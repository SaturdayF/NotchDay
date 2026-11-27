import Foundation
import IOKit
import Observation
import SQLite3

struct ActivitySummary: Sendable {
    struct Item: Identifiable, Sendable {
        let id: String
        let seconds: TimeInterval
    }

    let seconds: TimeInterval
    let hours: [TimeInterval]
    let apps: [Item]
    let domains: [Item]
}

@MainActor
@Observable
final class ActivityFeed {
    enum State {
        case loading, available(ActivitySummary), accessDenied, unavailable
    }

    private(set) var state: State = .loading
    private var refreshedAt: Date?
    private var refreshing = false

    func refresh(force: Bool = false) async {
        let now = Date.now
        guard !refreshing, force || refreshedAt.map({ now.timeIntervalSince($0) >= 45 }) != false else { return }
        refreshing = true
        if force { state = .loading }
        let result = await Task.detached(priority: .utility) {
            Result { try KnowledgeActivity.read(now: now) }
        }.value
        refreshing = false
        refreshedAt = now
        switch result {
        case let .success(summary): state = .available(summary)
        case .failure(KnowledgeActivity.ReadError.accessDenied): state = .accessDenied
        case .failure: state = .unavailable
        }
    }
}

enum KnowledgeActivity {
    enum ReadError: Error {
        case accessDenied, unavailable
    }

    static func read(
        now: Date,
        url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Knowledge/knowledgeC.db")
    ) throws -> ActivitySummary {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        defer { if let handle { sqlite3_close(handle) } }
        guard result == SQLITE_OK, let database = handle else {
            if let handle, sqlite3_system_errno(handle) == ENOENT { throw ReadError.unavailable }
            throw readError(result)
        }
        sqlite3_busy_timeout(database, 150)

        let calendar = Calendar.autoupdatingCurrent
        let midnight = calendar.startOfDay(for: now)
        let lower = midnight.timeIntervalSinceReferenceDate
        let upper = now.timeIntervalSinceReferenceDate
        let supportsDevices = hasColumn("ZDEVICEID", in: "ZSOURCE", database)
            && hasColumn("ZSOURCE", in: "ZOBJECT", database)
        let supportsWeb = hasColumn("Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN", in: "ZSTRUCTUREDMETADATA", database)
            && hasColumn("ZSTRUCTUREDMETADATA", in: "ZOBJECT", database)
        let sourceJoin = supportsDevices ? "LEFT JOIN ZSOURCE s ON o.ZSOURCE = s.Z_PK" : ""
        let sourceFilter = supportsDevices ? "AND (NULLIF(s.ZDEVICEID, '') IS NULL OR s.ZDEVICEID = ?3 COLLATE NOCASE)" : ""
        let metadataJoin = supportsWeb ? "LEFT JOIN ZSTRUCTUREDMETADATA m ON o.ZSTRUCTUREDMETADATA = m.Z_PK" : ""
        let domain = supportsWeb ? "m.Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN" : "NULL"
        let query = """
            SELECT o.ZSTREAMNAME, o.ZVALUESTRING, o.ZSTARTDATE, o.ZENDDATE, \(domain)
            FROM ZOBJECT o
            \(sourceJoin)
            \(metadataJoin)
            WHERE o.ZSTREAMNAME IN ('/app/usage', '/app/webUsage')
              AND o.ZENDDATE > ?1 AND o.ZSTARTDATE < ?2
              \(sourceFilter)
            ORDER BY o.ZSTARTDATE
            """
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        defer { if let statement { sqlite3_finalize(statement) } }
        guard prepared == SQLITE_OK, let statement else { throw readError(prepared) }
        sqlite3_bind_double(statement, 1, lower)
        sqlite3_bind_double(statement, 2, upper)
        if supportsDevices, let deviceID = localDeviceID() {
            _ = deviceID.withCString { sqlite3_bind_text(statement, 3, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }

        var apps: [String: UsageTotal] = [:]
        var domains: [String: UsageTotal] = [:]
        var combined: [Range<Double>] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw readError(step) }
            let start = max(lower, sqlite3_column_double(statement, 2))
            let end = min(upper, sqlite3_column_double(statement, 3))
            guard start.isFinite, end.isFinite, end > start else { continue }
            if string(statement, 0) == "/app/usage", let id = string(statement, 1), !id.isEmpty {
                apps[id, default: UsageTotal()].add(start..<end)
            } else if let domain = string(statement, 4)?.lowercased(), !domain.isEmpty {
                domains[domain, default: UsageTotal()].add(start..<end)
            } else {
                continue
            }
            // The query returns rows in start-time order, including after clipping.
            if let last = combined.last, start <= last.upperBound {
                combined[combined.count - 1] = last.lowerBound..<max(last.upperBound, end)
            } else {
                combined.append(start..<end)
            }
        }

        var hours = Array(repeating: 0.0, count: 24)
        for interval in combined {
            var cursor = Date(timeIntervalSinceReferenceDate: interval.lowerBound)
            let limit = Date(timeIntervalSinceReferenceDate: interval.upperBound)
            while cursor < limit, let hour = calendar.dateInterval(of: .hour, for: cursor) {
                let end = min(hour.end, limit)
                guard end > cursor else { break }
                hours[calendar.component(.hour, from: cursor)] += end.timeIntervalSince(cursor)
                cursor = end
            }
        }
        return ActivitySummary(
            seconds: combined.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }, hours: hours,
            apps: ranked(apps), domains: ranked(domains)
        )
    }

    private static func ranked(_ groups: [String: UsageTotal]) -> [ActivitySummary.Item] {
        groups.map { id, total in
            ActivitySummary.Item(id: id, seconds: total.seconds)
        }.sorted { lhs, rhs in
            lhs.seconds == rhs.seconds ? lhs.id < rhs.id : lhs.seconds > rhs.seconds
        }
    }

    private struct UsageTotal {
        private var end = -Double.infinity
        private(set) var seconds = 0.0

        mutating func add(_ interval: Range<Double>) {
            seconds += max(0, interval.upperBound - max(end, interval.lowerBound))
            end = max(end, interval.upperBound)
        }
    }

    private static func string(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        let buffer = UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index)))
        return String(validating: buffer, as: UTF8.self)
    }

    private static func hasColumn(_ name: String, in table: String, _ database: OpaquePointer) -> Bool {
        sqlite3_table_column_metadata(database, "main", table, name, nil, nil, nil, nil, nil) == SQLITE_OK
    }

    private static func localDeviceID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func readError(_ code: Int32) -> ReadError {
        switch code & 0xff {
        case SQLITE_AUTH, SQLITE_PERM, SQLITE_CANTOPEN: .accessDenied
        default: .unavailable
        }
    }
}
