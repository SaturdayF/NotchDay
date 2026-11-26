import AppKit
import Observation
import SwiftUI

enum NotchMode: Equatable {
    case compact
    case expanded
    case locked
}

enum NotchPage: Int, CaseIterable, Identifiable {
    case music
    case activity
    case schedule
    case storage

    var id: Self { self }

    var title: String {
        switch self {
        case .music: "音乐"
        case .activity: "App 与网站活动"
        case .schedule: "日程"
        case .storage: "储存空间"
        }
    }

    var symbol: String {
        switch self {
        case .music: "music.note"
        case .activity: "hourglass"
        case .schedule: "calendar"
        case .storage: "internaldrive"
        }
    }

    var tint: Color {
        switch self {
        case .music, .storage: Color(red: 0.54, green: 0.56, blue: 0.97)
        case .activity: .purple
        case .schedule: .orange
        }
    }
}

struct NotchSizing: Equatable {
    static let contentInset: CGFloat = 19
    static let pageRailWidth: CGFloat = 18
    static let pageRailGap: CGFloat = 12
    static let pageRailTopInset: CGFloat = 4
    static let pageDotHeight: CGFloat = 18
    private static let railClearance: CGFloat = 28
    static let cardInset = contentInset + pageRailWidth + pageRailGap
    static let cardGap: CGFloat = 10
    static let expandedTopInset: CGFloat = 8
    static let expandedBottomInset: CGFloat = 18
    private static let expandedInsets = expandedTopInset + expandedBottomInset

    let hardwareWidth: CGFloat
    let hardwareHeight: CGFloat
    let availableWidth: CGFloat
    let screenHeight: CGFloat
    let topBleed: CGFloat

    var compactCorner: CGFloat { min(12, hardwareHeight * 0.33) }

    var expandedWidth: CGFloat {
        min(availableWidth, max(392, hardwareWidth + 112))
    }

    var maximumSize: CGSize {
        let minimumDepth = NotchPage.allCases.map { depth(for: .expanded, page: $0, scheduleRows: 0) }.max() ?? hardwareHeight
        return CGSize(width: expandedWidth + 2 * shoulder(for: .expanded), height: max(screenHeight / 2, minimumDepth))
    }

    func bodyWidth(for mode: NotchMode, playing: Bool) -> CGFloat {
        switch mode {
        case .compact: hardwareWidth + (playing ? 64 : 0)
        case .expanded: expandedWidth
        case .locked: hardwareWidth + 43
        }
    }

    func shoulder(for mode: NotchMode) -> CGFloat {
        mode == .expanded ? 15 : 7
    }

    func depth(for mode: NotchMode, page: NotchPage, scheduleRows: Int, pages: Int = NotchPage.allCases.count) -> CGFloat {
        guard mode == .expanded else { return hardwareHeight }
        return hardwareHeight + Self.expandedInsets + contentHeight(for: page, scheduleRows: scheduleRows, pages: pages)
    }

    /// 页轨圆点可能比卡片本身更高，内容区按两者较大者取，避免末位圆点贴到底部圆角。
    func contentHeight(for page: NotchPage, scheduleRows: Int, pages: Int) -> CGFloat {
        max(cardHeight(for: page, scheduleRows: scheduleRows), railHeight(pages: pages) + Self.railClearance)
    }

    func railHeight(pages: Int) -> CGFloat {
        Self.pageRailTopInset + Self.pageDotHeight * CGFloat(max(pages, 1))
    }

    func cardHeight(for page: NotchPage, scheduleRows: Int) -> CGFloat {
        switch page {
        case .music: 114
        case .activity: 142
        case .schedule: scheduleViewport(rows: scheduleRows)
        case .storage: 160
        }
    }

    func cardOffset(for page: NotchPage, scheduleRows: Int, order: [NotchPage]) -> CGFloat {
        order.prefix { $0 != page }.reduce(0) {
            $0 + cardHeight(for: $1, scheduleRows: scheduleRows) + Self.cardGap
        }
    }

