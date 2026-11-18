import AppKit
import SwiftUI

struct ActivityPage: View {
    let feed: ActivityFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: SystemLinks.openScreenTime) {
                HStack(spacing: 9) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.purple)
                    Text("App 与网站活动")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.57))
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开系统的 App 与网站活动")
            .help("在系统设置中打开屏幕时间")

            switch feed.state {
            case .loading:
                status("正在读取本地使用记录…")
            case let .available(summary):
                if summary.seconds > 0 {
                    report(summary)
                } else {
                    status("今天暂无使用记录。")
                    retry
                }
            case .accessDenied:
                status("macOS 拒绝读取本地使用记录。")
                HStack(spacing: 12) {
                    Button("打开完全磁盘访问", action: SystemLinks.openFullDiskAccess)
                    retry
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.63, green: 0.71, blue: 1))
            case .unavailable:
                status("当前无法读取本地记录。")
                retry
            }
        }
    }

    private var retry: some View {
        Button("重新读取") { Task { await feed.refresh(force: true) } }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(red: 0.63, green: 0.71, blue: 1))
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.65))
    }

    private func report(_ summary: ActivitySummary) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(duration(summary.seconds))
                    .font(.system(size: 19, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                status("今天")
                hourlyBars(summary.hours)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(summary.apps.prefix(3)) { item in
                    usageRow(item, name: appName(item.id))
                }
                ForEach(summary.domains.prefix(2)) { item in
                    usageRow(item, name: item.id)
                }
                if summary.domains.isEmpty { status("暂无网站记录") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hourlyBars(_ hours: [TimeInterval]) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(hours.indices, id: \.self) { index in
                    let seconds = hours[index]
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(seconds > 0 ? Color.indigo : .white.opacity(0.16))
                        .frame(height: max(2, min(1, seconds / 3600) * 31))
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 31, alignment: .bottom)
            HStack {
                status("0 时")
                Spacer()
                status("12 时")
                Spacer()
                status("24 时")
            }
            .accessibilityHidden(true)
        }
    }

    private func usageRow(_ item: ActivitySummary.Item, name: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(duration(item.seconds))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.63))
                .fixedSize()
        }
        .font(.system(size: 10))
    }

    private func appName(_ identifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return identifier }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes == 0 { return "不足 1 分钟" }
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}

struct SchedulePage: View {
    let calendar: CalendarFeed
    let viewportHeight: CGFloat
    let edgesChanged: (AgendaScrollEdges) -> Void

    var body: some View {
        if calendar.permission == .allowed || calendar.reminderPermission == .allowed {
            let contentHeight = AgendaLayout.contentHeight(rows: calendar.maximumRowCount)
            if contentHeight > viewportHeight {
                ScrollView { columns(height: contentHeight) }
                    .frame(height: viewportHeight)
                    .onScrollGeometryChange(for: AgendaScrollEdges.self) { geometry in
                        let top = -geometry.contentInsets.top
                        let bottom = geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom
                        return AgendaScrollEdges(
                            canGoEarlier: geometry.contentOffset.y > top + 1,
                            canGoLater: geometry.contentOffset.y < bottom - 1
                        )
                    } action: { _, edges in
                        edgesChanged(edges)
                    }
            } else {
                columns(height: contentHeight)
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                Text("连接系统日历和提醒事项，查看今天与明天的安排。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.73))
                HStack(spacing: 15) {
                    calendarAccess
                    reminderAccess
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.63, green: 0.71, blue: 1))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var calendarAccess: some View {
        switch calendar.permission {
        case .allowed:
            EmptyView()
        case .requesting:
            Text("日历授权中…")
        case .denied:
            Button("日历权限", action: SystemLinks.openCalendarPrivacy)
        case .needsAccess, .unavailable:
            Button("连接日历") { Task { await calendar.requestAccess() } }
        }
    }

    @ViewBuilder
    private var reminderAccess: some View {
        switch calendar.reminderPermission {
        case .allowed:
            EmptyView()
        case .requesting:
            Text("提醒事项授权中…")
        case .denied:
            Button("提醒事项权限", action: SystemLinks.openRemindersPrivacy)
        case .needsAccess, .unavailable:
            Button("连接提醒事项") { Task { await calendar.requestReminderAccess() } }
        }
    }

    private func columns(height: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(calendar.days) { day in
                if day.title == "明天" {
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 1, height: height)
                        .accessibilityHidden(true)
                }
                dayColumn(day)
            }
        }
        .frame(height: height, alignment: .top)
    }

    private func dayColumn(_ day: AgendaDay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: SystemLinks.openCalendar) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(day.title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(day.date, format: .dateTime.month(.defaultDigits).day().locale(Locale(identifier: "zh_CN")))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .help("打开系统日历")
                Spacer(minLength: 0)
                if day.title == "今天" { calendarAccess } else { reminderAccess }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .frame(height: AgendaLayout.headingHeight, alignment: .topLeading)

            if day.events.isEmpty && day.reminders.isEmpty {
                Text("当天没有日程")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                VStack(alignment: .leading, spacing: AgendaLayout.rowSpacing) {
                    ForEach(day.events) { event in
                        eventRow(event)
                    }
                    ForEach(day.reminders) { reminder in
                        reminderRow(reminder)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func reminderRow(_ reminder: AgendaReminder) -> some View {
        Button(action: SystemLinks.openReminders) {
            HStack(spacing: 7) {
                Image(systemName: "circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reminder.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(reminder.hasTime
                         ? "提醒事项 · " + reminder.due.formatted(.dateTime.hour().minute())
                         : "提醒事项")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.57))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: AgendaLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开系统提醒事项")
    }

    private func eventRow(_ event: AgendaEvent) -> some View {
        Button {
            SystemLinks.openCalendarEvent(event)
        } label: {
            HStack(spacing: 7) {
                Capsule()
                    .fill(event.color.map { Color(cgColor: $0) } ?? .cyan)
                    .frame(width: 2, height: 23)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(timeLabel(event))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.57))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: AgendaLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在系统日历中打开")
    }

    private func timeLabel(_ event: AgendaEvent) -> String {
        if event.isAllDay { return "全天" }
        let calendar = Calendar.autoupdatingCurrent
        let style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            .locale(Locale(identifier: "zh_CN"))
        let start = event.start.formatted(style)
        guard event.end > event.start else { return start }
        if calendar.isDate(event.start, inSameDayAs: event.end) {
            return start + "–" + event.end.formatted(style)
        }
        let dayTimeStyle = style.month(.defaultDigits).day()
        return event.start.formatted(dayTimeStyle) + "–" + event.end.formatted(dayTimeStyle)
    }
}
