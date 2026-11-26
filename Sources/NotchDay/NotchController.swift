import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class NotchController: NSObject {
    private let model = NotchModel()
    private let calendar = CalendarFeed()
    private let activity = ActivityFeed()
    private let storage = StorageFeed()
    private let lockBadge = LockBadge()
    private var panel: NotchPanel?
    private var settingsWindow: NSWindow?
    private var display: NotchDisplay?
    private var desktopPanelFollowsNotch = false
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var pendingHover: Task<Void, Never>?
    private var pendingRestore: Task<Void, Never>?
    private var pendingLockHandoff: Task<Void, Never>?
    private var pendingPreviewMotion: Task<Void, Never>?
    private var lockedWatch: Task<Void, Never>?
    private var systemLocked = false
    private var restoring = false
    private var suppressHover = false
    private var wheelGesture = NotchWheelGesture()
    private lazy var desktopSpaces = DesktopSpaces()

    func start() {
        calendar.start()
        model.music.changed = { [weak self] in
            self?.prepareLockPlayback()
            self?.updatePointer()
        }
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
    }

    func stop() {
        calendar.stop()
        model.music.stop()
        storage.deactivate()
        pendingHover?.cancel()
        pendingRestore?.cancel()
        pendingLockHandoff?.cancel()
        pendingPreviewMotion?.cancel()
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
        if !systemLocked, Self.systemLockStatus == true {
            screenLocked()
            return
        }
        if systemLocked {
            if let current = NotchDisplay.preferred(), current.hasHardwareNotch, current != display {
                display = current
                lockBadge.show(on: current)
            }
            return
        }
        guard let display = NotchDisplay.preferred() else {
            panel?.orderOut(nil)
            lockBadge.discardStagedPlayback()
            self.display = nil
            return
        }

        let sizingChanged = self.display?.sizing != display.sizing
        self.display = display
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if sizingChanged || !(panel.contentView is NSHostingView<NotchView>) {
            let view = NotchView(
                model: model,
                calendar: calendar,
                activity: activity,
                storage: storage,
                sizing: display.sizing,
                toggleExpanded: { [weak self] in self?.toggleExpanded() },
                seekingChanged: { [weak self] active in self?.setSeeking(active) },
                playbackChanged: { [weak self] in self?.updatePointer() },
                selectPage: { [weak self] page in self?.selectPage(page) }
            )
            panel.contentView = NSHostingView(rootView: view)
        }
        if panel.frame != display.panelFrame { panel.setFrame(display.panelFrame, display: true, animate: false) }
        if !desktopPanelFollowsNotch, display.hasHardwareNotch {
            let fallback = panel.collectionBehavior
            panel.collectionBehavior = [.ignoresCycle]
            desktopPanelFollowsNotch = lockBadge.attachDesktopPanel(panel)
            if !desktopPanelFollowsNotch { panel.collectionBehavior = fallback }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        prepareLockPlayback()
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
        panel.collectionBehavior = [.managed, .moveToActiveSpace, .ignoresCycle, .fullScreenAuxiliary]
        panel.acceptsDesktopInput = { [weak self] in
            guard let self else { return false }
            return !self.systemLocked && !self.restoring && Self.systemLockStatus != true
        }
        panel.handleScroll = { [weak self] event in self?.handleScroll(event) ?? false }
        panel.openSettings = { [weak self] in self?.openSettings() }
        panel.closeIsland = { [weak self] in self?.collapseExplicitly() }
        return panel
    }

    private func hitRegion() -> CGRect? {
        guard let display else { return nil }
        let sizing = display.sizing
        let location = display.anchor
        let height = sizing.depth(
            for: model.mode, page: model.page, scheduleRows: calendar.maximumRowCount,
            pages: model.visiblePages.count
        )
        let lockHasMusicWidth = model.mode == .locked && model.lockPlaybackPreview != nil
        let width = lockHasMusicWidth ? sizing.bodyWidth(for: .compact, playing: true)
            : sizing.bodyWidth(for: model.mode, playing: model.showsCompactPlayback)
        let leftMargin = model.mode == .locked && !lockHasMusicWidth ? LockBadgeMotion.leftMargin : 0
        return CGRect(x: location.x - width / 2 - leftMargin, y: location.y - height, width: width + leftMargin, height: height)
    }

    private func updatePointer() {
        guard !systemLocked, !restoring, model.desktopWingsVisible,
              let panel, let bounds = hitRegion() else { return }
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
        let playback = lockPlayback()
        systemLocked = true
        restoring = false
        pendingRestore?.cancel()
        pendingLockHandoff?.cancel()
        pendingPreviewMotion?.cancel()
        pendingHover?.cancel()
        panel?.ignoresMouseEvents = true
        model.isSeeking = false
        model.isHovering = false
        model.music.setVisible(false)
        if model.mode != .compact { panel?.orderOut(nil) }
        let geometry = display ?? NotchDisplay.preferred()
        let showedLockBadge = geometry.map { lockBadge.show(on: $0, playback: playback) } ?? false
        if showedLockBadge, playback != nil, model.mode == .compact {
            // Let the pre-rendered lock window reach the compositor before retiring the matching desktop frame.
            pendingLockHandoff = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                self?.retireDesktopForLock()
            }
        } else {
            retireDesktopForLock()
        }

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

    private func retireDesktopForLock() {
        panel?.orderOut(nil)
        model.desktopWingsVisible = false
        model.lockPreview = .hidden
        model.lockPlaybackPreview = nil
        model.mode = .compact
    }

    @objc private func screenUnlocked() {
        guard systemLocked else { return }
        pendingLockHandoff?.cancel()
        retireDesktopForLock()
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
                    let canUseCurrent = self.display?.hasHardwareNotch != true || current?.hasHardwareNotch == true
                    if let current, current == prior, canUseCurrent { break }
                    prior = current
                    try await Task.sleep(for: .milliseconds(150))
                }
                guard let self, !self.systemLocked else { return }
                self.restoring = false
                try await self.restoreDesktopWings()
            } catch {
                return
            }
        }
    }

    @objc private func activeSpaceChanged() {
        guard !systemLocked, !restoring else { return }
        if Self.systemLockStatus == true {
            screenLocked()
            return
        }
        movePanelToCurrentSpace()
    }

    private func movePanelToCurrentSpace() {
        guard !desktopPanelFollowsNotch, let panel, let display, !panel.isOnActiveSpace else { return }
        desktopSpaces?.moveWindowToActiveSpace(windowNumber: panel.windowNumber, on: display.spaceIdentifier)
        if !panel.isOnActiveSpace { panel.orderFrontRegardless() }
    }

    private func restoreDesktopWings() async throws {
        suppressHover = true
        refreshDisplay()
        // Mount the narrow shape for one frame before widening it and fading in the artwork.
        try await Task.sleep(for: .milliseconds(45))
        guard !systemLocked else { return }
        model.desktopWingsVisible = true
        prepareLockPlayback()
        updatePointer()
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
        guard model.mode != .locked, model.desktopWingsVisible else { return }
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
        if mode != .expanded {
            wheelGesture = NotchWheelGesture()
            panel?.resignKey()
        }
        updatePointer()
    }

    private func selectPage(_ page: NotchPage) {
        guard model.mode == .expanded, page != model.page else { return }
        if page == .schedule { calendar.refresh() }
        model.page = page
        updatePointer()
    }

    private func setSeeking(_ isSeeking: Bool) {
        model.isSeeking = isSeeking
        updatePointer()
        updateHoverAction()
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard model.mode == .expanded, !model.isSeeking else { return false }

        let movement = NotchWheelGesture.Movement(
            dx: event.scrollingDeltaX,
            dy: event.scrollingDeltaY,
            timestamp: event.timestamp,
            startsGesture: event.phase == .began,
            isUnphased: event.phase.isEmpty,
            isMomentum: !event.momentumPhase.isEmpty,
            isPrecise: event.hasPreciseScrollingDeltas
        )
        // Resolve the calendar's scroll priority lazily, only at the start of a gesture.
        let action = wheelGesture.handle(movement) { [self] isHorizontal in
            if isHorizontal { return model.page == .music ? .songs : .native }
            return agendaUsesScroll(event, earlier: movement.dy > 0) ? .native : .pages
        }
        switch action {
        case .forward:
            return false
        case .consume:
            break
        case let .changeTrack(step):
            model.changeTrack(by: step)
        case let .selectPage(step):
            let pages = model.visiblePages
            if let index = pages.firstIndex(of: model.page), pages.indices.contains(index + step) {
                selectPage(pages[index + step])
            }
        }
        return true
    }

    private func agendaUsesScroll(_ event: NSEvent, earlier: Bool) -> Bool {
        guard model.page == .schedule, let panel, let display else { return false }
        let sizing = display.sizing
        let rows = calendar.maximumRowCount
        guard AgendaLayout.contentHeight(rows: rows) > sizing.scheduleViewport(rows: rows) else { return false }

        let leftOfBody = (panel.frame.width - sizing.expandedWidth) / 2
        guard event.locationInWindow.x >= leftOfBody + NotchSizing.cardInset else { return false }
        return earlier ? model.agendaScrollEdges.canGoEarlier : model.agendaScrollEdges.canGoLater
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
        guard !systemLocked, !restoring, model.desktopWingsVisible,
              model.mode != .locked || model.lockPreview == .locked else { return }
        suppressHover = true
        pendingPreviewMotion?.cancel()
        if model.lockPreview == .locked {
            pendingPreviewMotion = Task { [weak self] in
                guard let self, await LockBadgeMotion.retract({ self.model.lockPreview = $0 }) else { return }
                self.model.lockPlaybackPreview = nil
                self.model.desktopWingsVisible = false
                self.setMode(.compact)
                try? await self.restoreDesktopWings()
            }
        } else {
            model.lockPlaybackPreview = lockPlayback()
            let phase: LockBadgePhase = model.lockPlaybackPreview == nil ? .hidden : .music
            model.lockPreview = phase
            setMode(.locked)
            pendingPreviewMotion = Task { [weak self] in
                await LockBadgeMotion.present(from: phase) { self?.model.lockPreview = $0 }
            }
        }
    }

    private func lockPlayback() -> LockPlayback? {
        model.isPlaying ? LockPlayback(artwork: model.music.artwork, tint: model.musicTint) : nil
    }

    private func prepareLockPlayback() {
        guard !systemLocked, !restoring else { return }
        if model.desktopWingsVisible,
           let display, let playback = lockPlayback(), display.hasHardwareNotch {
            lockBadge.stagePlayback(on: display, playback: playback)
        } else {
            lockBadge.discardStagedPlayback()
        }
    }
}

