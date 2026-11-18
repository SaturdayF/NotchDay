import AppKit
import CoreGraphics
import Observation
import SwiftUI

enum LockBadgePhase: Equatable {
    case hidden, music, fadingMusic, locked, opening, retracting

    var inWing: Bool { self == .locked || self == .opening }
    var open: Bool { self == .opening || self == .retracting }
    var entered: Bool { self == .locked || open }
}

struct LockPlayback: Equatable {
    let artwork: NSImage?
    let tint: Color
}

enum LockBadgeMotion {
    static let leftMargin: CGFloat = 10
    static let shadowAllowance: CGFloat = 24

    static func width(for sizing: NotchSizing) -> CGFloat {
        max(
            sizing.bodyWidth(for: .locked, playing: false) + leftMargin,
            sizing.bodyWidth(for: .compact, playing: true)
        ) + 2 * sizing.shoulder(for: .locked)
    }

    @MainActor
    static func present(from phase: LockBadgePhase, update: (LockBadgePhase) -> Void) async {
        do {
            try await Task.sleep(for: .milliseconds(30))
            if phase == .music {
                update(.fadingMusic)
                try await Task.sleep(for: .milliseconds(150))
            }
            update(.locked)
        } catch {
            return
        }
    }

    @MainActor
    static func retract(_ update: (LockBadgePhase) -> Void) async -> Bool {
        guard !Task.isCancelled else { return false }
        update(.opening)
        do {
            try await Task.sleep(for: .milliseconds(260))
        } catch {
            return false
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animation: Animation = reduceMotion
            ? .easeInOut(duration: 0.12)
            : .timingCurve(0.32, 0, 0.24, 1, duration: 0.36)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withAnimation(animation, completionCriteria: .removed) {
                update(.retracting)
            } completion: {
                continuation.resume()
            }
        }
        guard !Task.isCancelled else { return false }
        update(.hidden)
        return true
    }

    static func glyphEntrance(reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.12) }
        return .spring(duration: 0.36, bounce: 0.19).delay(0.04)
    }
}

struct LockBadgeSurface: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sizing: NotchSizing
    let phase: LockBadgePhase
    let playback: LockPlayback?
    let hovering: Bool

    var body: some View {
        let showsOutline = phase.inWing || phase == .music || phase == .fadingMusic
        let shoulder = showsOutline ? sizing.shoulder(for: .locked) : 0
        let lockedWidth = sizing.bodyWidth(for: .locked, playing: false)
        let height = sizing.hardwareHeight + sizing.topBleed
        let musicWidth = sizing.bodyWidth(for: .compact, playing: true)
        let activeWidth = playback == nil ? lockedWidth + LockBadgeMotion.leftMargin : musicWidth
        let width = showsOutline ? activeWidth : sizing.hardwareWidth
        let lifted = hovering && phase.inWing

        ZStack(alignment: .top) {
            NotchOutline(shoulder: shoulder, corner: sizing.compactCorner)
                .fill(.black)
                .frame(width: width + 2 * shoulder, height: height)
                .offset(x: showsOutline && playback == nil ? -LockBadgeMotion.leftMargin / 2 : 0)
                .shadow(color: .black.opacity(lifted ? 0.38 : 0), radius: 6, y: 5)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: phase.entered)

            if let playback {
                musicWings(playback, width: musicWidth, shoulder: sizing.shoulder(for: .locked), height: height)
            }

            lockGlyph(lockedWidth: lockedWidth)
        }
        .frame(width: LockBadgeMotion.width(for: sizing), height: height)
        .scaleEffect(x: lifted && !reduceMotion ? 1.04 : 1, y: lifted && !reduceMotion ? 1.08 : 1, anchor: .top)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .allowsHitTesting(false)
    }

    private func musicWings(_ playback: LockPlayback, width: CGFloat, shoulder: CGFloat, height: CGFloat) -> some View {
        let size = min(20, sizing.hardwareHeight - 8)
        return Color.clear
            .frame(width: width + 2 * shoulder, height: height)
            .overlay(alignment: .topLeading) {
                AlbumArtwork(image: playback.artwork, tint: playback.tint)
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: 4))
                    .offset(x: shoulder + 7, y: sizing.topBleed + (sizing.hardwareHeight - size) / 2)
            }
            .overlay(alignment: .topTrailing) {
                PlaybackPips(color: playback.tint, active: false)
                    .frame(height: sizing.hardwareHeight)
                    .padding(.top, sizing.topBleed)
                    .padding(.trailing, shoulder + 8)
            }
            .clipShape(NotchOutline(shoulder: shoulder, corner: sizing.compactCorner))
            .opacity(phase == .music ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: phase == .music)
            .accessibilityHidden(true)
    }

    private func lockGlyph(lockedWidth: CGFloat) -> some View {
        let wingWidth = (lockedWidth - sizing.hardwareWidth) / 2
        return ZStack(alignment: .topLeading) {
            PadlockShackle(openness: phase.open ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 1.55, lineCap: .round))
                .offset(y: 0.8)
                .animation(.easeInOut(duration: reduceMotion ? 0 : 0.20), value: phase.open)
            RoundedRectangle(cornerRadius: 2.1)
                .fill(.white)
                .frame(width: 11.8, height: 8.4)
                .position(x: 9, y: 13.7)
        }
        .frame(width: 18, height: 19)
        .frame(width: wingWidth, height: sizing.hardwareHeight)
        .offset(x: phase.inWing || reduceMotion ? 0 : wingWidth + 4)
        .opacity(phase.inWing ? 1 : 0)
        .blur(radius: phase == .retracting && !reduceMotion ? 2.6 : 0)
        // Keep the mask anchored to the camera housing even while the shape widens.
        .clipped()
        .frame(width: lockedWidth, alignment: .leading)
        .padding(.top, sizing.topBleed)
        .animation(LockBadgeMotion.glyphEntrance(reduceMotion: reduceMotion), value: phase.entered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.open ? "打开的白锁" : "白锁")
        .accessibilityHidden(!phase.inWing)
    }
}

