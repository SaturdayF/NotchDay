import AppKit
import Combine
import QuartzCore

/// Identity of the built-in display. `NSApplication` posts a screen change for
/// a backlight change too, and this tells the two apart.
struct Layout: Equatable {
    var displayID: CGDirectDisplayID?
    var frame: CGRect?
}

/// Watches the lid angle and drives the depth effect overlay.
///
/// A timer polls the sensor, and a display link advances a spring at the
/// screen refresh rate so the ramp stays smooth between readings.
///
/// Ported from Mac-Duo's `LidController`, Apache License 2.0.
@MainActor
final class DepthController: ObservableObject {

    @Published private(set) var currentAngle: Double = 0
    @Published private(set) var isSensorAvailable = false
    @Published private(set) var isActive = false
    @Published private(set) var hasScreenPermission = false

    var captureIsland: ((NSScreen) -> DepthIslandPicture?)?
    var onIslandComposited: ((Bool) -> Void)?

    private let preferences: DepthPreferences
    private let sensor = LidAngleSensor()
    private let overlay = DepthOverlay()
    private let streamer = ScreenStreamer()
    private let snapshotter = ScreenSnapshotter()

    private var preferencesObservation: AnyCancellable?
    private var nextCaptureAttempt: CFTimeInterval = 0
    private var pictureTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var lastPublishTime: CFTimeInterval = 0

    private var rawAngle: Double = 0
    /// Degrees per second, negative while the lid closes.
    private var angularVelocity: Double = 0
    private var lastChangedAngle: Double?
    private var lastChangeTime: CFTimeInterval = 0
    private var lastClosingTime: CFTimeInterval = -.greatestFiniteMagnitude
    private var visualAngle = CriticallyDampedSpring()
    private var consecutiveFailedReads = 0
    private var startedAt: CFTimeInterval = 0
    private var preview: PreviewRun?
    private var lidAngleBeforeSleep: Double?
    private var openingWake: LidWakeOpening?
    private var openingStartedAt: CFTimeInterval?
    private var isSuspended = false
    private var isDisplaySleeping = false
    private var isSessionLocked = false
    private var isCapturePending = false
    private var motionIntent = LidMotionIntent()
    private var openDwell = LidOpenDwell()
    /// Where the lid last moved to by more than `timeoutMovementThreshold`,
    /// and when. The timeout counts from there.
    private var timeoutReferenceAngle: Double?
    private var timeoutReferenceTime: CFTimeInterval = 0
    /// Set when the timeout ends the effect, cleared once the lid rises back
    /// above the threshold. Closing further from the same resting spot must
    /// not retrigger it.
    private var timeoutAwaitingRelease = false
    /// The setting as last seen, so flipping it drops stale tracking.
    private var wasTimeoutEnabled = false
    /// True while `beginClosingOut()` is easing the picture back to flat.
    private var isClosingOut = false
    private var closingOutStartedAt: CFTimeInterval = 0
    private var builtInLayout = Layout()
    private var peakAngle: Double = 0
    /// The lowest reading since the effect started. Opening releases only
    /// once the lid has risen `LidEffectPolicy.minimumReleaseRise` above it.
    private var lowestRunAngle: Double = 0
    private static let idlePollInterval: TimeInterval = 1.0 / 8
    private static let relaxedPollInterval: TimeInterval = 1.0 / 6
    private static let activePollInterval: TimeInterval = 1.0 / 30
    private static let fadeInDuration: TimeInterval = 0.07
    private static let captureRetryInterval: TimeInterval = 0.5
    private static let openingWakeWindow: TimeInterval = 1.25
    private static let openingFrameDeadline: TimeInterval = 0.4
    private static let openingRunLimit: TimeInterval = 2.5

    /// Closing speed that counts as a deliberate close, in degrees per second.
    /// A still lid reads under 0.5.
    private static let triggerClosingSpeed: Double = 2

    /// Opening speed that counts as a deliberate reversal, in degrees per second.
    private static let triggerOpeningSpeed: Double = 2

    /// How long after the lid last moved down the effect may still start.
    private static let closingMemory: TimeInterval = 1.5

    private static let predictionSpeedFloor: Double = 40

    /// Sensor latency the prediction adds on top of the reading's own age.
    private static let predictionLatency: TimeInterval = 0.04