@MainActor
private final class NotchPanel: TopAnchoredPanel {
    var acceptsDesktopInput: (() -> Bool)?
    var handleScroll: ((NSEvent) -> Bool)?
    var openSettings: (() -> Void)?
    var closeIsland: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        guard acceptsDesktopInput?() != false else { return }
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
    let spaceIdentifier: String?
    let hasHardwareNotch: Bool

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

    static func availableTopBleed(above frame: CGRect, screenFrames: [CGRect]) -> CGFloat {
        let maximum: CGFloat = 4
        // AppKit uses a shared desktop. The overscan strip can land on a screen above this one.
        return screenFrames.reduce(maximum) { available, other in
            guard other.maxY > frame.maxY, other.maxX > frame.minX, other.minX < frame.maxX else { return available }
            return min(available, max(0, other.minY - frame.maxY).rounded(.down))
        }
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
        let hasHardwareNotch = notched != nil
        var width: CGFloat = 136
        var anchorX = frame.midX
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, right.minX > left.maxX {
            width = right.minX - left.maxX
            anchorX = (right.minX + left.maxX) / 2
        }
        let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let uuid = displayNumber.flatMap { CGDisplayCreateUUIDFromDisplayID($0.uint32Value)?.takeRetainedValue() }
        let spaceIdentifier = NSScreen.screensHaveSeparateSpaces ? uuid.map { CFUUIDCreateString(nil, $0) as String } : "Main"
        return NotchDisplay(
            anchor: CGPoint(x: anchorX, y: frame.maxY),
            sizing: NotchSizing(
                hardwareWidth: width,
                hardwareHeight: max(screen.safeAreaInsets.top, NSStatusBar.system.thickness),
                availableWidth: max(220, frame.width - 50),
                screenHeight: frame.height,
                topBleed: hasHardwareNotch ? availableTopBleed(above: frame, screenFrames: screens.map(\.frame)) : 0
            ),
            spaceIdentifier: spaceIdentifier,
            hasHardwareNotch: hasHardwareNotch
        )
    }
}