private struct PadlockShackle: Shape {
    var openness: CGFloat

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let amount = min(1, max(0, openness))
        // Sweep the free end out to the right while the left stem stays seated.
        let left = 5.1 + 2.6 * amount
        let right = 13 + 3.9 * amount
        let top = 2.2 - 0.55 * amount
        let side = 6.4 - 0.25 * amount
        let end = 10.5 - 3.1 * amount
        var path = Path()
        path.move(to: CGPoint(x: left, y: 10.6))
        path.addLine(to: CGPoint(x: left, y: side))
        path.addCurve(to: CGPoint(x: right, y: side),
                      control1: CGPoint(x: left, y: top - 1.6),
                      control2: CGPoint(x: right, y: top - 1.6))
        path.addLine(to: CGPoint(x: right, y: end))
        return path
    }
}

@MainActor
@Observable
private final class LockBadgeState {
    var phase: LockBadgePhase = .hidden
    var playback: LockPlayback?
    var hovering = false
}

private struct LockBadgeWindowView: View {
    let sizing: NotchSizing
    let state: LockBadgeState

    var body: some View {
        LockBadgeSurface(sizing: sizing, phase: state.phase, playback: state.playback, hovering: state.hovering)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Owns the passive lock-screen window and the compositor Space used by the notch.
@MainActor
final class LockBadge {
    private var panel: TopAnchoredPanel?
    private var hosting: NSHostingView<LockBadgeWindowView>?
    private var presentedSizing: NotchSizing?
    private var presenting = false
    private var playbackStaged = false
    private var motionTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var hoverFrame = CGRect.zero
    private let state = LockBadgeState()
    private lazy var space = LockBadgeSpace()

    func attachDesktopPanel(_ window: TopAnchoredPanel) -> Bool {
        space?.attach(windowNumber: window.windowNumber) == true
    }

    /// Pre-render the lock transition without drawing a second desktop surface.
    func stagePlayback(on display: NotchDisplay, playback: LockPlayback) {
        guard !presenting, display.sizing.topBleed > 0 else { return }
        let needsDraw = !playbackStaged || state.playback != playback || presentedSizing != display.sizing
        if needsDraw {
            state.playback = playback
            state.phase = .music
        }
        guard let window = prepareWindow(on: display, redraw: needsDraw) else { return }
        window.alphaValue = 0
        if needsDraw { draw(window) }
        if !playbackStaged || !window.isVisible { window.orderFrontRegardless() }
        playbackStaged = true
    }

    func discardStagedPlayback() {
        guard !presenting, playbackStaged else { return }
        panel?.orderOut(nil)
        playbackStaged = false
        state.playback = nil
        state.phase = .hidden
    }

    @discardableResult
    func show(on display: NotchDisplay, playback: LockPlayback? = nil) -> Bool {
        guard display.sizing.topBleed > 0 else { return false }
        let needsEntry = !presenting || state.phase.open
        let ready = playbackStaged && state.playback == playback && presentedSizing == display.sizing
        let openingPhase: LockBadgePhase = playback == nil ? .hidden : .music
        let needsFirstFrame = needsEntry && (state.phase != openingPhase || state.playback != playback)
        if needsEntry {
            state.playback = playback
            state.phase = openingPhase
        }
        guard let window = prepareWindow(on: display, redraw: needsFirstFrame) else { return false }

        let sizing = display.sizing
        let height = sizing.hardwareHeight + sizing.topBleed
        let playing = state.playback != nil
        let hoverWidth = playing ? sizing.bodyWidth(for: .compact, playing: true)
            : sizing.bodyWidth(for: .locked, playing: false) + LockBadgeMotion.leftMargin
        hoverFrame = display.topFrame(size: CGSize(width: hoverWidth, height: height))
            .offsetBy(dx: playing ? 0 : -LockBadgeMotion.leftMargin / 2, dy: 0)
        if !ready { draw(window) }
        window.alphaValue = 1
        if !window.isVisible { window.orderFrontRegardless() }
        playbackStaged = false
        presenting = true
        if needsEntry {
            motionTask?.cancel()
            let openingPhase = state.phase
            motionTask = Task { [weak self] in
                await LockBadgeMotion.present(from: openingPhase) { self?.state.phase = $0 }
            }
        }
        startHover()
        return true
    }

    private func prepareWindow(on display: NotchDisplay, redraw: Bool) -> TopAnchoredPanel? {
        guard let space else { return nil }
        let sizing = display.sizing
        let window = panel ?? makePanel()
        if hosting == nil || presentedSizing != sizing {
            let view = NSHostingView(rootView: LockBadgeWindowView(sizing: sizing, state: state))
            window.contentView = view
            hosting = view
            presentedSizing = sizing
        } else if redraw {
            hosting?.rootView = LockBadgeWindowView(sizing: sizing, state: state)
        }

        let width = LockBadgeMotion.width(for: sizing)
        let height = sizing.hardwareHeight + sizing.topBleed
        let frame = display.topFrame(size: CGSize(
            width: width + 2 * LockBadgeMotion.shadowAllowance, height: height + LockBadgeMotion.shadowAllowance
        ))
        if window.frame != frame { window.setFrame(frame, display: false, animate: false) }
        if panel == nil {
            guard space.attach(windowNumber: window.windowNumber) else {
                window.orderOut(nil)
                hosting = nil
                presentedSizing = nil
                return nil
            }
            panel = window
        }
        return window
    }

    private func draw(_ window: TopAnchoredPanel) {
        hosting?.layoutSubtreeIfNeeded()
        window.display()
    }

    func retract() async {
        motionTask?.cancel()
        hoverTask?.cancel()
        guard presenting else { return }
        if state.phase.inWing {
            guard await LockBadgeMotion.retract({ state.phase = $0 }) else { return }
        }
        state.phase = .hidden
        panel?.alphaValue = 0
        panel?.orderOut(nil)
        presenting = false
        state.hovering = false
        state.playback = nil
    }

    func hide() {
        motionTask?.cancel()
        hoverTask?.cancel()
        state.hovering = false
        state.playback = nil
        state.phase = .hidden
        panel?.alphaValue = 0
        panel?.orderOut(nil)
        presenting = false
        playbackStaged = false
    }

    private func startHover() {
        hoverTask?.cancel()
        // The passive overlay cannot receive pointer events in the login window's session.
        hoverTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.panel?.isVisible == true {
                let hovering = self.hoverFrame.contains(NSEvent.mouseLocation)
                if self.state.hovering != hovering { self.state.hovering = hovering }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }

    private func makePanel() -> TopAnchoredPanel {
        let panel = TopAnchoredPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "NotchDay 锁屏标识"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.isReleasedWhenClosed = false
        return panel
    }
}

class TopAnchoredPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Runtime-only ABI, documented by SkyLightWindow. Only attaches our own noninteractive window.
private final class LockBadgeSpace {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Create = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias Level = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias Show = @convention(c) (Int32, CFArray) -> Int32
    private typealias Attach = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private let library: UnsafeMutableRawPointer
    private let connection: Int32
    private let space: Int32
    private let attachWindows: Attach

    init?() {
        let framework = "/System/Library/PrivateFrameworks/SkyLight.framework"
        guard let handle = dlopen(framework + "/Versions/A/SkyLight", RTLD_LAZY)
            ?? dlopen(framework + "/SkyLight", RTLD_LAZY) else { return nil }
        guard let connectionSymbol = dlsym(handle, "SLSMainConnectionID"),
              let createSymbol = dlsym(handle, "SLSSpaceCreate"),
              let levelSymbol = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let showSymbol = dlsym(handle, "SLSShowSpaces"),
              let attachSymbol = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else {
            dlclose(handle)
            return nil
        }

        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
        let space = unsafeBitCast(createSymbol, to: Create.self)(connection, 1, 0)
        let level = unsafeBitCast(levelSymbol, to: Level.self)
        let show = unsafeBitCast(showSymbol, to: Show.self)
        guard space > 0, level(connection, space, 400) == 0,
              show(connection, [NSNumber(value: space)] as CFArray) == 0 else {
            dlclose(handle)
            return nil
        }

        self.library = handle
        self.connection = connection
        self.space = space
        attachWindows = unsafeBitCast(attachSymbol, to: Attach.self)
    }

    deinit { dlclose(library) }

    func attach(windowNumber: Int) -> Bool {
        guard windowNumber > 0 else { return false }
        return attachWindows(connection, space, [NSNumber(value: windowNumber)] as CFArray, 7) == 0
    }
}
