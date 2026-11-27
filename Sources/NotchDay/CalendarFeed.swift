import AppKit
import EventKit
import Observation

struct AgendaEvent: Identifiable {
    let itemID: String
    let start: Date
    let end: Date
    let title: String
    let isAllDay: Bool
    let occurrence: Date?
    let color: CGColor?

    var id: String { "\(itemID)-\(start.timeIntervalSinceReferenceDate)" }

    var calendarURL: URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%;")
        guard !itemID.isEmpty, let encodedID = itemID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }

        var path = "/"
        if let occurrence {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            path += formatter.string(from: occurrence) + "/"
        }
        return URL(string: "ical://ekevent\(path)\(encodedID)?method=show&options=more")
    }

    func overlaps(_ interval: DateInterval) -> Bool {
        if start == end { return start >= interval.start && start < interval.end }
        return start < interval.end && end > interval.start
    }
}

struct AgendaDay: Identifiable {
    let title: String
    let date: Date
    let events: [AgendaEvent]
    let reminders: [AgendaReminder]

    var id: Date { date }
}

struct AgendaReminder: Identifiable, Sendable {
    let id: String
    let due: Date
    let title: String
    let hasTime: Bool

    static func dueDate(from components: DateComponents, localCalendar: Calendar = .autoupdatingCurrent) -> Date? {
        var components = components
        var calendar = components.calendar ?? localCalendar
        if components.hour == nil {
            // A date-only reminder follows the local calendar day regardless of its source time zone.
            calendar.timeZone = localCalendar.timeZone
            components.timeZone = nil
        }
        return calendar.date(from: components)
    }
}

@MainActor
@Observable
final class CalendarFeed: NSObject {
    enum Permission: Equatable {
        case needsAccess
        case requesting
        case denied
        case allowed
        case unavailable
    }

    private let store = EKEventStore()
    private(set) var permission: Permission = .needsAccess
    private(set) var reminderPermission: Permission = .needsAccess
    private(set) var days: [AgendaDay] = []
    private var reminders: [AgendaReminder] = []
    private var reminderFetch: Any?
    private var reminderRequestID = UUID()
    var maximumRowCount: Int { days.lazy.map { $0.events.count + $0.reminders.count }.max() ?? 0 }

    func start() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(calendarChanged(_:)), name: .EKEventStoreChanged, object: store)
        center.addObserver(self, selector: #selector(calendarChanged(_:)), name: .NSCalendarDayChanged, object: nil)
        center.addObserver(self, selector: #selector(calendarChanged(_:)), name: .NSSystemTimeZoneDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(calendarChanged(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
    }

    func stop() {
        cancelReminderFetch()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func requestAccess() async {
        guard permission == .needsAccess || permission == .unavailable else { return }
        permission = .requesting
        do {
            _ = try await store.requestFullAccessToEvents()
            permission = .needsAccess
            refresh()
        } catch {
            permission = .needsAccess
            refresh()
            if permission == .needsAccess { permission = .unavailable }
        }
    }

    func requestReminderAccess() async {
        guard reminderPermission == .needsAccess || reminderPermission == .unavailable else { return }
        reminderPermission = .requesting
        do {
            _ = try await store.requestFullAccessToReminders()
            reminderPermission = .needsAccess
            refresh()
        } catch {
            reminderPermission = .needsAccess
            refresh()
            if reminderPermission == .needsAccess { reminderPermission = .unavailable }
        }
    }

    func refresh() {
        if permission != .requesting { permission = Self.permission(for: .event) }
        if reminderPermission != .requesting { reminderPermission = Self.permission(for: .reminder) }
        if reminderPermission != .allowed { reminders = [] }
        cancelReminderFetch()
        guard let dates = Self.agendaDates() else {
            days = []
            return
        }
        let events = permission == .allowed ? calendarEvents(from: dates.today, to: dates.end) : []
        rebuildDays(events: events, dates: dates)
        guard reminderPermission == .allowed else { return }

        let id = reminderRequestID
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: dates.today, ending: dates.end, calendars: nil
        )
        // EventKit invokes this callback on its own search queue.
        reminderFetch = store.fetchReminders(matching: predicate) { @Sendable [weak self] items in
            let reminders = (items ?? []).compactMap { item -> AgendaReminder? in
                guard !item.isCompleted, let components = item.dueDateComponents,
                      let due = AgendaReminder.dueDate(from: components) else { return nil }
                let title = item.title ?? ""
                return AgendaReminder(
                    id: item.calendarItemIdentifier, due: due,
                    title: title.isEmpty ? "无标题提醒事项" : title,
                    hasTime: components.hour != nil
                )
            }.sorted {
                if $0.due != $1.due { return $0.due < $1.due }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            Task { @MainActor [weak self] in
                guard let self, self.reminderRequestID == id else { return }
                self.reminderFetch = nil
                self.reminders = reminders
                self.rebuildDays(events: events, dates: dates)
            }
        }
    }

    private func cancelReminderFetch() {
        reminderRequestID = UUID()
        if let reminderFetch { store.cancelFetchRequest(reminderFetch) }
        reminderFetch = nil
    }

    private func rebuildDays(events: [AgendaEvent], dates: (today: Date, tomorrow: Date, end: Date)) {
        guard permission == .allowed || reminderPermission == .allowed else {
            days = []
            return
        }
        days = [("今天", dates.today, dates.tomorrow), ("明天", dates.tomorrow, dates.end)].map { title, start, end in
            let interval = DateInterval(start: start, end: end)
            return AgendaDay(
                title: title, date: start,
                events: events.filter { $0.overlaps(interval) },
                reminders: reminders.filter { $0.due >= start && $0.due < end }
            )
        }
    }

    private func calendarEvents(from today: Date, to end: Date) -> [AgendaEvent] {
        let predicate = store.predicateForEvents(withStart: today, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event -> AgendaEvent? in
            guard let start = event.startDate, let end = event.endDate else { return nil }
            return AgendaEvent(
                itemID: event.calendarItemIdentifier, start: start, end: end,
                title: event.title?.isEmpty == false ? event.title : "无标题日程",
                isAllDay: event.isAllDay,
                occurrence: event.hasRecurrenceRules || event.isDetached ? event.occurrenceDate ?? start : nil,
                color: event.calendar?.cgColor
            )
        }
        .sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

    }

    private static func agendaDates() -> (today: Date, tomorrow: Date, end: Date)? {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: tomorrow) else { return nil }
        return (today, tomorrow, end)
    }

    private static func permission(for entity: EKEntityType) -> Permission {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess: .allowed
        case .notDetermined: .needsAccess
        case .denied, .restricted, .writeOnly: .denied
        @unknown default: .unavailable
        }
    }

    @objc nonisolated private func calendarChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.refresh() }
    }
}
