import AppKit
import CoreVideo
import Metal
import ScreenCaptureKit

/// Streams the built-in display into Metal textures for the live picture.
///
/// Frames are `IOSurface` backed, so wrapping one as a texture copies nothing.
/// `startCapture` takes long enough that the stream has to be started while
/// the lid is still closing rather than at the trigger angle.
///
/// Ported from Mac-Duo, Apache License 2.0.
@MainActor
final class ScreenStreamer {

    /// Display P3 carries the same transfer function as sRGB, so the shader's
    /// sRGB pixel format decodes it correctly.
    static let colourSpaceName = CGColorSpace.displayP3

    /// Frames arrive on the stream's own queue. The newest one is kept under a
    /// lock and picked up on the main thread; the texture cache is only ever
    /// touched from the stream queue.
    private final class Receiver: NSObject, SCStreamOutput, SCStreamDelegate {
        private let cache: CVMetalTextureCache
        private let lock = NSLock()
        private var newest: CapturedFrame?
        private let stopped: @Sendable (ObjectIdentifier) -> Void

        init?(device: MTLDevice, stopped: @escaping @Sendable (ObjectIdentifier) -> Void) {
            self.stopped = stopped
            var made: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &made) == kCVReturnSuccess,
                  let made else { return nil }
            cache = made
            super.init()
        }

        func takeLatest() -> CapturedFrame? {
            lock.lock()
            defer { lock.unlock() }
            let frame = newest
            newest = nil
            return frame
        }

        func stream(_ stream: SCStream, didStopWithError error: any Error) {
            DepthLog.capture.error("stream interrupted: \(String(describing: error), privacy: .public)")
            stopped(ObjectIdentifier(stream))
        }

        func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {
            guard type == .screen,
                  CMSampleBufferIsValid(sampleBuffer),
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
                  let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            // Lets go of the surfaces nothing holds, so the pool keeps recycling.
            CVMetalTextureCacheFlush(cache, 0)

            var wrapped: CVMetalTexture?
            let result = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixels,
                nil,
                .bgra8Unorm_srgb,
                CVPixelBufferGetWidth(pixels),
                CVPixelBufferGetHeight(pixels),
                0,
                &wrapped
            )
            guard result == kCVReturnSuccess, let wrapped,
                  let frame = CapturedFrame(wrapped) else { return }

            lock.lock()
            newest = frame
            lock.unlock()
        }
    }

    private lazy var device = MTLCreateSystemDefaultDevice()
    private var stream: SCStream?
    private var receiver: Receiver?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var retryAt: CFTimeInterval = 0
    private let frameQueue = DispatchQueue(label: "NotchDay.frames", qos: .userInitiated)
    /// Enumerating every on screen window costs about 70 ms, so the filter is
    /// kept between runs and rebuilt only when the display or the notch
    /// window changed.
    private var filter: SCContentFilter?
    private var filterKey: DepthFilter.Key?
    private(set) var isStarted = false

    /// Begins capturing, or does nothing if it is already running.
    func start() {
        guard !isStarted, startTask == nil, CACurrentMediaTime() >= retryAt,
              CGPreflightScreenCaptureAccess(), device != nil else { return }
        guard let target = NSScreen.builtIn, let displayID = target.displayID else { return }
        isStarted = true
        let previousStop = stopTask
        startTask = Task { [weak self] in
            guard let self else { return }
            await previousStop?.value
            await self.begin(displayID: displayID)
            guard !Task.isCancelled else { return }
            self.startTask = nil
        }
    }

    func stop() {
        guard isStarted || stream != nil else { return }
        isStarted = false
        let starting = startTask
        let closing = stream
        let previousStop = stopTask
        starting?.cancel()
        startTask = nil
        stream = nil
        receiver = nil
        stopTask = Task {
            await previousStop?.value
            await starting?.value
            if let closing { try? await closing.stopCapture() }
        }
    }

    /// Drops the cached filter, so the next start enumerates the windows again.
    func invalidateFilter() {
        filter = nil
        filterKey = nil
    }

    func newFrame() -> CapturedFrame? {
        receiver?.takeLatest()
    }

    private func begin(displayID: CGDirectDisplayID) async {
        guard !Task.isCancelled else { return }
        guard let device, let receiver = Receiver(device: device, stopped: { [weak self] stream in
            Task { @MainActor in self?.streamDidStop(stream) }
        }) else {
            recordFailure()
            return
        }
        do {
            let key = DepthFilter.Key(displayID: displayID)
            if filter == nil || filterKey != key {
                await rebuildFilter(key)
            }
            guard !Task.isCancelled, isStarted else { return }
            guard let activeFilter = filter else {
                recordFailure()
                return
            }

            let configuration = SCStreamConfiguration()
            configuration.width = Int(activeFilter.contentRect.width * CGFloat(activeFilter.pointPixelScale))
            configuration.height = Int(activeFilter.contentRect.height * CGFloat(activeFilter.pointPixelScale))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = Self.colourSpaceName
            configuration.showsCursor = false
            configuration.queueDepth = 3
            configuration.scalesToFit = false

            let fresh = SCStream(filter: activeFilter, configuration: configuration, delegate: receiver)
            try fresh.addStreamOutput(
                receiver,
                type: .screen,
                sampleHandlerQueue: frameQueue
            )
            let started = CFAbsoluteTimeGetCurrent()
            try await fresh.startCapture()
            guard !Task.isCancelled, isStarted else {
                try? await fresh.stopCapture()
                return
            }
            self.receiver = receiver
            self.stream = fresh
            DepthLog.capture.notice(
                """
                stream started \(configuration.width)x\(configuration.height) px in \
                \((CFAbsoluteTimeGetCurrent() - started) * 1000, format: .fixed(precision: 1)) ms
                """
            )
        } catch {
            guard !Task.isCancelled else { return }
            DepthLog.capture.error("stream failed: \(String(describing: error), privacy: .public)")
            recordFailure()
        }
    }

    private func streamDidStop(_ stopped: ObjectIdentifier) {
        guard let stream, ObjectIdentifier(stream) == stopped else { return }
        self.stream = nil
        receiver = nil
        recordFailure()
    }

    private func recordFailure() {
        invalidateFilter()
        isStarted = false
        retryAt = CACurrentMediaTime() + 0.5
    }

    private func rebuildFilter(_ key: DepthFilter.Key) async {
        let made = await DepthFilter.make(for: key)
        guard !Task.isCancelled else { return }
        filter = made
        filterKey = made == nil ? nil : key
        if made == nil { DepthLog.capture.error("stream filter failed") }
    }
}
