import Foundation
import SQLite3

// MARK: Store

/// When a snapshot of folder sizes was taken, and the smallest folder it holds.
struct GrowthSnapshot: Sendable, Hashable {
    /// Local day number, or `GrowthStore.sessionKey` for the "last open" copy.
    let key: Int
    let taken: Date
    /// Folders below this weren't recorded: a missing path means "smaller
    /// than this", not "empty".
    let floor: Int64
}

/// Folder sizes over time, so the Overview can say what grew.
///
/// Lives in its own `growth.sqlite` beside the index: a full scan replaces
/// the index file and renumbers every row, so history is keyed by path and
/// kept where a rebuild can't reach it. Only folders of at least `floor`
/// are recorded (about 5,000 on a 500 GB disk, not the index's 600k), one
/// snapshot per day, the day's last reading winning. Daily snapshots are
/// kept for 30 days, then one a week up to 90 days.
final class GrowthStore {
    /// Decimal, like every figure Ballast shows: "20 MB" means 20,000,000 bytes.
    static let floor: Int64 = 20_000_000
    /// The newest snapshot as it was when this session began: "since last open".
    static let sessionKey = -1
    static let retentionDays = 90
    static let dailyDays = 30

    private let db: IndexDB

    init(path: String = Paths.growth) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        db = try IndexDB(path: path, mode: .write)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS paths(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE);
            CREATE TABLE IF NOT EXISTS snapshots(key INTEGER PRIMARY KEY, taken REAL NOT NULL, floor INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS sizes(
                key INTEGER NOT NULL, path_id INTEGER NOT NULL, bytes INTEGER NOT NULL,
                PRIMARY KEY(key, path_id)) WITHOUT ROWID;
            """)
    }

    /// Local calendar day, so "today" turns over at the user's midnight.
    static func dayKey(_ date: Date) -> Int {
        let local = date.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: date))
        return Int((local / 86_400).rounded(.down))
    }

    /// Saves today's sizes (display path → bytes), replacing any earlier
    /// reading today. `newSession` first keeps the newest snapshot aside as
    /// the "since last open" baseline.
    func record(_ sizes: [String: Int64], at date: Date = .now, floor: Int64 = GrowthStore.floor, newSession: Bool) throws {
        let today = Self.dayKey(date)
        try db.transaction {
            if newSession, let latest = try snapshots().last(where: { $0.key >= 0 }) {
                try copy(latest.key, to: Self.sessionKey)
            }
            let isNewDay = try !snapshots().contains { $0.key == today }
            try db.run("DELETE FROM sizes WHERE key = ?", [.int(Int64(today))])
            for (path, bytes) in sizes where bytes >= floor {
                try db.run("INSERT OR IGNORE INTO paths(path) VALUES (?)", [.text(path)])
                try db.run("INSERT INTO sizes(key, path_id, bytes) VALUES (?, (SELECT id FROM paths WHERE path = ?), ?)",
                           [.int(Int64(today)), .text(path), .int(bytes)])
            }
            try db.run("INSERT OR REPLACE INTO snapshots(key, taken, floor) VALUES (?, ?, ?)",
                       [.int(Int64(today)), .text(String(date.timeIntervalSince1970)), .int(floor)])
            if isNewDay { try prune(today: today) }
        }
    }

    func snapshots() throws -> [GrowthSnapshot] {
        try db.query("SELECT key, taken, floor FROM snapshots ORDER BY key") {
            GrowthSnapshot(key: Int(sqlite3_column_int64($0, 0)),
                           taken: Date(timeIntervalSince1970: sqlite3_column_double($0, 1)),
                           floor: sqlite3_column_int64($0, 2))
        }
    }

    func sizes(_ key: Int) throws -> [String: Int64] {
        let rows = try db.query(
            "SELECT p.path, s.bytes FROM sizes s JOIN paths p ON p.id = s.path_id WHERE s.key = ?", [.int(Int64(key))]
        ) { (String(cString: sqlite3_column_text($0, 0)), sqlite3_column_int64($0, 1)) }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    private func copy(_ key: Int, to target: Int) throws {
        try db.run("DELETE FROM sizes WHERE key = ?", [.int(Int64(target))])
        try db.run("INSERT INTO sizes(key, path_id, bytes) SELECT ?, path_id, bytes FROM sizes WHERE key = ?",
                   [.int(Int64(target)), .int(Int64(key))])
        try db.run("INSERT OR REPLACE INTO snapshots(key, taken, floor) SELECT ?, taken, floor FROM snapshots WHERE key = ?",
                   [.int(Int64(target)), .int(Int64(key))])
    }

    /// Drops days past the retention window and thins older days to the
    /// last one of each week, then paths no snapshot mentions any more.
    private func prune(today: Int) throws {
        let days = try snapshots().map(\.key).filter { $0 >= 0 }
        let oldest = today - Self.retentionDays
        let daily = today - Self.dailyDays
        let weekly = Dictionary(grouping: days.filter { $0 >= oldest && $0 < daily }, by: { $0 / 7 })
        let kept = Set(weekly.values.compactMap { $0.max() })
        for key in days where key < oldest || (key < daily && !kept.contains(key)) {
            try db.run("DELETE FROM sizes WHERE key = ?", [.int(Int64(key))])
            try db.run("DELETE FROM snapshots WHERE key = ?", [.int(Int64(key))])
        }
        try db.run("DELETE FROM paths WHERE id NOT IN (SELECT DISTINCT path_id FROM sizes)")
    }

    /// Forgets every snapshot, e.g. from Settings › Data.
    static func clear(path: String = Paths.growth) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }
}

// MARK: Comparing

/// How far back "what grew" looks.
enum GrowthPeriod: String, CaseIterable, Identifiable, Sendable {
    case lastOpen, day, week, month

    var id: Self { self }

    var title: String {
        switch self {
        case .lastOpen: "Since Last Open"
        case .day: "Last 24 Hours"
        case .week: "Last 7 Days"
        case .month: "Last 30 Days"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .lastOpen: nil
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }
}

/// One folder in "what grew" (or what shrank).
struct GrowthRow: Identifiable, Sendable, Hashable {
    /// Display path.
    let path: String
    /// Change this row accounts for: the folder's own change minus what the
    /// listed folders inside it already show, so no byte is counted twice.
    /// Positive for growth, negative for shrinkage.
    let bytes: Int64
    /// The folder's whole change, including listed folders inside it.
    let change: Int64
    /// Size now; nil when it's gone or below the recording floor.
    let size: Int64?
    /// The biggest listed folders inside this one (up to three), whose
    /// change `bytes` leaves out, and how many there are in all.
    let inside: [String]
    let insideCount: Int

    var id: String { path }
    var name: String { path == "/" ? Paths.volumeName : (path as NSString).lastPathComponent }
}

struct GrowthReport: Sendable {
    let since: Date
    /// Biggest growth first, disjoint (no row's bytes are in another's).
    let grew: [GrowthRow]
    /// Space that disappeared from folders that shrank, counted once.
    let freed: Int64
}

/// What the Overview shows: which periods have data, and the chosen one.
struct GrowthSummary: Sendable {
    let periods: [GrowthPeriod]
    let period: GrowthPeriod?
    let report: GrowthReport?
    /// Net change of everything Ballast measures since yesterday's last
    /// reading; nil without one.
    let today: Int64?
    /// Days with a snapshot, and the first of them.
    let days: Int
    let since: Date?

    static let empty = GrowthSummary(periods: [], period: nil, report: nil, today: nil, days: 0, since: nil)
}

enum Growth {
    /// Smaller changes aren't listed: under the recording floor they're
    /// within the uncertainty, and they wouldn't explain a full disk.
    static let minimum: Int64 = 100_000_000
    /// A folder is only listed for what its listed subfolders don't explain;
    /// if they cover 80% or more of its change, they speak for it.
    static let explainedShare = 0.8

    /// The snapshot to compare against for a period, or nil when there's no
    /// history that covers it. Periods pick the reading nearest to "now
    /// minus the period", within half to one and a half times the period, so
    /// "7 days" never quietly means 60. The card prints the date it actually
    /// compares with.
    static func baseline(for period: GrowthPeriod, in snapshots: [GrowthSnapshot], current: GrowthSnapshot, now: Date) -> GrowthSnapshot? {
        guard let interval = period.interval else {
            return snapshots.first { $0.key == GrowthStore.sessionKey && $0.taken < current.taken }
        }
        let target = now.addingTimeInterval(-interval)
        let earliest = now.addingTimeInterval(-1.5 * interval)
        let latest = now.addingTimeInterval(-interval / 2)
        return snapshots
            .filter { $0.key >= 0 && $0.key != current.key && $0.taken >= earliest && $0.taken <= latest }
            .min { abs($0.taken.timeIntervalSince(target)) < abs($1.taken.timeIntervalSince(target)) }
    }

    static func periods(in snapshots: [GrowthSnapshot], current: GrowthSnapshot, now: Date) -> [GrowthPeriod] {
        GrowthPeriod.allCases.filter { baseline(for: $0, in: snapshots, current: current, now: now) != nil }
    }

    /// Change per path between two snapshots. A path missing from one side
    /// was below that side's floor, so it counts as the floor there: the
    /// change shown is a lower bound, never more than what happened.
    static func changes(old: [String: Int64], oldFloor: Int64, new: [String: Int64], newFloor: Int64) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for (path, bytes) in new {
            if let before = old[path] {
                result[path] = bytes - before
            } else {
                result[path] = max(bytes - oldFloor, 0)
            }
        }
        for (path, before) in old where new[path] == nil {
            result[path] = min(newFloor - before, 0)
        }
        return result
    }

    /// The folders that explain the positive changes, biggest first. Deepest
    /// folders go first; a parent is listed only for the change its listed
    /// subfolders leave unexplained, and only when that is at least
    /// `minimum` and a fifth of its own change. So a parent whose growth is
    /// one child's gives way to that child, and nothing is counted twice.
    static func rank(_ changes: [String: Int64], sizes: [String: Int64] = [:], minimum: Int64 = Growth.minimum) -> [GrowthRow] {
        var children: [String: [String]] = [:]
        for path in changes.keys {
            if let parent = parent(of: path) { children[parent, default: []].append(path) }
        }
        // Per path: the biggest listed folders inside it (outermost only),
        // how many there are, and what they add up to. Only a few names are
        // carried up, so a disk where everything changed stays linear.
        var listedInside: [String: (top: [String], count: Int)] = [:]
        var covered: [String: Int64] = [:]
        func biggest(_ paths: [String]) -> [String] {
            Array(paths.sorted { (changes[$0] ?? 0) != (changes[$1] ?? 0) ? (changes[$0] ?? 0) > (changes[$1] ?? 0) : $0 < $1 }.prefix(3))
        }
        var listed: [String: GrowthRow] = [:]
        let depths = Dictionary(uniqueKeysWithValues: changes.keys.map { ($0, depth($0)) })
        let deepestFirst = changes.keys.sorted { depths[$0]! != depths[$1]! ? depths[$0]! > depths[$1]! : $0 < $1 }
        for path in deepestFirst {
            var inside: [String] = []
            var count = 0
            var explained: Int64 = 0
            for child in children[path] ?? [] {
                if listed[child] != nil {
                    inside.append(child)
                    count += 1
                    explained += changes[child] ?? 0
                } else if let below = listedInside[child] {
                    inside += below.top
                    count += below.count
                    explained += covered[child] ?? 0
                }
            }
            inside = biggest(inside)
            let change = changes[path] ?? 0
            let residual = change - explained
            if change > 0, residual >= minimum, Double(residual) >= Double(change) * (1 - explainedShare) {
                listed[path] = GrowthRow(path: path, bytes: residual, change: change, size: sizes[path],
                                         inside: inside, insideCount: count)
            }
            if count > 0 {
                listedInside[path] = (inside, count)
                covered[path] = explained
            }
        }
        return listed.values.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
    }

    /// Growth and shrinkage between two snapshots.
    static func report(old: [String: Int64], oldFloor: Int64, new: [String: Int64], newFloor: Int64,
                       since: Date, limit: Int = 8) -> GrowthReport {
        let changes = changes(old: old, oldFloor: oldFloor, new: new, newFloor: newFloor)
        let grew = rank(changes, sizes: new)
        let shrank = rank(changes.mapValues { -$0 })
        return GrowthReport(since: since, grew: Array(grew.prefix(limit)), freed: shrank.reduce(0) { $0 + $1.bytes })
    }

    /// Reads the store and compares today's snapshot with the chosen
    /// period's baseline, or the first period that has one.
    static func summary(_ store: GrowthStore, period requested: GrowthPeriod?, now: Date = .now) throws -> GrowthSummary {
        let snapshots = try store.snapshots()
        let daily = snapshots.filter { $0.key >= 0 }
        guard let current = daily.first(where: { $0.key == GrowthStore.dayKey(now) }) ?? daily.last else { return .empty }
        let periods = periods(in: snapshots, current: current, now: now)
        let preferred: [GrowthPeriod] = [.day, .lastOpen, .week, .month]
        let period = requested.flatMap { periods.contains($0) ? $0 : nil } ?? preferred.first { periods.contains($0) }
        let new = try store.sizes(current.key)

        var report: GrowthReport?
        if let period, let baseline = baseline(for: period, in: snapshots, current: current, now: now) {
            report = Self.report(old: try store.sizes(baseline.key), oldFloor: baseline.floor,
                                 new: new, newFloor: current.floor, since: baseline.taken)
        }
        var today: Int64?
        if let yesterday = daily.first(where: { $0.key == current.key - 1 }),
           let before = try store.sizes(yesterday.key)["/"], let after = new["/"] {
            today = after - before
        }
        return GrowthSummary(periods: periods, period: period, report: report, today: today,
                             days: daily.count, since: daily.first?.taken)
    }

    static func parent(of path: String) -> String? {
        path == "/" ? nil : (path as NSString).deletingLastPathComponent
    }

    private static func depth(_ path: String) -> Int {
        path == "/" ? 0 : path.split(separator: "/").count
    }
}
