import AppKit
import CoreGraphics
import Observation
import SwiftUI

enum LockBadgeMotion {
    static let dismissal: Duration = .milliseconds(280)

    static func glyph(revealed: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.12) }
        return revealed ? .spring(duration: 0.36, bounce: 0.19).delay(0.04) : .easeInOut(duration: 0.23)
    }

    static func outline(revealed: Bool, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return revealed ? .easeOut(duration: 0.25) : .easeInOut(duration: 0.23).delay(0.04)
    }

    static func bodyWidth(for sizing: NotchSizing, revealed: Bool, reduceMotion: Bool) -> CGFloat {
        revealed || reduceMotion ? sizing.bodyWidth(for: .locked, playing: false) : sizing.hardwareWidth
    }
}

struct LockBadgeGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sizing: NotchSizing
    let revealed: Bool

    var body: some View {
        let lockedWidth = sizing.bodyWidth(for: .locked, playing: false)
        let wingWidth = (lockedWidth - sizing.hardwareWidth) / 2
        Image(systemName: "lock.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: wingWidth, height: sizing.hardwareHeight)
            // This mask stays at the left edge of the physical camera housing.
            .offset(x: revealed || reduceMotion ? 0 : wingWidth)
            .opacity(revealed || !reduceMotion ? 1 : 0)
            .clipped()
            .frame(width: lockedWidth, alignment: .leading)
            .padding(.top, sizing.topBleed)
            .animation(LockBadgeMotion.glyph(revealed: revealed, reduceMotion: reduceMotion), value: revealed)
            .allowsHitTesting(false)
            .accessibilityLabel("白锁")
            .accessibilityHidden(!revealed)
    }
}

@MainActor
@Observable
private final class LockBadgeState {
    var revealed = false
}

private struct LockBadgeSurface: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sizing: NotchSizing
    let state: LockBadgeState

    var body: some View {
        let shoulder = sizing.shoulder(for: .locked)
        let width = LockBadgeMotion.bodyWidth(for: sizing, revealed: state.revealed, reduceMotion: reduceMotion)
        NotchOutline(shoulder: shoulder, corner: 11)
            .fill(.black)
            .frame(width: width + 2 * shoulder, height: sizing.hardwareHeight + sizing.topBleed)
            .overlay(alignment: .top) {
                LockBadgeGlyph(sizing: sizing, revealed: state.revealed)
            }
            .animation(LockBadgeMotion.outline(revealed: state.revealed, reduceMotion: reduceMotion), value: state.revealed)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Owns a passive lock-screen window. Desktop controls never enter the lock-screen space.
@MainActor
final class LockBadge {
    private var panel: TopAnchoredPanel?
    private var presentedSizing: NotchSizing?
    private var motionTask: Task<Void, Never>?
    private let state = LockBadgeState()
    private lazy var space = LockBadgeSpace()

    @discardableResult
    func show(on display: NotchDisplay) -> Bool {
        let sizing = display.sizing
        guard sizing.topBleed > 0, let space else { return false }

        let shoulder = sizing.shoulder(for: .locked)
        let width = sizing.bodyWidth(for: .locked, playing: false) + 2 * shoulder
        let height = sizing.hardwareHeight + sizing.topBleed
        let frame = display.topFrame(size: CGSize(width: width, height: height))
        let window = panel ?? makePanel()
        if presentedSizing != sizing {
            window.contentView = NSHostingView(rootView: LockBadgeSurface(sizing: sizing, state: state))
            presentedSizing = sizing
        }
        window.setFrame(frame, display: true, animate: false)
        if panel == nil {
            guard space.attach(windowNumber: window.windowNumber) else {
                window.orderOut(nil)
                presentedSizing = nil
                return false
            }
            panel = window
        }
        motionTask?.cancel()
        let alreadyVisible = window.isVisible
        window.orderFrontRegardless()
        if alreadyVisible {
            state.revealed = true
        } else {
            motionTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
                self?.state.revealed = true
            }
        }
        return true
    }

    func retract() async {
        motionTask?.cancel()
        guard panel?.isVisible == true else { return }
        state.revealed = false
        do { try await Task.sleep(for: LockBadgeMotion.dismissal) } catch { return }
        panel?.orderOut(nil)
    }

    func hide() {
        motionTask?.cancel()
        state.revealed = false
        panel?.orderOut(nil)
    }

    private func makePanel() -> TopAnchoredPanel {
        let panel = TopAnchoredPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "NotchDay 锁屏标识"
        panel.isOpaque = false
        panel.backgroundColor = .clear
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
