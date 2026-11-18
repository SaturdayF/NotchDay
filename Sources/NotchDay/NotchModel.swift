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
    let hardwareWidth: CGFloat
    let hardwareHeight: CGFloat
    let availableWidth: CGFloat
    let screenHeight: CGFloat
    let topBleed: CGFloat

    var expandedWidth: CGFloat {
        min(availableWidth, max(392, hardwareWidth + 112))
    }

    var maximumSize: CGSize {
        CGSize(width: expandedWidth + 30, height: max(screenHeight / 2, hardwareHeight + 169))
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
        switch page {
        case .music: return hardwareHeight + 155
        case .activity: return hardwareHeight + 91
        case .schedule: return hardwareHeight + 40 + scheduleViewport(rows: scheduleRows)
        }
    }

    func scheduleViewport(rows: Int) -> CGFloat {
        min(AgendaLayout.contentHeight(rows: rows), max(56, screenHeight / 2 - hardwareHeight - 40))
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

@MainActor
@Observable
final class NotchModel {
    let music = MusicPlayback()
    var mode: NotchMode = .compact
    var page: NotchPage = .music
    var lockPreviewRevealed = false
    var isHovering = false
    var isSeeking = false

    var isPlaying: Bool { music.isPlaying }
    var track: MusicTrack { music.track }
    var musicTint: Color { Color(red: 0.54, green: 0.56, blue: 0.97) }

    func playbackPosition(at date: Date = .now) -> Double { music.position(at: date) }
    func togglePlayback() { music.send(.playPause) }
    func seek(to position: Double) { music.send(.seek(position)) }
    func changeTrack(by step: Int) { music.send(step > 0 ? .next : .previous) }
}
