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

    var id: Date { date }
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
    private(set) var days: [AgendaDay] = []
    var maximumRowCount: Int { days.map(\.events.count).max() ?? 0 }

    func start() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(calendarChanged(_:)), name: .EKEventStoreChanged, object: store)
        center.addObserver(self, selector: #selector(calendarChanged(_:)), name: .NSCalendarDayChanged, object: nil)
        center.addObserver(self, selector: #selector(calendarChanged(_:)), name: .NSSystemTimeZoneDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(calendarChanged(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
    }

    func stop() {
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

    func refresh() {
        guard permission != .requesting else { return }

        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: permission = .allowed
        case .notDetermined: permission = .needsAccess
        case .denied, .restricted, .writeOnly: permission = .denied
        @unknown default: permission = .unavailable
        }

        guard permission == .allowed else {
            days = []
            return
        }

        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: .now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: tomorrow)
        else {
            days = []
            return
        }

        let predicate = store.predicateForEvents(withStart: today, end: end, calendars: nil)
        let events = store.events(matching: predicate).compactMap { event -> AgendaEvent? in
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

        days = [
            AgendaDay(title: "今天", date: today, events: events.filter { $0.overlaps(DateInterval(start: today, end: tomorrow)) }),
            AgendaDay(title: "明天", date: tomorrow, events: events.filter { $0.overlaps(DateInterval(start: tomorrow, end: end)) })
        ]
    }

    @objc nonisolated private func calendarChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.refresh() }
    }
}
