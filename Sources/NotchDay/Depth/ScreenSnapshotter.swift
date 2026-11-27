import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Keeps a recent screenshot of the built-in display ready.
///
/// A screenshot taken at the trigger angle lands too late, so the effect
/// pre-warms a capture loop while the lid is still on its way down.
///
/// Ported from Mac-Duo, Apache License 2.0.
@MainActor
final class ScreenSnapshotter {

    private(set) var latestImage: CGImage?
    private(set) var latestScreen: NSScreen?

    private var filter: SCContentFilter?
    private var filterKey: DepthFilter.Key?
    private var timer: Timer?
    private var inFlight: Task<Void, Never>?

    func beginPrewarm(interval: TimeInterval = 0.2) {
        guard timer == nil else { return }
        capture()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func endPrewarm() {
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        endPrewarm()
        inFlight?.cancel()
        discard()
    }

    /// Drops the held screenshot.
    func discard() {
        latestImage = nil
        latestScreen = nil
    }

    /// Waits for a screenshot. A pre-warm capture already running counts.
    func captureOnce() async {
        await startCapture().value
    }

    /// Drops the cached filter, so the next capture enumerates the windows
    /// again.
    func invalidateFilter() {
        filter = nil
        filterKey = nil
    }

    private func capture() {
        startCapture()
    }

    @discardableResult
    private func startCapture() -> Task<Void, Never> {
        if let inFlight { return inFlight }
        let task = Task { [weak self] in
            await self?.performCapture()
            self?.inFlight = nil
        }
        inFlight = task
        return task
    }

    private func performCapture() async {
        guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return }
        guard let screen = NSScreen.builtIn, let displayID = screen.displayID else { return }
        let key = DepthFilter.Key(displayID: displayID)
        if filter == nil || filterKey != key {
            await rebuildFilter(key)
        }
        guard !Task.isCancelled, let activeFilter = filter else { return }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(activeFilter.contentRect.width * CGFloat(activeFilter.pointPixelScale))
        configuration.height = Int(activeFilter.contentRect.height * CGFloat(activeFilter.pointPixelScale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false

        do {
            let started = CFAbsoluteTimeGetCurrent()
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: activeFilter,
                configuration: configuration
            )
            guard !Task.isCancelled else { return }
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
            latestImage = image
            latestScreen = screen
            DepthLog.capture.debug("captureImage took \(elapsed, format: .fixed(precision: 1)) ms")
        } catch {
            guard !Task.isCancelled else { return }
            DepthLog.capture.error("capture failed: \(String(describing: error), privacy: .public)")
            invalidateFilter()
        }
    }

    private func rebuildFilter(_ key: DepthFilter.Key) async {
        let started = CFAbsoluteTimeGetCurrent()
        let made = await DepthFilter.make(for: key)
        guard !Task.isCancelled else { return }
        filter = made
        filterKey = filter == nil ? nil : key
        DepthLog.capture.notice(
            "filter rebuilt in \((CFAbsoluteTimeGetCurrent() - started) * 1000, format: .fixed(precision: 1)) ms"
        )
    }
}
