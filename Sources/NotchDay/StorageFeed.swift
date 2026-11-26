import AppKit
import Foundation
import Observation

struct StoragePoint: Identifiable, Sendable, Equatable {
    let date: Date
    let used: Int64
    /// 0 表示原始采样，1 表示按自然日合并，大于 1 表示每 N 天合并为一个点。
    let bucketDays: Int

    var id: Date { date }
}

struct StorageSnapshot: Sendable, Equatable {
    let total: Int64
    let available: Int64

    var used: Int64 { max(0, total - available) }
}

enum StorageRange: Int, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case quarter
    case halfYear
    case year
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .day: "1天"
        case .week: "7天"
        case .month: "1月"
        case .quarter: "3月"
        case .halfYear: "6月"
        case .year: "1年"
        case .all: "全部"
        }
    }

    /// nil 表示按已有记录的总跨度自适应。
    var span: TimeInterval? {
        switch self {
        case .day: 24 * 3600
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .quarter: 90 * 86_400
        case .halfYear: 182 * 86_400
        case .year: 365 * 86_400
        case .all: nil
        }
    }

    var bucketDays: Int {
        switch self {
        case .day: 0
        case .week, .month: 1
        case .quarter: 3
        case .halfYear: 6
        case .year: 7
        case .all: 0
        }
    }

    var deltaTitle: String {
        switch self {
        case .day: "较 1 天前"
        case .week: "较 7 天前"
        case .month: "较 1 个月前"
        case .quarter: "较 3 个月前"
        case .halfYear: "较 6 个月前"
        case .year: "较 1 年前"
        case .all: "较记录起点"
        }
    }
}

enum StorageLog {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "NotchDay/Storage", directoryHint: .isDirectory)
    }

    static func prepare() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func readAll() -> [StoragePoint] {
        let fileManager = FileManager.default
        prepare()
        prune(fileManager)
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let formatter = timestampFormatter()
        var points: [StoragePoint] = []
        for file in files where file.pathExtension == "csv" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let fields = line.split(separator: ",")
                guard fields.count >= 2,
                      let date = formatter.date(from: String(fields[0])),
                      let used = Int64(fields[1].trimmingCharacters(in: .whitespaces)) else { continue }
                points.append(StoragePoint(date: date, used: used, bucketDays: 0))
            }
        }
        return points.sorted { $0.date < $1.date }
    }

    static func append(date: Date, used: Int64, total: Int64) {
        let fileManager = FileManager.default
        prepare()
        let url = fileURL(for: date)
        if !fileManager.fileExists(atPath: url.path) {
            try? "time,used_bytes,total_bytes\n".write(to: url, atomically: true, encoding: .utf8)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        let line = "\(timestampFormatter().string(from: date)),\(used),\(total)\n"
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    static func fileURL(for date: Date) -> URL {
        directory.appending(path: "storage-\(monthKey(date)).csv")
    }

    private static func prune(_ fileManager: FileManager) {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        let cutoff = Calendar.current.date(byAdding: .month, value: -13, to: Date()) ?? Date()
        let cutoffKey = monthKey(cutoff)
        for file in files where file.lastPathComponent.hasPrefix("storage-") {
            let key = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "storage-", with: "")
            if key < cutoffKey { try? fileManager.removeItem(at: file) }
        }
    }

    private static func monthKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private static func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }
}

@MainActor
@Observable
final class StorageFeed {
    private(set) var snapshot: StorageSnapshot?
    private(set) var series: [StoragePoint] = []
    private(set) var range: StorageRange = .day

    private var rawPoints: [StoragePoint] = []
    private var lastSampleAt: Date?
    private var loaded = false
    private var activation: Task<Void, Never>?
    private var sampler: Task<Void, Never>?

