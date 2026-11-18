import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class NotchController: NSObject {
    private let model = NotchModel()
    private let calendar = CalendarFeed()
    private let lockBadge = LockBadge()
    private var panel: NotchPanel?
    private var settingsWindow: NSWindow?
    private var display: NotchDisplay?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var pendingHover: Task<Void, Never>?
    private var pendingRestore: Task<Void, Never>?
    private var pendingPreviewRetraction: Task<Void, Never>?
    private var lockedWatch: Task<Void, Never>?
    private var systemLocked = false
    private var restoring = false
    private var suppressHover = false
    private var scrollDistance: CGFloat = 0
    private var scrollTime: TimeInterval = 0
    private var consumedScroll = false

    func start() {
        calendar.start()
        model.music.changed = { [weak self] in self?.updatePointer() }
        model.music.start()
        if Self.systemLockStatus == true {
            screenLocked()
        } else {
            refreshDisplay()
        }
        let motion: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: motion) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: motion) { [weak self] event in
            MainActor.assumeIsolated { self?.updatePointer() }
            return event
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshDisplay),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenLocked), name: .init("com.apple.screenIsLocked"), object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenUnlocked), name: .init("com.apple.screenIsUnlocked"), object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayWoke), name: NSWorkspace.screensDidWakeNotification, object: nil
        )
    }

    func stop() {
        calendar.stop()
        model.music.stop()
        pendingHover?.cancel()
        pendingRestore?.cancel()
        pendingPreviewRetraction?.cancel()
        lockedWatch?.cancel()
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        lockBadge.hide()
        panel?.orderOut(nil)
    }

    func refreshCalendar() {
        calendar.refresh()
    }

    @objc private func refreshDisplay() {
        guard !restoring else { return }
        if systemLocked {
            if let current = NotchDisplay.preferred(), current.sizing.topBleed > 0, current != display {
                display = current
                lockBadge.show(on: current)
            }
            return
        }
        guard let display = NotchDisplay.preferred() else {
            panel?.orderOut(nil)
            self.display = nil
            return
        }

        self.display = display
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let view = NotchView(
            model: model,
            calendar: calendar,
            sizing: display.sizing,
            toggleExpanded: { [weak self] in self?.toggleExpanded() },
            seekingChanged: { [weak self] active in self?.setSeeking(active) },
            playbackChanged: { [weak self] in self?.updatePointer() }
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.setFrame(display.panelFrame, display: true, animate: false)
        panel.orderFrontRegardless()
        updatePointer()
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "NotchDay"
        panel.identifier = NSUserInterfaceItemIdentifier("NotchDay.Island")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        panel.handleScroll = { [weak self] event in self?.handleScroll(event) ?? false }
        panel.openSettings = { [weak self] in self?.openSettings() }
        panel.closeIsland = { [weak self] in self?.collapseExplicitly() }
        return panel
    }

    private func hitRegion() -> CGRect? {
        guard let display else { return nil }
        let sizing = display.sizing
        let location = display.anchor
        let width = sizing.bodyWidth(for: model.mode, playing: model.isPlaying)
        let height = sizing.depth(for: model.mode, page: model.page, scheduleRows: calendar.maximumRowCount)
        return CGRect(x: location.x - width / 2, y: location.y - height, width: width, height: height)
    }

    private func updatePointer() {
        guard !systemLocked, !restoring, let panel, let bounds = hitRegion() else { return }
        let containsPointer = bounds.contains(NSEvent.mouseLocation)
        let acceptsPointer = containsPointer || model.isSeeking
        let ignoresPointer = !acceptsPointer
        if panel.ignoresMouseEvents != ignoresPointer {
            panel.ignoresMouseEvents = ignoresPointer
        }
        let previous = model.isHovering
        if previous != containsPointer {
            model.isHovering = containsPointer
        }
        if !containsPointer { suppressHover = false }
        guard containsPointer != previous else { return }
        updateHoverAction()
    }

    private static var systemLockStatus: Bool? {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool
    }

    @objc private func screenLocked() {
        guard !systemLocked else { return }
        systemLocked = true
        restoring = false
        pendingRestore?.cancel()
        pendingPreviewRetraction?.cancel()
        pendingHover?.cancel()
        panel?.orderOut(nil)
        model.lockPreviewRevealed = false
        model.mode = .compact
        model.isSeeking = false
        model.isHovering = false
        model.music.setVisible(false)
        if let geometry = display ?? NotchDisplay.preferred() { lockBadge.show(on: geometry) }

        // Limit the fallback check to the locked session in case a wake delays the unlock notice.
        lockedWatch?.cancel()
        lockedWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.systemLocked else { return }
                if Self.systemLockStatus == false {
                    self.screenUnlocked()
                    return
                }
            }
        }
    }

    @objc private func screenUnlocked() {
        guard systemLocked else { return }
        systemLocked = false
        lockedWatch?.cancel()
        restoring = true
        pendingRestore?.cancel()
        pendingRestore = Task { [weak self] in
            do {
                guard let badge = self?.lockBadge else { return }
                await badge.retract()
                try await Task.sleep(for: .milliseconds(180))
                var prior: NotchDisplay?
                for _ in 0..<10 {
                    guard let self, !self.systemLocked else { return }
                    let current = NotchDisplay.preferred()
                    let canUseCurrent = self.display?.sizing.topBleed == 0 || current?.sizing.topBleed == 4
                    if let current, current == prior, canUseCurrent { break }
                    prior = current
                    try await Task.sleep(for: .milliseconds(150))
                }
                guard let self, !self.systemLocked else { return }
                self.restoring = false
                self.suppressHover = true
                self.refreshDisplay()
            } catch {
                return
            }
        }
    }

    @objc private func displayWoke() {
        if Self.systemLockStatus == true {
            if !systemLocked { screenLocked() }
            else if let display { lockBadge.show(on: display) }
        } else if !systemLocked && !restoring {
            refreshDisplay()
        }
    }

    private func updateHoverAction() {
        pendingHover?.cancel()
        guard !model.isSeeking, model.mode != .locked else { return }
        let isInside = model.isHovering
        if isInside && (model.mode == .expanded || suppressHover) { return }
        if !isInside && model.mode != .expanded { return }
        pendingHover = Task { [weak self] in
            do {
                try await Task.sleep(for: isInside ? .milliseconds(150) : .milliseconds(240))
            } catch {
                return
            }
            guard let self, self.model.isHovering == isInside else { return }
            self.setMode(isInside ? .expanded : .compact)
        }
    }

    private func toggleExpanded() {
        guard model.mode != .locked else { return }
        if model.mode == .expanded {
            collapseExplicitly()
        } else {
            setMode(.expanded)
            panel?.makeKey()
        }
    }

    private func collapseExplicitly() {
        guard model.mode == .expanded else { return }
        suppressHover = model.isHovering
        setMode(.compact)
    }

    private func setMode(_ mode: NotchMode) {
        pendingHover?.cancel()
        guard model.mode != mode else { return }
        model.mode = mode
        if mode == .expanded && model.page == .schedule { calendar.refresh() }
        if mode != .expanded { panel?.resignKey() }
        updatePointer()
    }

    private func setSeeking(_ isSeeking: Bool) {
        model.isSeeking = isSeeking
        updatePointer()
        updateHoverAction()
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard model.mode == .expanded, model.page == .music, !model.isSeeking,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        else { return false }

        if !event.momentumPhase.isEmpty { return true }
        if event.phase == .began || event.timestamp - scrollTime > 0.22 {
            scrollDistance = 0
            consumedScroll = false
        }
        scrollTime = event.timestamp
        scrollDistance += event.scrollingDeltaX
        if !consumedScroll, abs(scrollDistance) >= 40 {
            consumedScroll = true
            model.changeTrack(by: scrollDistance > 0 ? 1 : -1)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        return true
    }

    private func openSettings() {
        pendingHover?.cancel()
        suppressHover = true
        if model.mode == .expanded { setMode(.compact) }
        calendar.refresh()

        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let controller = NSHostingController(rootView: NotchSettingsView(
            calendar: calendar,
            model: model,
            toggleLockPreview: { [weak self] in self?.toggleLockPreview() }
        ))
        let window = NSWindow(contentViewController: controller)
        window.title = "NotchDay 设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    @objc private func toggleLockPreview() {
        guard !systemLocked, !restoring else { return }
        suppressHover = true
        pendingPreviewRetraction?.cancel()
        if model.lockPreviewRevealed {
            model.lockPreviewRevealed = false
            pendingPreviewRetraction = Task { [weak self] in
                do { try await Task.sleep(for: LockBadgeMotion.dismissal) } catch { return }
                self?.setMode(.compact)
            }
        } else {
            setMode(.locked)
            model.lockPreviewRevealed = true
        }
    }
}

