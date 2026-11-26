import AppKit
import SwiftUI

struct NotchSettingsView: View {
    let calendar: CalendarFeed
    let model: NotchModel
    let toggleLockPreview: () -> Void

    @State private var targetedPage: NotchPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("NotchDay")
                .font(.title2.bold())

            services

            Divider()
            cardSection

            Divider()
            logSection

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

    private var services: some View {
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
    }

    private var cardSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("卡片")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(model.pageOrder) { page in
                    cardRow(page)
                }
            }

            Text("拖动左侧把手调整顺序，关闭的卡片不会出现在灵动岛的页轨里。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func cardRow(_ page: NotchPage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 12, height: 20)
                .contentShape(Rectangle())
                .draggable(String(page.rawValue)) {
                    Label(page.title, systemImage: page.symbol)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: .rect(cornerRadius: 6))
                }
                .help("拖动调整顺序")

            Image(systemName: page.symbol)
                .font(.system(size: 12))
                .foregroundStyle(page.tint)
                .frame(width: 18)

            Text(page.title)
                .font(.system(size: 12))

            Spacer(minLength: 8)

            Toggle("", isOn: visibility(page))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(isLastVisible(page))
                .help(isLastVisible(page) ? "至少保留一张卡片" : (model.hiddenPages.contains(page) ? "显示这张卡片" : "隐藏这张卡片"))
        }
        .frame(height: 30)
        .padding(.horizontal, 6)
        .background(
            targetedPage == page ? Color.accentColor.opacity(0.10) : Color.clear,
            in: .rect(cornerRadius: 6)
        )
        .dropDestination(for: String.self) { items, location in
            guard let raw = items.first, let value = Int(raw), let dragged = NotchPage(rawValue: value) else {
                return false
            }
            model.movePage(dragged, before: location.y < 15 ? page : nextPage(after: page))
            targetedPage = nil
            return true
        } isTargeted: { inside in
            if inside {
                targetedPage = page
            } else if targetedPage == page {
                targetedPage = nil
            }
        }
        .contextMenu {
            Button("上移") { model.movePage(page, by: -1) }
                .disabled(model.pageOrder.first == page)
            Button("下移") { model.movePage(page, by: 1) }
                .disabled(model.pageOrder.last == page)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("存储日志", systemImage: "doc.text")
                Spacer()
                Button("打开文件夹", action: SystemLinks.openStorageLogFolder)
            }
            Text("每小时记录一条，按月存一个 CSV，保留最近 13 个月。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func visibility(_ page: NotchPage) -> Binding<Bool> {
        Binding(
            get: { !model.hiddenPages.contains(page) },
            set: { model.setVisible(page, $0) }
        )
    }

    private func isLastVisible(_ page: NotchPage) -> Bool {
        !model.hiddenPages.contains(page) && model.visiblePages.count == 1
    }

    private func nextPage(after page: NotchPage) -> NotchPage? {
        guard let index = model.pageOrder.firstIndex(of: page) else { return nil }
        return model.pageOrder.indices.contains(index + 1) ? model.pageOrder[index + 1] : nil
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
