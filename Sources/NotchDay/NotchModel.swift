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

    var id: Self { self }

    var title: String {
        switch self {
        case .music: "音乐"
        case .activity: "App 与网站活动"
        case .schedule: "日程"
        }
    }
}

struct NotchSizing: Equatable {
    static let contentInset: CGFloat = 19
    static let pageRailWidth: CGFloat = 18
    static let pageRailGap: CGFloat = 12
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

    func depth(for mode: NotchMode, page: NotchPage, scheduleRows: Int) -> CGFloat {
        guard mode == .expanded else { return hardwareHeight }
        return hardwareHeight + Self.expandedInsets + cardHeight(for: page, scheduleRows: scheduleRows)
    }

    func cardHeight(for page: NotchPage, scheduleRows: Int) -> CGFloat {
        switch page {
        case .music: 114
        case .activity: 142
        case .schedule: scheduleViewport(rows: scheduleRows)
        }
    }

    func cardOffset(for page: NotchPage, scheduleRows: Int) -> CGFloat {
        NotchPage.allCases.prefix(page.rawValue).reduce(0) {
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

    var isPlaying: Bool { music.isPlaying }
    var showsCompactPlayback: Bool { desktopWingsVisible && isPlaying }
    var track: MusicTrack { music.track }
    var musicTint: Color { Color(red: 0.54, green: 0.56, blue: 0.97) }

    func playbackPosition(at date: Date = .now) -> Double { music.position(at: date) }
    func togglePlayback() { music.send(.playPause) }
    func seek(to position: Double) { music.send(.seek(position)) }
    func changeTrack(by step: Int) { music.send(step > 0 ? .next : .previous) }
}