    private static let sampleInterval: TimeInterval = 3600

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSnapshot() }
            }
        }
    }

    var availableSpan: TimeInterval {
        guard let first = rawPoints.first, let last = rawPoints.last else { return 0 }
        return last.date.timeIntervalSince(first.date)
    }

    var hasTrend: Bool { series.count >= 2 }

    func isAvailable(_ range: StorageRange) -> Bool {
        guard let span = range.span else { return true }
        return availableSpan >= span - 3600
    }

    func select(_ range: StorageRange) {
        guard isAvailable(range), range != self.range else { return }
        self.range = range
        rebuildSeries()
    }

    /// 打开卡片：立刻读一次容量，并按“上次采样 + 1 小时”的节奏继续采样。
    func activate() {
        guard activation == nil, sampler == nil else { return }
        activation = Task { [weak self] in
            guard let self else { return }
            await load()
            guard !Task.isCancelled else { return }
            // 打开卡片先读一次当前容量，日志写入仍按每小时一条。
            self.refreshSnapshot()
            self.activation = nil
            self.startSampler()
        }
    }

    /// 收起卡片：停止采样，不做任何后台 I/O。
    func deactivate() {
        activation?.cancel()
        activation = nil
        sampler?.cancel()
        sampler = nil
    }

    private func load() async {
        guard !loaded else { return }
        let points = await Task.detached(priority: .utility) { StorageLog.readAll() }.value
        rawPoints = points
        lastSampleAt = points.last?.date
        loaded = true
        clampRange()
        rebuildSeries()
    }

    private func startSampler() {
        sampler?.cancel()
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.shouldSample {
                    self.sample()
                }
                let due = (self.lastSampleAt ?? Date()).addingTimeInterval(Self.sampleInterval)
                let wait = max(1, due.timeIntervalSinceNow)
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            }
        }
    }

    private var shouldSample: Bool {
        guard let lastSampleAt else { return true }
        return Date().timeIntervalSince(lastSampleAt) >= Self.sampleInterval
    }

    private func sample() {
        guard let snapshot = readSnapshot() else { return }
        let now = Date()
        self.snapshot = snapshot
        lastSampleAt = now
        rawPoints.append(StoragePoint(date: now, used: snapshot.used, bucketDays: 0))
        StorageLog.append(date: now, used: snapshot.used, total: snapshot.total)
        clampRange()
        rebuildSeries()
    }

    private func refreshSnapshot() {
        guard loaded, let snapshot = readSnapshot() else { return }
        self.snapshot = snapshot
    }

    private func readSnapshot() -> StorageSnapshot? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return StorageSnapshot(total: Int64(total), available: available)
    }

    private func clampRange() {
        guard !isAvailable(range) else { return }
        range = StorageRange.allCases.last { isAvailable($0) } ?? .all
    }

    private func rebuildSeries() {
        series = Self.aggregate(rawPoints, range: range, now: Date())
    }

    static func aggregate(_ points: [StoragePoint], range: StorageRange, now: Date) -> [StoragePoint] {
        guard !points.isEmpty else { return [] }
        let sorted = points.sorted { $0.date < $1.date }
        guard range != .day else {
            let start = now.addingTimeInterval(-86_400)
            return sorted.filter { $0.date >= start }.map { StoragePoint(date: $0.date, used: $0.used, bucketDays: 0) }
        }

        let span: TimeInterval
        let bucketDays: Int
        if let fixed = range.span {
            span = fixed
            bucketDays = max(1, range.bucketDays)
        } else {
            span = max(86_400, sorted[sorted.count - 1].date.timeIntervalSince(sorted[0].date))
            bucketDays = max(1, Int((span / 86_400 / 50).rounded(.up)))
        }

        let start = now.addingTimeInterval(-span)
        var result: [StoragePoint] = []
        var currentBucket: Int?
        for point in sorted where point.date >= start {
            let bucket = Int((point.date.timeIntervalSinceReferenceDate / (86_400 * Double(bucketDays))).rounded(.down))
            if bucket == currentBucket, !result.isEmpty {
                result[result.count - 1] = StoragePoint(date: point.date, used: point.used, bucketDays: bucketDays)
            } else {
                result.append(StoragePoint(date: point.date, used: point.used, bucketDays: bucketDays))
                currentBucket = bucket
            }
        }
        return result
    }
}
