import AppKit
import SwiftUI

struct NotchSettingsView: View {
    let calendar: CalendarFeed
    let model: NotchModel
    let toggleLockPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("NotchDay")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Apple Music", systemImage: "music.note")
                    Spacer()
                    if model.music.connection == .connected {
                        Button("打开音乐", action: SystemLinks.openMusic)
                    } else {
                        Button("连接音乐", action: model.music.connectionAction)
                    }
                }
                Divider()
                HStack {
                    Label("系统日历", systemImage: "calendar")
                    Spacer()
                    calendarAction
                }
                Divider()
                HStack {
                    Label("App 与网站活动", systemImage: "hourglass")
                    Spacer()
                    Button("打开系统报告", action: SystemLinks.openScreenTime)
                }
            }

            Divider()
            HStack {
                Button(model.mode == .locked ? "结束锁屏预览" : "预览白锁", action: toggleLockPreview)
                    .disabled(model.mode == .locked && model.lockPreview != .locked)
                Spacer()
                Button("退出 NotchDay", role: .destructive) {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(22)
        .frame(width: 396)
    }

    @ViewBuilder
    private var calendarAction: some View {
        switch calendar.permission {
        case .allowed:
            Button("打开日历", action: SystemLinks.openCalendar)
        case .needsAccess, .unavailable:
            Button("允许读取日历") {
                Task { await calendar.requestAccess() }
            }
        case .requesting:
            Text("正在请求权限…")
                .foregroundStyle(.secondary)
        case .denied:
            Button("打开日历权限", action: SystemLinks.openCalendarPrivacy)
        }
    }
}
