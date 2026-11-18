import AppKit
import SwiftUI

struct NotchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let model: NotchModel
    let calendar: CalendarFeed
    let activity: ActivityFeed
    let sizing: NotchSizing
    let toggleExpanded: () -> Void
    let seekingChanged: (Bool) -> Void
    let playbackChanged: () -> Void
    let selectPage: (NotchPage) -> Void

    private var expanded: Bool { model.mode == .expanded }
    private var locked: Bool { model.mode == .locked }
    private var coverVisible: Bool {
        expanded ? model.page == .music : model.showsCompactPlayback && !locked
    }

    private var shapeAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .spring(duration: expanded ? 0.34 : 0.29, bounce: expanded ? 0.08 : 0)
    }

    private var contentAnimation: Animation {
        if !model.desktopWingsVisible { return .easeOut(duration: 0.10) }
        return .easeInOut(duration: reduceMotion ? 0.09 : 0.17)
            .delay(expanded && !reduceMotion ? 0.065 : 0)
    }

    var body: some View {
        let shoulder = model.desktopWingsVisible ? sizing.shoulder(for: model.mode) : 0
        let width = sizing.bodyWidth(for: model.mode, playing: model.showsCompactPlayback)
        let height = sizing.depth(for: model.mode, page: model.page, scheduleRows: calendar.maximumRowCount)
        let outline = NotchOutline(
            shoulder: shoulder,
            corner: expanded ? 24 : sizing.compactCorner
        )

        Color.black
            .frame(width: width + 2 * shoulder, height: height + sizing.topBleed)
            .overlay(alignment: .top) {
                expandedContents
                    .opacity(expanded ? 1 : 0)
                    .allowsHitTesting(expanded)
                    .accessibilityHidden(!expanded)
                    .animation(contentAnimation, value: expanded)
                    .padding(.top, sizing.topBleed + sizing.hardwareHeight + NotchSizing.expandedTopInset)
            }
            .overlay(alignment: .topLeading) {
                let size = expanded ? 52.0 : min(20.0, sizing.hardwareHeight - 8)
                AlbumArtwork(image: model.music.artwork, tint: model.musicTint)
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: expanded ? 9 : 4))
                    .offset(
                        x: shoulder + (expanded ? NotchSizing.cardInset : 7),
                        y: sizing.topBleed + (expanded
                            ? sizing.hardwareHeight + NotchSizing.expandedTopInset
                            : (sizing.hardwareHeight - size) / 2)
                    )
                    .opacity(coverVisible ? 1 : 0)
                    .animation(wingContentAnimation, value: model.desktopWingsVisible)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topTrailing) {
                PlaybackPips(
                    color: model.musicTint, active: model.mode == .compact && model.showsCompactPlayback
                )
                    .frame(height: sizing.hardwareHeight)
                    .padding(.top, sizing.topBleed)
                    .padding(.trailing, shoulder + 8)
                    .opacity(model.mode == .compact && model.showsCompactPlayback ? 1 : 0)
                    .animation(wingContentAnimation, value: model.desktopWingsVisible)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .top) {
                if !locked {
                    Button(action: toggleExpanded) {
                        Rectangle()
                            .fill(.clear)
                            .frame(width: width, height: sizing.hardwareHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "收起灵动岛" : "展开灵动岛")
                    .padding(.top, sizing.topBleed)
                }
            }
            .clipShape(outline)
            .animation(model.desktopWingsVisible ? shapeAnimation : wingShapeAnimation, value: model.mode)
            .animation(geometryAnimation(duration: 0.32), value: model.page)
            .animation(geometryAnimation(duration: 0.25), value: calendar.maximumRowCount)
            .animation(expanded || reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.isPlaying)
            .animation(wingShapeAnimation, value: model.desktopWingsVisible)
            .opacity(locked ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .top) {
                LockBadgeSurface(
                    sizing: sizing, phase: model.lockPreview, playback: model.lockPlaybackPreview,
                    hovering: model.isHovering
                )
                    .opacity(locked ? 1 : 0)
                    .accessibilityHidden(!locked)
            }
            .foregroundStyle(.white)
            .preferredColorScheme(.dark)
    }

    private var wingShapeAnimation: Animation? {
        guard !reduceMotion, model.desktopWingsVisible else { return nil }
        return .easeOut(duration: 0.22)
    }

    private func geometryAnimation(duration: Double) -> Animation? {
        guard !reduceMotion, model.desktopWingsVisible else { return nil }
        return .smooth(duration: duration)
    }

    private var wingContentAnimation: Animation {
        if !model.desktopWingsVisible { return .easeOut(duration: 0.09) }
        return .easeOut(duration: 0.19).delay(reduceMotion ? 0 : 0.055)
    }

    private var expandedContents: some View {
        let rows = calendar.maximumRowCount
        let height = sizing.cardHeight(for: model.page, scheduleRows: rows)
        let totalWidth = sizing.expandedWidth - 2 * NotchSizing.contentInset
        let width = totalWidth - NotchSizing.pageRailWidth - NotchSizing.pageRailGap

        return HStack(alignment: .top, spacing: NotchSizing.pageRailGap) {
            pageRail
                .padding(.top, 4)
                .frame(width: NotchSizing.pageRailWidth)

            VStack(spacing: NotchSizing.cardGap) {
                ForEach(NotchPage.allCases) { page in
                    card(page)
                        .frame(width: width, height: sizing.cardHeight(for: page, scheduleRows: rows), alignment: .topLeading)
                        .opacity(model.page == page ? 1 : 0.48)
                        .animation(.easeInOut(duration: reduceMotion ? 0.12 : 0.22), value: model.page == page)
                        .allowsHitTesting(model.page == page)
                        .accessibilityElement(children: .contain)
                        .accessibilityHidden(model.page != page)
                }
            }
            .offset(y: -sizing.cardOffset(for: model.page, scheduleRows: rows))
            .frame(width: width, height: height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
        }
        .frame(width: totalWidth, height: height, alignment: .top)
    }

    private var pageRail: some View {
        VStack(spacing: 0) {
            ForEach(NotchPage.allCases) { page in
                Button {
                    selectPage(page)
                } label: {
                    Circle()
                        .fill(model.page == page ? Color.white : Color.white.opacity(0.32))
                        .frame(width: 5, height: 5)
                        .frame(width: NotchSizing.pageRailWidth, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.title)
                .accessibilityAddTraits(model.page == page ? .isSelected : [])
                .help(page.title)
            }
        }
    }

    @ViewBuilder
    private func card(_ page: NotchPage) -> some View {
        switch page {
        case .music:
            MusicPage(model: model, seekingChanged: seekingChanged, playbackChanged: playbackChanged)
        case .activity:
            ActivityPage(feed: activity)
                .task(id: expanded && model.page == .activity) {
                    if expanded && model.page == .activity { await activity.refresh() }
                }
        case .schedule:
            SchedulePage(
                calendar: calendar,
                viewportHeight: sizing.scheduleViewport(rows: calendar.maximumRowCount),
                edgesChanged: { model.agendaScrollEdges = $0 }
            )
        }
    }
}

struct NotchOutline: Shape {
    var shoulder: CGFloat
    var corner: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, corner) }
        set {
            shoulder = newValue.first
            corner = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        let top = rect.minY
        let bottom = rect.maxY
        let radius = min(corner, max(0, rect.height - shoulder))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addQuadCurve(to: CGPoint(x: left, y: top + shoulder), control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: bottom), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: right, y: bottom - radius), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right, y: top + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top), control: CGPoint(x: right, y: top))
        path.closeSubpath()
        return path
    }
}

struct PlaybackPips: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    let active: Bool

    private let levels: [[CGFloat]] = [
        [0.66, 0.86, 0.48, 0.83],
        [0.84, 0.47, 0.92, 0.61],
        [0.46, 0.90, 0.72, 0.96],
        [0.92, 0.70, 0.89, 0.49]
    ]

    var body: some View {
        Group {
            if active && !reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.24)) { context in
                    let step = Int(context.date.timeIntervalSinceReferenceDate / 0.24) % levels.count
                    bars(levels[step])
                        .animation(.easeInOut(duration: 0.24), value: step)
                }
            } else {
                bars(levels[0])
            }
        }
        .accessibilityHidden(true)
    }

    private func bars(_ values: [CGFloat]) -> some View {
        HStack(spacing: 2) {
            ForEach(values.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 12)
                    .scaleEffect(x: 1, y: values[index])
            }
        }
    }
}

struct AlbumArtwork: View {
    let image: NSImage?
    let tint: Color

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                tint.opacity(0.20)
                Image(systemName: "music.note")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
    }
}