    /// The ordinary hysteresis release waits this long. A prediction can fire
    /// while the last reading is still above the trigger angle, but deliberate
    /// opening is allowed to release immediately.
    private static let minimumEffectDuration: TimeInterval = 0.35

    /// How long a lid held above the start angle waits before it counts as
    /// opened again, for openings slower than `triggerOpeningSpeed`.
    private static let openDwellDuration: TimeInterval = 1

    /// Movement within this many degrees counts as holding still.
    private static let timeoutMovementThreshold: Double = 2

    /// How long the lid has to hold still before the timeout ends the effect.
    private static let timeoutStillDuration: TimeInterval = 2

    /// How close the eased angle must get to flat before the last frame
    /// snaps there. Half a degree short, the dim curve still darkens the top
    /// of the picture by several percent, and the fade would then reveal a
    /// brighter screen underneath.
    private static let closingOutSettleEpsilon: Double = 0.05

    /// Safety cap, in case the spring never quite settles.
    private static let closingOutMaxDuration: TimeInterval = 1.2

    /// A scripted angle sweep, so the settings panel can show the effect
    /// without the lid moving. It feeds the same path the sensor feeds.
    private struct PreviewRun {
        let startedAt: CFTimeInterval
        let open: Double
        let shut: Double
        var openingOnly = false
        let closing: CFTimeInterval = 1.4
        let hold: CFTimeInterval = 0.8
        let opening: CFTimeInterval = 0.6

        /// `nil` once the run is over.
        func angle(at now: CFTimeInterval) -> Double? {
            let elapsed = now - startedAt
            if openingOnly {
                let duration = 0.95
                guard elapsed < duration else { return nil }
                return shut + (open - shut) * elapsed / duration
            }
            if elapsed < closing { return open + (shut - open) * (elapsed / closing) }
            if elapsed < closing + hold { return shut }
            if elapsed < closing + hold + opening {
                return shut + (open - shut) * ((elapsed - closing - hold) / opening)
            }
            return nil
        }
    }

    init(preferences: DepthPreferences) {
        self.preferences = preferences
        overlay.onIslandComposited = { [weak self] in self?.onIslandComposited?($0) }
    }

    // MARK: - Lifecycle

