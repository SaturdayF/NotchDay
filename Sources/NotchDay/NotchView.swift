import AppKit
import SwiftUI

struct NotchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pageDirection: CGFloat = 1

    let model: NotchModel
    let calendar: CalendarFeed
    let sizing: NotchSizing
    let toggleExpanded: () -> Void
    let seekingChanged: (Bool) -> Void
    let playbackChanged: () -> Void

    private var expanded: Bool { model.mode == .expanded }
    private var locked: Bool { model.mode == .locked }
    private var coverVisible: Bool {
        expanded ? model.page == .music : model.isPlaying && !locked
    }

    private var shapeAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .spring(duration: expanded ? 0.34 : 0.29, bounce: expanded ? 0.08 : 0)
    }

    private var contentAnimation: Animation {
        .easeInOut(duration: reduceMotion ? 0.09 : 0.17)
            .delay(expanded && !reduceMotion ? 0.065 : 0)
    }

    var body: some View {
        let shoulder = sizing.shoulder(for: model.mode)
        let width = locked
            ? LockBadgeMotion.bodyWidth(for: sizing, revealed: model.lockPreviewRevealed, reduceMotion: reduceMotion)
            : sizing.bodyWidth(for: model.mode, playing: model.isPlaying)
        let height = sizing.depth(for: model.mode, page: model.page, scheduleRows: calendar.maximumRowCount)
        let outline = NotchOutline(
            shoulder: shoulder,
            corner: expanded ? 24 : min(12, sizing.hardwareHeight * 0.33)
        )

        Color.black
            .frame(width: width + 2 * shoulder, height: height + sizing.topBleed)
            .overlay(alignment: .top) {
                expandedContents
                    .opacity(expanded ? 1 : 0)
                    .allowsHitTesting(expanded)
                    .accessibilityHidden(!expanded)
                    .animation(contentAnimation, value: expanded)
                    .padding(.top, sizing.topBleed + sizing.hardwareHeight + 8)
            }
            .overlay(alignment: .topLeading) {
                let size = expanded ? 52.0 : min(20.0, sizing.hardwareHeight - 8)
                AlbumArtwork(image: model.music.artwork, tint: model.musicTint)
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: expanded ? 9 : 4))
                    .offset(
                        x: shoulder + (expanded ? 19 : 7),
                        y: sizing.topBleed + (expanded ? sizing.hardwareHeight + 8 : (sizing.hardwareHeight - size) / 2)
                    )
                    .opacity(coverVisible ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topTrailing) {
                PlaybackPips(color: model.musicTint)
                    .frame(height: sizing.hardwareHeight)
                    .padding(.top, sizing.topBleed)
                    .padding(.trailing, shoulder + 8)
                    .opacity(model.mode == .compact && model.isPlaying ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .top) {
                LockBadgeGlyph(sizing: sizing, revealed: locked && model.lockPreviewRevealed)
                    .opacity(locked ? 1 : 0)
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
            .animation(shapeAnimation, value: model.mode)
            .animation(LockBadgeMotion.outline(revealed: model.lockPreviewRevealed, reduceMotion: reduceMotion), value: model.lockPreviewRevealed)
            .animation(reduceMotion ? nil : .smooth(duration: 0.23), value: model.page)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: calendar.maximumRowCount)
            .animation(reduceMotion ? nil : .smooth(duration: 0.19), value: model.isPlaying)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(.white)
            .preferredColorScheme(.dark)
    }

    private var expandedContents: some View {
        let height = sizing.depth(for: .expanded, page: model.page, scheduleRows: calendar.maximumRowCount) - sizing.hardwareHeight - 16
        return VStack(spacing: 3) {
            ZStack(alignment: .top) {
                switch model.page {
                case .music:
                    MusicPage(model: model, seekingChanged: seekingChanged, playbackChanged: playbackChanged)
                        .transition(pageTransition)
                case .activity:
                    ActivityPage()
                        .transition(pageTransition)
                case .schedule:
                    SchedulePage(calendar: calendar, viewportHeight: sizing.scheduleViewport(rows: calendar.maximumRowCount))
                        .transition(pageTransition)
                        .onAppear { calendar.refresh() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack(spacing: 2) {
                ForEach(NotchPage.allCases) { page in
                    Button {
                        guard page != model.page else { return }
                        pageDirection = page.rawValue > model.page.rawValue ? 1 : -1
                        withAnimation(.easeInOut(duration: reduceMotion ? 0.08 : 0.19)) {
                            model.page = page
                        }
                    } label: {
                        Circle()
                            .fill(model.page == page ? Color.white : Color.white.opacity(0.32))
                            .frame(width: 5, height: 5)
                            .frame(width: 23, height: 21)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(page.title)
                    .accessibilityAddTraits(model.page == page ? .isSelected : [])
                    .help(page.title)
                }
            }
        }
        .frame(width: sizing.expandedWidth - 38, height: height)
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: 9 * pageDirection).combined(with: .opacity),
            removal: .offset(x: -6 * pageDirection).combined(with: .opacity)
        )
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
    var color: Color
    var heights: [CGFloat] = [5, 10, 7, 9]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: heights[index])
            }
        }
    }
}

private struct AlbumArtwork: View {
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
