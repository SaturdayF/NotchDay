import AppKit
import Carbon
import ImageIO
import Observation

struct MusicTrack: Equatable, Sendable {
    let title: String
    let artist: String
    let duration: Double

    var id: String { title + "\u{1F}" + artist }
    static let empty = Self(title: "Apple Music", artist: "", duration: 0)
}

enum MusicCommand: Sendable {
    case playPause, previous, next, seek(Double), shuffle(Bool)
}

private struct MusicSnapshot: Sendable {
    let track: MusicTrack?
    let isPlaying: Bool
    let position: Double?
    let shuffle: Bool?
    let artwork: Data?
}

@MainActor
@Observable
final class MusicPlayback: NSObject {
    enum Connection { case closed, needsPermission, denied, connected, unavailable }

    private(set) var connection: Connection = .closed {
        didSet {
            if oldValue != connection { updatePolling() }
        }
    }
    private(set) var track = MusicTrack.empty
    private(set) var artwork: NSImage?
    private(set) var isPlaying = false
    private(set) var isShuffled = false
    var changed: (() -> Void)?

    private let events = MusicAppleEvents()
    private var sampledPosition: Double = 0
    private var sampledAt = Date.distantPast
    private var artworkAttempt: String?
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var noticeDate = Date.distantPast
    private var monitoring = false
    private var pid: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first?.processIdentifier
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(playerInfo(_:)), name: .init("com.apple.Music.playerInfo"), object: nil)
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(musicAppChanged(_:)), name: name, object: nil)
        }
        refresh()
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        refreshTask?.cancel()
        pollTask?.cancel()
        commandTask?.cancel()
    }

    func setVisible(_ visible: Bool) {
        guard visible != monitoring else { return }
        monitoring = visible
        updatePolling()
        if visible { refresh() }
    }

    private func updatePolling() {
        pollTask?.cancel()
        pollTask = nil
        guard monitoring, connection == .connected else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4), tolerance: .milliseconds(300)) } catch { return }
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func connectionAction() {
        guard pid != nil else {
            SystemLinks.openMusic()
            return
        }
        if connection == .denied {
            SystemLinks.openAutomationPrivacy()
        } else {
            refresh(askPermission: true)
        }
    }

    func position(at date: Date) -> Double {
        let value = sampledPosition + (isPlaying ? max(0, date.timeIntervalSince(sampledAt)) : 0)
        return track.duration > 0 ? min(track.duration, value) : value
    }

    func send(_ command: MusicCommand) {
        guard connection == .connected, let pid else { return }
        let previous = commandTask
        commandTask = Task { [weak self, events] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await events.send(command, pid: pid)
            } catch {
                if (error as NSError).code == Int(errAEEventNotPermitted) {
                    self?.connection = .denied
                }
            }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh(askPermission: Bool = false) {
        refreshTask?.cancel()
        guard let pid else {
            reset()
            return
        }

        let currentID = artworkAttempt
        refreshTask = Task { [weak self, events] in
            let status = await events.authorize(pid: pid, prompt: askPermission)
            guard let self, !Task.isCancelled, self.pid == pid else { return }
            guard status == noErr else {
                switch Int(status) {
                case errAEEventWouldRequireUserConsent: self.connection = .needsPermission
                case errAEEventNotPermitted: self.connection = .denied
                default: self.connection = .unavailable
                }
                return
            }
            self.connection = .connected
            let began = Date.now
            do {
                let snapshot = try await events.read(pid: pid, artworkFor: currentID)
                guard !Task.isCancelled, self.pid == pid, self.noticeDate <= began else { return }
                self.apply(snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                if (error as NSError).code == Int(errAEEventNotPermitted) {
                    self.connection = .denied
                }
            }
        }
    }

    private func apply(_ snapshot: MusicSnapshot) {
        if let track = snapshot.track {
            let sameTrack = track.id == self.track.id
            if !sameTrack { artwork = nil }
            if let data = snapshot.artwork { artwork = Self.thumbnail(data) }
            artworkAttempt = track.id
            self.track = sameTrack && track.duration <= 0 && self.track.duration > 0
                ? MusicTrack(title: track.title, artist: track.artist, duration: self.track.duration)
                : track
        }
        let now = Date.now
        sampledPosition = snapshot.position ?? position(at: now)
        sampledAt = now
        isPlaying = snapshot.isPlaying
        if let shuffle = snapshot.shuffle { isShuffled = shuffle }
        changed?()
    }

    private func reset() {
        connection = .closed
        track = .empty
        artwork = nil
        artworkAttempt = nil
        isPlaying = false
        isShuffled = false
        sampledPosition = 0
        sampledAt = .distantPast
        changed?()
    }

    @objc private func musicAppChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.Music" else { return }
        refresh()
    }

    @objc private func playerInfo(_ notification: Notification) {
        guard pid != nil, let info = notification.userInfo,
              let state = info["Player State"] as? String else { return }
        noticeDate = .now
        let oldPosition = position(at: noticeDate)
        if let name = info["Name"] as? String, !name.isEmpty {
            let artist = info["Artist"] as? String ?? ""
            let sameTrack = track.title == name && track.artist == artist
            let duration = (info["Total Time"] as? NSNumber).map { $0.doubleValue / 1000 }
            if !sameTrack { artwork = nil }
            track = MusicTrack(title: name, artist: artist, duration: duration ?? (sameTrack ? track.duration : 0))
            sampledPosition = sameTrack ? oldPosition : 0
        } else if state == "Stopped" {
            sampledPosition = 0
        } else {
            sampledPosition = oldPosition
        }
        sampledAt = noticeDate
        isPlaying = state == "Playing"
        changed?()
        refresh()
    }

    private static func thumbnail(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 144,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

private actor MusicAppleEvents {
    typealias Descriptor = NSAppleEventDescriptor

    func authorize(pid: pid_t, prompt: Bool) -> OSStatus {
        let target = Descriptor(processIdentifier: pid)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, prompt)
    }

    func read(pid: pid_t, artworkFor previousID: String?) throws -> MusicSnapshot {
        let state = try get(property("pPlS"), pid: pid).enumCodeValue
        let playing = state == code("kPSP")
        let position = try? get(property("pPos"), pid: pid).doubleValue
        let shuffle = try? get(property("pShE"), pid: pid).booleanValue
        let current = property("pTrk")
        var track: MusicTrack?
        var artwork: Data?
        if let title = try? get(property("pnam", in: current), pid: pid).stringValue, !title.isEmpty {
            let artist = (try? get(property("pArt", in: current), pid: pid).stringValue) ?? ""
            let duration = (try? get(property("pDur", in: current), pid: pid).doubleValue) ?? 0
            let result = MusicTrack(title: title, artist: artist, duration: duration)
            track = result
            if result.id != previousID {
                let firstArt = object("cArt", form: "indx", selector: Descriptor(int32: 1), in: current)
                artwork = try? get(property("pRaw", in: firstArt), pid: pid).data
            }
        }
        return MusicSnapshot(track: track, isPlaying: playing, position: position, shuffle: shuffle, artwork: artwork)
    }

    func send(_ command: MusicCommand, pid: pid_t) throws {
        switch command {
        case .playPause: _ = try commandEvent("PlPs", pid: pid)
        case .previous: _ = try commandEvent("Prev", pid: pid)
        case .next: _ = try commandEvent("Next", pid: pid)
        case let .seek(value): try set(property("pPos"), to: Descriptor(double: value), pid: pid)
        case let .shuffle(value): try set(property("pShE"), to: Descriptor(boolean: value), pid: pid)
        }
    }

    private func commandEvent(_ identifier: String, pid: pid_t) throws -> Descriptor {
        try send(event("hook", identifier, pid: pid))
    }

    private func get(_ specifier: Descriptor, pid: pid_t) throws -> Descriptor {
        let request = event("core", "getd", pid: pid)
        request.setParam(specifier, forKeyword: code("----"))
        return try send(request).paramDescriptor(forKeyword: code("----")) ?? .null()
    }

    private func set(_ specifier: Descriptor, to value: Descriptor, pid: pid_t) throws {
        let request = event("core", "setd", pid: pid)
        request.setParam(specifier, forKeyword: code("----"))
        request.setParam(value, forKeyword: code("data"))
        _ = try send(request)
    }

    private func send(_ request: Descriptor) throws -> Descriptor {
        let reply = try request.sendEvent(options: [.waitForReply, .neverInteract], timeout: 1)
        if let error = reply.paramDescriptor(forKeyword: code("errn"))?.int32Value, error != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error))
        }
        return reply
    }

    private func event(_ suite: String, _ identifier: String, pid: pid_t) -> Descriptor {
        Descriptor(eventClass: code(suite), eventID: code(identifier), targetDescriptor: Descriptor(processIdentifier: pid),
                   returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    private func property(_ name: String, in parent: Descriptor? = nil) -> Descriptor {
        object("prop", form: "prop", selector: Descriptor(typeCode: code(name)), in: parent)
    }

    private func object(_ kind: String, form: String, selector: Descriptor, in parent: Descriptor?) -> Descriptor {
        let descriptor = Descriptor.record()
        descriptor.setDescriptor(Descriptor(typeCode: code(kind)), forKeyword: code("want"))
        descriptor.setDescriptor(Descriptor(enumCode: code(form)), forKeyword: code("form"))
        descriptor.setDescriptor(selector, forKeyword: code("seld"))
        descriptor.setDescriptor(parent ?? .null(), forKeyword: code("from"))
        return descriptor.coerce(toDescriptorType: code("obj ")) ?? descriptor
    }

    private func code(_ value: String) -> UInt32 {
        value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
