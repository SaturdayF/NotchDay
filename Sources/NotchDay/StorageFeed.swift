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
            if Task.isCancelled { return [] }
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
    private var availability: [StorageRange: Bool] = [:]
    private var lastSampleAt: Date?
    private var activation: Task<Void, Never>?
    private var sampler: Task<Void, Never>?

    private static let sampleInterval: TimeInterval = 3600

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.sampler != nil else { return }
                    self.refreshSnapshot()
                }
            }
        }
    }

    func isAvailable(_ range: StorageRange) -> Bool {
        availability[range] ?? false
    }

    /// 区间是否可用。1 天与全部只要有记录就能画（单点也显示），
    /// 更长区间需要记录跨度覆盖且至少两个点，避免用几天的数据冒充一年。
    /// 同时看点数是为了处理长时间未运行的情况：跨度够了但最近 24 小时只有一条，
    /// 1 天区间会是一片空白，看起来像历史记录丢了。
    private func recomputeAvailability() {
        let now = Date()
        let historySpan = rawPoints.first.map { now.timeIntervalSince($0.date) } ?? 0
        let total = rawPoints.count
        var map: [StorageRange: Bool] = [:]
        for range in StorageRange.allCases {
            let count = sampleCount(range, now: now)
            if let span = range.span, range != .day {
                map[range] = count >= 2 && historySpan >= span - 3600
            } else {
                map[range] = count >= 2 || (count == 1 && total == 1)
            }
        }
        availability = map
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
        rawPoints = []
    }

    private func load() async {
        // 每次进入卡片都重读日志并按当前时间重算窗口，
        // 否则离开一段时间后再回来，图表还停在离开那一刻的区间。
        let read = Task.detached(priority: .utility) { StorageLog.readAll() }
        let points = await withTaskCancellationHandler {
            await read.value
        } onCancel: {
            read.cancel()
        }
        guard !Task.isCancelled else { return }
        rawPoints = points
        lastSampleAt = points.last?.date
        recomputeAvailability()
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
        let point = StoragePoint(date: now, used: snapshot.used, bucketDays: 0)
        let index = rawPoints.last.map { $0.date > now } == true
            ? rawPoints.firstIndex { $0.date > now } ?? rawPoints.endIndex
            : rawPoints.endIndex
        rawPoints.insert(point, at: index)
        StorageLog.append(date: now, used: snapshot.used, total: snapshot.total)
        recomputeAvailability()
        clampRange()
        rebuildSeries()
    }

    private func refreshSnapshot() {
        guard let snapshot = readSnapshot() else { return }
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
        // 优先回落到最短的可用区间，保持与默认视图接近的密度；
        // 全都不可用时保留「全部」，由卡片显示数据积累提示。
        range = StorageRange.allCases.first { isAvailable($0) } ?? .all
    }

    private func rebuildSeries() {
        series = aggregate(range, now: Date())
    }

    private func window(_ range: StorageRange, now: Date) -> (points: ArraySlice<StoragePoint>, bucketDays: Int) {
        guard let first = rawPoints.first, let last = rawPoints.last else { return ([], 0) }
        let span = range.span ?? max(86_400, last.date.timeIntervalSince(first.date))
        let days = range == .all ? max(1, Int((span / 86_400 / 50).rounded(.up))) : range.bucketDays
        let start = now.addingTimeInterval(-span)
        return (rawPoints.drop(while: { $0.date < start }), days)
    }

    private func sampleCount(_ range: StorageRange, now: Date) -> Int {
        let (points, days) = window(range, now: now)
        guard let first = points.first, let last = points.last else { return 0 }
        if days == 0 { return points.count }
        return bucket(first.date, days: days) == bucket(last.date, days: days) ? 1 : 2
    }

    private func aggregate(_ range: StorageRange, now: Date) -> [StoragePoint] {
        let (points, days) = window(range, now: now)
        guard days != 0 else { return Array(points) }
        var result: [StoragePoint] = []
        var currentBucket: Int?
        for point in points {
            let key = bucket(point.date, days: days)
            let sample = StoragePoint(date: point.date, used: point.used, bucketDays: days)
            if key == currentBucket {
                result[result.count - 1] = sample
            } else {
                result.append(sample)
                currentBucket = key
            }
        }
        return result
    }

    private func bucket(_ date: Date, days: Int) -> Int {
        Int((date.timeIntervalSinceReferenceDate / (86_400 * Double(days))).rounded(.down))
    }
}
