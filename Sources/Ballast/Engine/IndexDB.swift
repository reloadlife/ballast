import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DirRow: Identifiable, Hashable, Sendable {
    let id: Int64
    let parent: Int64?
    let name: String
    let own: Int64
    let ownFiles: Int64
    let total: Int64
    let files: Int64
    let err: Int32
    /// Unix seconds of the newest modification anywhere inside.
    let newest: Int64
}

/// A row plus the absolute on-volume path it was reached by.
struct Located {
    let row: DirRow
    let path: String
}

struct IndexError: LocalizedError {
    let message: String
    var errorDescription: String? { "Index: \(message)" }
}

/// The on-disk folder index. One row per directory, with totals that already
/// include every descendant, so any folder's size is a single lookup.
final class IndexDB {
    enum Mode {
        case read
        case write
        /// Fresh file for a full scan: no journal, indexes added at the end.
        case build
    }

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    enum Value {
        case int(Int64)
        case text(String)
        case null
    }

    init(path: String, mode: Mode) throws {
        let flags = mode == .read ? SQLITE_OPEN_READWRITE : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw IndexError(message: message)
        }
        sqlite3_busy_timeout(handle, 10_000)
        switch mode {
        case .build:
            try exec("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;")
            try exec("""
                CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE dirs(
                    id INTEGER PRIMARY KEY, parent INTEGER, name TEXT NOT NULL,
                    own INTEGER NOT NULL, own_files INTEGER NOT NULL,
                    total INTEGER NOT NULL, files INTEGER NOT NULL, err INTEGER NOT NULL,
                    newest INTEGER NOT NULL);
                """)
        case .write:
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        case .read:
            break
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    func createIndexes() throws {
        try exec("""
            CREATE INDEX dirs_parent ON dirs(parent, name);
            CREATE INDEX dirs_total ON dirs(total);
            CREATE INDEX dirs_err ON dirs(err) WHERE err != 0;
            """)
    }

    // MARK: Primitives

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw IndexError(message: message.map { String(cString: $0) } ?? "exec failed")
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func statement(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            statement = cached
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
                throw IndexError(message: String(cString: sqlite3_errmsg(handle)))
            }
            statements[sql] = prepared
            statement = prepared
        }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .int(let n): sqlite3_bind_int64(statement, index, n)
            case .text(let s): sqlite3_bind_text(statement, index, s, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        let s = try statement(sql, values)
        defer { sqlite3_reset(s) }
        let rc = sqlite3_step(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw IndexError(message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    func query<T>(_ sql: String, _ values: [Value] = [], _ map: (OpaquePointer) -> T) throws -> [T] {
        let s = try statement(sql, values)
        defer { sqlite3_reset(s) }
        var rows: [T] = []
        while true {
            switch sqlite3_step(s) {
            case SQLITE_ROW: rows.append(map(s))
            case SQLITE_DONE: return rows
            default: throw IndexError(message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    // MARK: Rows

    private static let columns = "id, parent, name, own, own_files, total, files, err, newest"

    private static func row(_ s: OpaquePointer) -> DirRow {
        DirRow(
            id: sqlite3_column_int64(s, 0),
            parent: sqlite3_column_type(s, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 1),
            name: String(cString: sqlite3_column_text(s, 2)),
            own: sqlite3_column_int64(s, 3),
            ownFiles: sqlite3_column_int64(s, 4),
            total: sqlite3_column_int64(s, 5),
            files: sqlite3_column_int64(s, 6),
            err: Int32(sqlite3_column_int64(s, 7)),
            newest: sqlite3_column_int64(s, 8)
        )
    }

    func upsert(id: Int64, parent: Int64?, name: String, node: WalkNode) throws {
        try run(
            "INSERT OR REPLACE INTO dirs(\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.int(id), parent.map(Value.int) ?? .null, .text(name), .int(node.own),
             .int(node.ownFiles), .int(node.total), .int(node.files), .int(Int64(node.err)), .int(node.newest)]
        )
    }

    func row(_ id: Int64) throws -> DirRow? {
        try query("SELECT \(Self.columns) FROM dirs WHERE id = ?", [.int(id)], Self.row).first
    }

    func root() throws -> DirRow? {
        try query("SELECT \(Self.columns) FROM dirs WHERE parent IS NULL LIMIT 1", [], Self.row).first
    }

    func child(of parent: Int64, named name: String) throws -> DirRow? {
        try query("SELECT \(Self.columns) FROM dirs WHERE parent = ? AND name = ?", [.int(parent), .text(name)], Self.row).first
    }

    func children(of id: Int64) throws -> [DirRow] {
        try query("SELECT \(Self.columns) FROM dirs WHERE parent = ? ORDER BY total DESC", [.int(id)], Self.row)
    }

    /// Every directory at least `bytes` big. Totals only grow toward the root,
    /// so the result always contains each row's full ancestor chain.
    func rows(atLeast bytes: Int64) throws -> [DirRow] {
        try query("SELECT \(Self.columns) FROM dirs WHERE total >= ?", [.int(bytes)], Self.row)
    }

    func unreadable() throws -> [DirRow] {
        try query("SELECT \(Self.columns) FROM dirs WHERE err != 0", [], Self.row)
    }

    func maxID() throws -> Int64 {
        try query("SELECT COALESCE(MAX(id), 0) FROM dirs") { sqlite3_column_int64($0, 0) }.first ?? 0
    }

    func setSizes(_ id: Int64, own: Int64, ownFiles: Int64, total: Int64, files: Int64, newest: Int64) throws {
        try run(
            "UPDATE dirs SET own = ?, own_files = ?, total = ?, files = ?, newest = ?, err = 0 WHERE id = ?",
            [.int(own), .int(ownFiles), .int(total), .int(files), .int(newest), .int(id)]
        )
    }

    func setError(_ id: Int64, _ err: Int32) throws {
        try run("UPDATE dirs SET err = ? WHERE id = ?", [.int(Int64(err)), .int(id)])
    }

    func deleteDescendants(of id: Int64) throws {
        try run("""
            WITH RECURSIVE sub(id) AS (
                SELECT id FROM dirs WHERE parent = ?
                UNION ALL SELECT d.id FROM dirs d JOIN sub ON d.parent = sub.id)
            DELETE FROM dirs WHERE id IN (SELECT id FROM sub)
            """, [.int(id)])
    }

    func deleteSubtree(_ id: Int64) throws {
        try deleteDescendants(of: id)
        try run("DELETE FROM dirs WHERE id = ?", [.int(id)])
    }

    /// Adds a size change to `start` and every folder above it, and raises
    /// their newest-modification time to at least `newest`.
    func propagate(from start: Int64?, bytes: Int64, files: Int64, newest: Int64) throws {
        var current = start
        while let id = current {
            try run(
                "UPDATE dirs SET total = total + ?, files = files + ?, newest = MAX(newest, ?) WHERE id = ?",
                [.int(bytes), .int(files), .int(newest), .int(id)]
            )
            current = try query("SELECT parent FROM dirs WHERE id = ?", [.int(id)]) {
                sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : sqlite3_column_int64($0, 0)
            }.first ?? nil
        }
    }

    /// Root-first list of rows from the root down to `id`.
    func chain(to id: Int64) throws -> [DirRow] {
        var chain: [DirRow] = []
        var current: Int64? = id
        while let id = current, let row = try row(id) {
            chain.append(row)
            current = row.parent
        }
        return chain.reversed()
    }

    /// Follows `path` down from the root as far as the index knows it.
    /// The last element is the deepest indexed folder on that path.
    func locate(_ path: String) throws -> [Located] {
        guard let root = try root() else { return [] }
        var result = [Located(row: root, path: root.name)]
        guard path.hasPrefix(root.name) else { return result }
        for component in path.dropFirst(root.name.count).split(separator: "/") {
            let last = result[result.count - 1]
            guard let child = try child(of: last.row.id, named: String(component)) else { break }
            result.append(Located(row: child, path: last.path + "/" + component))
        }
        return result
    }

    func path(of id: Int64) throws -> String {
        try chain(to: id).map(\.name).joined(separator: "/")
    }

    // MARK: Meta

    func meta(_ key: String) throws -> String? {
        try query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { String(cString: sqlite3_column_text($0, 0)) }.first
    }

    func setMeta(_ key: String, _ value: String) throws {
        try run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [.text(key), .text(value)])
    }
}