    func scheduleViewport(rows: Int) -> CGFloat {
        min(AgendaLayout.contentHeight(rows: rows), max(56, screenHeight / 2 - hardwareHeight - Self.expandedInsets))
    }
}

enum AgendaLayout {
    static let headingHeight: CGFloat = 23
    static let rowHeight: CGFloat = 31
    static let rowSpacing: CGFloat = 4

    static func contentHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return 58 }
        return headingHeight + CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing
    }
}

struct AgendaScrollEdges: Equatable {
    var canGoEarlier = false
    var canGoLater = false
}

@MainActor
@Observable
final class NotchModel {
    let music = MusicPlayback()
    var mode: NotchMode = .compact
    var page: NotchPage = .music
    var lockPreview: LockBadgePhase = .hidden
    var lockPlaybackPreview: LockPlayback?
    var agendaScrollEdges = AgendaScrollEdges()
    var isHovering = false
    var isSeeking = false
    var desktopWingsVisible = true

    var pageOrder: [NotchPage] { didSet { saveOrder() } }
    var hiddenPages: Set<NotchPage> { didSet { saveHidden() } }

    private static let orderKey = "pages.order"
    private static let hiddenKey = "pages.hidden"

    init() {
        let defaults = UserDefaults.standard
        var order: [NotchPage] = []
        for page in (defaults.array(forKey: Self.orderKey) as? [Int] ?? []).compactMap(NotchPage.init(rawValue:))
        where !order.contains(page) {
            order.append(page)
        }
        for page in NotchPage.allCases where !order.contains(page) { order.append(page) }
        pageOrder = order

        var hidden = Set((defaults.array(forKey: Self.hiddenKey) as? [Int] ?? []).compactMap(NotchPage.init(rawValue:)))
        if order.allSatisfy({ hidden.contains($0) }) { hidden = [] }
        hiddenPages = hidden
        if hidden.contains(.music), let first = order.first(where: { !hidden.contains($0) }) {
            page = first
        }
    }

    var visiblePages: [NotchPage] { pageOrder.filter { !hiddenPages.contains($0) } }

    func setVisible(_ page: NotchPage, _ visible: Bool) {
        if visible {
            hiddenPages.remove(page)
        } else {
            guard visiblePages.count > 1 else { return }
            hiddenPages.insert(page)
            if self.page == page { self.page = visiblePages.first ?? .music }
        }
    }

    func movePage(_ page: NotchPage, before target: NotchPage?) {
        guard page != target, let from = pageOrder.firstIndex(of: page) else { return }
        var order = pageOrder
        order.remove(at: from)
        let index = target.flatMap { order.firstIndex(of: $0) } ?? order.count
        order.insert(page, at: index)
        pageOrder = order
    }

    func movePage(_ page: NotchPage, by offset: Int) {
        guard let index = pageOrder.firstIndex(of: page) else { return }
        let target = index + offset
        guard pageOrder.indices.contains(target) else { return }
        var order = pageOrder
        order.swapAt(index, target)
        pageOrder = order
    }

    private func saveOrder() {
        UserDefaults.standard.set(pageOrder.map(\.rawValue), forKey: Self.orderKey)
    }

    private func saveHidden() {
        UserDefaults.standard.set(hiddenPages.map(\.rawValue).sorted(), forKey: Self.hiddenKey)
    }

    var isPlaying: Bool { music.isPlaying }
    var showsCompactPlayback: Bool { desktopWingsVisible && isPlaying }
    var track: MusicTrack { music.track }
    var musicTint: Color { Color(red: 0.54, green: 0.56, blue: 0.97) }

    func playbackPosition(at date: Date = .now) -> Double { music.position(at: date) }
    func togglePlayback() { music.send(.playPause) }
    func seek(to position: Double) { music.send(.seek(position)) }
    func changeTrack(by step: Int) { music.send(step > 0 ? .next : .previous) }
}
