import SwiftUI

struct ActivityPage: View {
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

            Text("在系统设置中查看使用时长")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.61))
        }
    }
}

struct SchedulePage: View {
    let calendar: CalendarFeed
    let viewportHeight: CGFloat

    var body: some View {
        switch calendar.permission {
        case .allowed:
            let contentHeight = AgendaLayout.contentHeight(rows: calendar.maximumRowCount)
            if contentHeight > viewportHeight {
                ScrollView {
                    columns(height: contentHeight)
                }
                .frame(height: viewportHeight)
            } else {
                columns(height: contentHeight)
            }

        case .needsAccess, .unavailable:
            accessState(
                message: calendar.permission == .unavailable ? "无法读取日历，可以重试。" : "允许访问「日历」以显示今天和明天的日程。",
                action: "允许读取日历"
            ) {
                Task { await calendar.requestAccess() }
            }

        case .requesting:
            VStack(alignment: .leading, spacing: 8) {
                Text("正在请求日历权限…")
                    .font(.system(size: 12))
                Button("打开日历 ↗", action: SystemLinks.openCalendar)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
            }

        case .denied:
            accessState(message: "请在系统设置中允许 NotchDay 访问日历。", action: "打开日历权限", perform: SystemLinks.openCalendarPrivacy)
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

    private func accessState(message: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.73))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button(action, action: perform)
                    .foregroundStyle(Color(red: 0.63, green: 0.71, blue: 1))
                Button("打开日历 ↗", action: SystemLinks.openCalendar)
                    .foregroundStyle(.white.opacity(0.65))
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayColumn(_ day: AgendaDay) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .buttonStyle(.plain)
            .frame(height: AgendaLayout.headingHeight, alignment: .topLeading)
            .help("打开系统日历")

            if day.events.isEmpty {
                Text("当天没有日程")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                VStack(alignment: .leading, spacing: AgendaLayout.rowSpacing) {
                    ForEach(day.events) { event in
                        eventRow(event)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