@MainActor
private final class NotchPanel: TopAnchoredPanel {
    var handleScroll: ((NSEvent) -> Bool)?
    var openSettings: (() -> Void)?
    var closeIsland: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .scrollWheel where handleScroll?(event) == true:
            return
        case .rightMouseDown:
            openSettings?()
        case .keyDown where event.keyCode == 53:
            closeIsland?()
        default:
            super.sendEvent(event)
        }
    }
}

struct NotchDisplay: Equatable {
    let anchor: CGPoint
    let sizing: NotchSizing

    var panelFrame: CGRect {
        let size = sizing.maximumSize
        return topFrame(size: CGSize(width: size.width, height: size.height + sizing.topBleed))
    }

    func topFrame(size: CGSize) -> CGRect {
        return CGRect(
            x: anchor.x - size.width / 2, y: anchor.y + sizing.topBleed - size.height,
            width: size.width, height: size.height
        )
    }

    @MainActor
    static func preferred() -> NotchDisplay? {
        let screens = NSScreen.screens
        let builtIn = screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }
        let notched = screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
        guard let screen = notched ?? builtIn ?? NSScreen.main else { return nil }
        let frame = screen.frame
        var width: CGFloat = 136
        var anchorX = frame.midX
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
            width = right.minX - left.maxX
            anchorX = (right.minX + left.maxX) / 2
        }
        return NotchDisplay(
            anchor: CGPoint(x: anchorX, y: frame.maxY),
            sizing: NotchSizing(
                hardwareWidth: width,
                hardwareHeight: max(screen.safeAreaInsets.top, NSStatusBar.system.thickness),
                availableWidth: max(220, frame.width - 50),
                screenHeight: frame.height,
                topBleed: screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil ? 4 : 0
            )
        )
    }
}