    func start() {
        isSensorAvailable = sensor.isAvailable
        guard isSensorAvailable else { return }

        if let angle = sensor.angle() {
            rawAngle = angle
            currentAngle = angle
            visualAngle.reset(to: angle)
        }
        // Before the first poll, which reads it.
        builtInLayout = Layout(displayID: NSScreen.builtIn?.displayID, frame: NSScreen.builtIn?.frame)
        observeSystemEvents()
        preferencesObservation = preferences.$isEnabled
            .combineLatest(preferences.$isLivePicture)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .dropFirst()
            .sink { [weak self] enabled, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !enabled { self.openingWake = nil }
                    self.disableEffect()
                    self.updatePolling(enabled: enabled)
                }
            }
        refreshScreenPermission()
    }

    func stop() {
        preferencesObservation?.cancel()
        preferencesObservation = nil
        setPollInterval(0)
        openingWake = nil
        stopEffectAndCapture()
    }

    func refreshScreenPermission() {
        let allowed = CGPreflightScreenCaptureAccess()
        if hasScreenPermission != allowed { hasScreenPermission = allowed }
        if !allowed {
            openingWake = nil
            if pollTimer != nil { disableEffect() }
        }
        updatePolling(enabled: preferences.isEnabled)
    }

    func setSessionLocked(_ locked: Bool) {
        isSessionLocked = locked
        if locked { disableEffect() }
        updatePolling(enabled: preferences.isEnabled)
    }

    private func updatePolling(enabled: Bool) {
        let canPoll = enabled && hasScreenPermission && isSensorAvailable
            && !isSuspended && !isDisplaySleeping && !isSessionLocked && builtInLayout.displayID != nil
        if !canPoll { setPollInterval(0) }
        else if pollTimer == nil {
            setPollInterval(openingWake == nil ? Self.idlePollInterval : Self.activePollInterval)
        }
    }

    private func stopEffectAndCapture() {
        pictureTask?.cancel()
        pictureTask = nil
        isCapturePending = false
        openingStartedAt = nil
        isClosingOut = false
        stopDisplayLink()
        overlay.dismiss(animated: false)
        snapshotter.stop()
        streamer.stop()
        overlay.releasePresence()
        preview = nil
        isActive = false
    }

    private func disableEffect() {
        stopEffectAndCapture()
        lastChangedAngle = nil
        angularVelocity = 0
        lastClosingTime = -.greatestFiniteMagnitude
        motionIntent.reset()
        openDwell.reset()
        peakAngle = 0
        timeoutReferenceAngle = nil
        timeoutAwaitingRelease = false
        nextCaptureAttempt = 0
        if pollTimer != nil { setPollInterval(Self.idlePollInterval) }
    }

    /// Plays the effect once on the current screen contents.
    func runPreview(opening: Bool = false) {
        refreshScreenPermission()
        guard pollTimer != nil, preview == nil, !isActive, !isClosingOut else { return }
        guard !opening || preferences.isOpeningEnabled else { return }
        // Well above the trigger angle, so the sweep runs the pre-warm the way
        // a real close does.
        let now = CACurrentMediaTime()
        let run = PreviewRun(
            startedAt: now,
            open: max(
                preferences.thresholdAngle + preferences.hysteresis + 5,
                min(preferences.thresholdAngle + 35, 130)
            ),
            shut: max(preferences.thresholdAngle - preferences.blurSpan * 1.15, opening ? 0 : 5),
            openingOnly: opening
        )
        preview = run
        openingWake = opening ? LidWakeOpening(deadline: now + Self.openingWakeWindow, lowestAngle: run.shut) : nil
        setPollInterval(Self.activePollInterval)
    }

    // MARK: - Polling

    private func setPollInterval(_ interval: TimeInterval) {
        guard pollInterval != interval else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        pollTimer = nil
        guard interval > 0 else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        let now = CACurrentMediaTime()
        if let wake = openingWake, now >= wake.deadline || !preferences.isOpeningEnabled {
            openingWake = nil
        }
        if let started = openingStartedAt {
            if !preferences.isOpeningEnabled
                || (!overlay.hasPresentedPicture
                    && (now - started >= Self.openingFrameDeadline || (!isCapturePending && !overlay.isVisible))) {
                disableEffect()
            } else if now - started >= Self.openingRunLimit {
                setActive(false)
            }
        }
        let angle: Double
        if let run = preview {
            guard let scripted = run.angle(at: CACurrentMediaTime()) else {
                preview = nil
                openingWake = nil
                if isActive { setActive(false) }
                peakAngle = 0
                lastChangedAngle = nil
                angularVelocity = 0
                lastClosingTime = -.greatestFiniteMagnitude
                motionIntent.reset()
                return
            }
            angle = scripted
        } else {
            guard let read = sensor.angle() else {
                consecutiveFailedReads += 1
                if consecutiveFailedReads > 30, isActive {
                    DepthLog.lid.notice(
                        """
                        release: sensor read failed \(self.consecutiveFailedReads) times in a row, \
                        last angle \(self.rawAngle, format: .fixed(precision: 2))
                        """
                    )
                    setActive(false)
                }
                return
            }
            if consecutiveFailedReads > 0 {
                DepthLog.lid.notice(
                    "sensor recovered after \(self.consecutiveFailedReads) failed reads, angle \(read, format: .fixed(precision: 2))"
                )
            }
            consecutiveFailedReads = 0
            angle = read
        }

        rawAngle = angle
        peakAngle = max(peakAngle, angle)
        if isActive { lowestRunAngle = min(lowestRunAngle, angle) }
        publish(angle: angle)

        updateVelocity(with: angle)
        openDwell.update(angle: angle, at: CACurrentMediaTime(), dwellAngle: effectPolicy.dwellAngle)
        reconcile(angle: angle)

        if let displayLink, overlay.hasPresentedPicture {
            let moving = isClosingOut || abs(angle - visualAngle.value) > 0.01 || abs(visualAngle.velocity) > 0.1
            let maximum: Float = moving ? 60 : 30
            if displayLink.preferredFrameRateRange.maximum != maximum {
                displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maximum, preferred: maximum)
            }
        }
        let prewarmZone = preferences.thresholdAngle + preferences.prewarmCeiling
        let wantsFastPolling = preview != nil || isActive || isClosingOut || openingWake != nil
            || (angle <= prewarmZone && angularVelocity <= -Self.triggerClosingSpeed)
        let stillAboveTrigger = angle > preferences.thresholdAngle + 12
            && now - lastChangeTime > 0.5 && abs(angularVelocity) < 0.5
        if wantsFastPolling { setPollInterval(Self.activePollInterval) }
        else if stillAboveTrigger { setPollInterval(Self.relaxedPollInterval) }
        else { setPollInterval(Self.idlePollInterval) }
    }

    private var effectPolicy: LidEffectPolicy {
        LidEffectPolicy(threshold: preferences.thresholdAngle, hysteresis: preferences.hysteresis)
    }

    /// Whether the picture belongs on screen for this angle. It widens the
    /// angle for release and keeps a lid held below the angle showing, unless
    /// the timeout ends it first.
    private func wantsEffect(angle: Double) -> Bool {
        // `builtInLayout` is kept current by the screen change observer, so
        // this does not enumerate the screens on every sample.
        guard preferences.isEnabled, builtInLayout.displayID != nil else { return false }
        if preferences.isTimeoutEnabled != wasTimeoutEnabled {
            timeoutReferenceAngle = nil
            timeoutAwaitingRelease = false
            wasTimeoutEnabled = preferences.isTimeoutEnabled
        }

        let now = CACurrentMediaTime()
        let threshold = preferences.thresholdAngle
        let minimumDurationElapsed = now - startedAt > Self.minimumEffectDuration

        if !isActive, preferences.isTimeoutEnabled, timeoutAwaitingRelease {
            guard angle >= threshold else { return false }
            timeoutAwaitingRelease = false
        }

        let wanted = effectPolicy.wantsEffect(
            isEnabled: preferences.isEnabled,
            isActive: isActive,
            angle: angle,
            predictedAngle: predictedAngle(),
            riseSinceLowest: angle - lowestRunAngle,
            hasBeenAboveThreshold: peakAngle >= threshold,
            wasClosingRecently: motionIntent.wasClosingRecently(
                at: now,
                memoryDuration: Self.closingMemory
            ),
            isClearlyOpening: angularVelocity >= Self.triggerOpeningSpeed,
            hasDwelledOpen: openDwell.hasDwelled(at: now, duration: Self.openDwellDuration),
            minimumDurationElapsed: minimumDurationElapsed
        )

        // The timeout only cuts short a run the policy would keep showing.
        if isActive, wanted, minimumDurationElapsed,
           preferences.isTimeoutEnabled, isPastTimeout(angle: angle) {
            timeoutAwaitingRelease = true
            return false
        }
        return wanted
    }

    /// True once the angle has held within `timeoutMovementThreshold` of its
    /// last significant position for `timeoutStillDuration`.
    private func isPastTimeout(angle: Double) -> Bool {
        let now = CACurrentMediaTime()
        if let reference = timeoutReferenceAngle,
           abs(angle - reference) <= Self.timeoutMovementThreshold {
            return now - timeoutReferenceTime >= Self.timeoutStillDuration
        }
        timeoutReferenceAngle = angle
        timeoutReferenceTime = now
        return false
    }

    /// Brings the screen in line with `wantsEffect` on every sample. A run
    /// whose screenshot failed is retried here.
    private func reconcile(angle: Double) {
        guard preferences.isEnabled, !isSuspended else { return }
        if openingStartedAt != nil {
            let reversing = angularVelocity <= -Self.triggerClosingSpeed
                && peakAngle - angle >= LidEffectPolicy.minimumReleaseRise
            if reversing, !overlay.hasPresentedPicture {
                stopEffectAndCapture()
            } else if reversing || (overlay.hasPresentedPicture && angle >= preferences.thresholdAngle) {
                setActive(false)
            }
            return
        }
        if !isActive, !isClosingOut, var wake = openingWake {
            let now = CACurrentMediaTime()
            let displayReady = builtInLayout.displayID.map { CGDisplayIsAsleep($0) == 0 } ?? false
            switch wake.observe(angle: angle, now: now, threshold: preferences.thresholdAngle, displayReady: displayReady) {
            case .wait:
                openingWake = wake
            case .expire:
                openingWake = nil
            case .start:
                DepthLog.lid.notice("opening start at \(angle, format: .fixed(precision: 2))°")
                openingStartedAt = now
                nextCaptureAttempt = 0
                streamer.stop()
                setActive(true)
                return
            }
        }
        let wanted = wantsEffect(angle: angle)
        if wanted != isActive {
            DepthLog.lid.notice(
                """
                \(wanted ? "start" : "end", privacy: .public) raw \(angle, format: .fixed(precision: 2)) \
                predicted \(self.predictedAngle(), format: .fixed(precision: 2)) \
                velocity \(self.angularVelocity, format: .fixed(precision: 1)) deg/s \
                snapshot \(self.snapshotter.latestImage != nil)
                """
            )
            setActive(wanted)
            return
        }
        if isActive {
            if preferences.isLivePicture { streamer.start() }
            if !isCapturePending {
                if !overlay.isVisible { presentPicture() }
                else if preferences.isLivePicture, !overlay.isPictureReady,
                        CACurrentMediaTime() >= nextCaptureAttempt { requestSeed() }
            }
            // A visible overlay with no link would sit at its first frame.
            if overlay.isVisible, displayLink == nil { startDisplayLink() }
        } else if !isClosingOut {
            // The ease back to flat still draws the live picture, and this
            // would free it.
            updatePrewarm(angle: angle, ceiling: preferences.thresholdAngle + preferences.prewarmCeiling)
        }
    }

    private func updateVelocity(with angle: Double) {
        let now = CACurrentMediaTime()
        guard let last = lastChangedAngle else {
            lastChangedAngle = angle
            lastChangeTime = now
            return
        }
        if angle != last {
            let dt = now - lastChangeTime
            if dt > 0.001 {
                let instant = (angle - last) / dt
                angularVelocity = 0.5 * instant + 0.5 * angularVelocity
            }
            lastChangedAngle = angle
            lastChangeTime = now
        } else if now - lastChangeTime > 0.4 {
            angularVelocity = 0
        }
        motionIntent.update(
            angularVelocity: angularVelocity,
            at: now,
            closingSpeed: Self.triggerClosingSpeed,
            openingSpeed: Self.triggerOpeningSpeed
        )
        if angularVelocity >= Self.triggerOpeningSpeed {
            lastClosingTime = -.greatestFiniteMagnitude
        } else if angularVelocity <= -preferences.closingSpeed {
            lastClosingTime = now
        }
    }

    /// Runs only while the lid is closing, so holding it still does not leave
    /// a capture loop running.
    private func updatePrewarm(angle: Double, ceiling: Double) {
        let closingRecently = CACurrentMediaTime() - lastClosingTime < preferences.prewarmLinger
        guard angle <= ceiling, closingRecently else {
            snapshotter.stop()
            streamer.stop()
            overlay.releasePresence()
            return
        }
        guard overlay.warmUp() else { return }
        guard preferences.isLivePicture else {
            streamer.stop()
            snapshotter.beginPrewarm(interval: preferences.prewarmInterval)
            return
        }
        // Only the stream. Asking ScreenCaptureKit for a screenshot at the
        // same time makes it serve neither quickly.
        snapshotter.endPrewarm()
        streamer.start()
    }

    /// A reading can be a full sensor refresh old, so a fast close works from
    /// where the lid is heading rather than the last reading.
    private func predictedAngle() -> Double {
        guard angularVelocity < -Self.predictionSpeedFloor else { return rawAngle }
        let staleness = min(CACurrentMediaTime() - lastChangeTime, 0.12)
        return rawAngle + angularVelocity * (staleness + Self.predictionLatency)
    }

    private func publish(angle: Double) {
        let now = CACurrentMediaTime()
        guard now - lastPublishTime > 0.08 else { return }
        lastPublishTime = now
        if abs(currentAngle - angle) > 0.001 { currentAngle = angle }
    }

    // MARK: - Depth effect

    private func setActive(_ active: Bool) {
        isActive = active
        if active {
            openingWake = nil
            peakAngle = rawAngle
            lowestRunAngle = rawAngle
            openDwell.reset()
            isClosingOut = false
            startedAt = CACurrentMediaTime()
            if preferences.isTimeoutEnabled {
                timeoutReferenceAngle = rawAngle
                timeoutReferenceTime = startedAt
            }
            visualAngle.reset(to: rawAngle)
            snapshotter.endPrewarm()
            setPollInterval(Self.activePollInterval)
            presentPicture()
        } else {
            openingStartedAt = nil
            cancelSnapshot()
            timeoutReferenceAngle = nil
            beginClosingOut()
        }
    }

    private func cancelSnapshot() {
        pictureTask?.cancel()
        pictureTask = nil
        isCapturePending = false
        snapshotter.stop()
    }

    /// Eases the picture back to flat before the overlay fades away. Ending
    /// the effect with the lid still shut would otherwise fade out a warped
    /// picture. `step(_:)` drives the ease and calls `finishClosingOut()`.
    private func beginClosingOut() {
        // Nothing to ease before the picture is up, or with no link to draw it.
        guard overlay.isVisible, displayLink != nil else {
            finishClosingOut()
            return
        }
        isClosingOut = true
        closingOutStartedAt = CACurrentMediaTime()
    }

    private func finishClosingOut() {
        isClosingOut = false
        stopDisplayLink()
        overlay.dismiss(animated: true)
        streamer.stop()
        overlay.releasePresence()
    }

    /// Shows the held screenshot, or waits for one. A pre-warm capture that is
    /// already running counts as that wait.
    private func presentPicture() {
        let now = CACurrentMediaTime()
        guard isActive, now >= nextCaptureAttempt else { return }
        nextCaptureAttempt = now + Self.captureRetryInterval
        guard overlay.warmUp() else { return }
        let isOpening = openingStartedAt != nil
        if !isOpening, preferences.isLivePicture, let screen = NSScreen.builtIn,
           overlay.showLive(
               on: screen,
               island: captureIsland?(screen),
               startAngle: preferences.thresholdAngle,
               tuning: preferences.tuning,
               fadeIn: Self.fadeInDuration
           ) {
            streamer.start()
            startDisplayLink()
            if let frame = streamer.newFrame() {
                DepthLog.lid.notice("present: live, a stream frame was ready")
                overlay.absorb(frame)
                return
            }
            // A fast close can reach the trigger angle before the stream has a
            // frame. One screenshot starts the picture off.
            if let image = snapshotter.latestImage {
                DepthLog.lid.notice("present: live, seeding from the pre-warm screenshot")
                overlay.seed(image: image)
                return
            }
            DepthLog.lid.notice("present: live, no picture yet, asking for a screenshot")
            requestSeed()
            return
        }

        if !isOpening, let image = snapshotter.latestImage, let screen = snapshotter.latestScreen {
            snapshotter.stop()
            show(image: image, on: screen)
            return
        }
        isCapturePending = true
        pictureTask?.cancel()
        pictureTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            if isOpening { await self.snapshotter.captureAfterWake() }
            else { await self.snapshotter.captureOnce() }
            guard !Task.isCancelled else { return }
            self.pictureTask = nil
            self.isCapturePending = false
            defer { self.snapshotter.discard() }
            guard self.isActive, !self.overlay.isVisible,
                  let image = self.snapshotter.latestImage,
                  let screen = self.snapshotter.latestScreen else { return }
            self.show(image: image, on: screen)
        }
    }

    /// Takes one screenshot to start a live overlay that has nothing to show
    /// yet. A stream frame that lands first makes it unnecessary.
    private func requestSeed() {
        isCapturePending = true
        let started = CACurrentMediaTime()
        nextCaptureAttempt = started + Self.captureRetryInterval
        pictureTask?.cancel()
        pictureTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            // A pre-warmed stream normally lands first.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await self.snapshotter.captureOnce()
            guard !Task.isCancelled else { return }
            self.pictureTask = nil
            self.isCapturePending = false
            defer { self.snapshotter.discard() }
            DepthLog.lid.notice(
                """
                seed capture landed after \((CACurrentMediaTime() - started) * 1000, format: .fixed(precision: 0)) ms: \
                image \(self.snapshotter.latestImage != nil) on \(self.isActive) \
                ready \(self.overlay.isPictureReady)
                """
            )
            guard self.isActive, !self.overlay.isPictureReady,
                  let image = self.snapshotter.latestImage else { return }
            self.overlay.seed(image: image)
        }
    }

    private func show(image: CGImage, on screen: NSScreen) {
        overlay.show(
            image: image,
            on: screen,
            island: captureIsland?(screen),
            startAngle: preferences.thresholdAngle,
            tuning: preferences.tuning,
            fadeIn: Self.fadeInDuration
        )
        // The link belongs to the overlay window.
        startDisplayLink()
    }

    private func blurProgress(for angle: Double) -> Double {
        let span = max(preferences.blurSpan, 1)
        return min(max((preferences.thresholdAngle - angle) / span, 0), 1)
    }

    // MARK: - Animation

    private func startDisplayLink() {
        stopDisplayLink()
        guard let window = overlay.hostWindow else {
            DepthLog.lid.notice("display link skipped, no overlay window")
            return
        }
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        lastFrameTime = CACurrentMediaTime()
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let rawInterval = now - lastFrameTime
        let dt = min(max(rawInterval, 1.0 / 240), 1.0 / 20)
        lastFrameTime = now
        if let frame = streamer.newFrame() {
            overlay.absorb(frame)
            if isCapturePending { cancelSnapshot() }
        }
        let threshold = preferences.thresholdAngle
        if let started = openingStartedAt, !overlay.hasPresentedPicture {
            guard now - started < Self.openingFrameDeadline, overlay.isPictureReady else { return }
            // A quick open can pass the flat angle while the frame uploads.
            // Start its short finish near flat instead of showing an old angle.
            visualAngle.reset(to: min(rawAngle, max(0, threshold - 5)))
            applyVisual(angle: visualAngle.value)
            return
        }
        let target = isClosingOut ? threshold : rawAngle
        visualAngle.advance(to: target, dt: dt)

        guard isClosingOut else {
            applyVisual(angle: visualAngle.value)
            return
        }
        // At or above the threshold the picture is already flat, so a lid
        // that opened past it finishes at once.
        let settled = visualAngle.value >= target - Self.closingOutSettleEpsilon
        let timedOut = now - closingOutStartedAt > Self.closingOutMaxDuration
        guard settled || timedOut else {
            applyVisual(angle: visualAngle.value)
            return
        }
        // The frame that fades out must match the screen behind it exactly,
        // so land on the threshold itself rather than just short of it.
        visualAngle.reset(to: target)
        applyVisual(angle: target)
        finishClosingOut()
    }

    /// The geometry takes the lid angle itself, so only the blur saturates.
    private func applyVisual(angle: Double) {
        let progress = blurProgress(for: angle)
        overlay.update(progress: progress, currentAngle: angle, tuning: preferences.tuning)
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setDisplaySleeping(true) }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setDisplaySleeping(false) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // macOS posts this for backlight and colour changes too.
                let screen = NSScreen.builtIn
                let layout = Layout(displayID: screen?.displayID, frame: screen?.frame)
                guard layout != self.builtInLayout else { return }
                DepthLog.lid.notice("screen parameters changed, layout now \(String(describing: layout), privacy: .public)")
                self.builtInLayout = layout
                self.disableEffect()
                self.streamer.invalidateFilter()
                self.snapshotter.invalidateFilter()
                self.updatePolling(enabled: self.preferences.isEnabled)
            }
        }
    }

    private func setDisplaySleeping(_ sleeping: Bool) {
        isDisplaySleeping = sleeping
        if sleeping { disableEffect() }
        updatePolling(enabled: preferences.isEnabled)
    }

    private func suspend() {
        DepthLog.lid.notice("suspend")
        lidAngleBeforeSleep = preferences.isEnabled && preferences.isOpeningEnabled ? sensor.angle() : nil
        openingWake = nil
        isSuspended = true
        setPollInterval(0)
        stopEffectAndCapture()
    }

    private func resume() {
        guard isSuspended else { return }
        DepthLog.lid.notice("resume")
        isSuspended = false
        // A fresh baseline, so waking with a nearly shut lid does not read as
        // closing movement.
        lastChangedAngle = nil
        angularVelocity = 0
        lastClosingTime = -.greatestFiniteMagnitude
        motionIntent.reset()
        openDwell.reset()
        peakAngle = 0
        timeoutReferenceAngle = nil
        timeoutAwaitingRelease = false
        wasTimeoutEnabled = false
        isClosingOut = false
        let wakeAngle = sensor.angle()
        if let displayID = builtInLayout.displayID, CGDisplayIsAsleep(displayID) == 0 {
            isDisplaySleeping = false
        }
        if let angle = wakeAngle {
            rawAngle = angle
            visualAngle.reset(to: angle)
        }
        if preferences.isEnabled, preferences.isOpeningEnabled {
            // A low reading before sleep can establish movement even when
            // the first reading after a fast open is already near flat.
            let closedAngle = lidAngleBeforeSleep.flatMap { $0 <= 35 ? $0 : nil }
            openingWake = LidWakeOpening(
                deadline: CACurrentMediaTime() + Self.openingWakeWindow,
                lowestAngle: closedAngle ?? wakeAngle
            )
        }
        lidAngleBeforeSleep = nil
        refreshScreenPermission()
    }
}
