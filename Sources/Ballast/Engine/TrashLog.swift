import Darwin
import Foundation

/// One file or folder a cleanup moved to the Trash, and where it went
/// there (the Trash renames on name clashes: "node_modules 2").
struct TrashMove: Codable, Hashable, Sendable {
    let from: String
    let to: String
    var restored = false
}

/// What one cleanup did, kept so it can be put back.
struct CleanupRecord: Codable, Identifiable, Sendable {
    struct Item: Codable, Sendable {
        let name: String
        let path: String
        let bytes: Int64
        /// Empty when it was deleted outright or cleaned by a tool command.
        var moves: [TrashMove]
    }

    var id = UUID()
    var date = Date.now
    /// Delete Now was chosen. Uninstalls went to the Trash anyway.
    var permanent: Bool
    /// Done by an auto-clean rule rather than from the Cleanup List.
    var auto = false
    var items: [Item]

    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    /// A record of what the Cleaner did; nil when nothing was cleaned.
    init?(outcomes: [CleanOutcome], permanent: Bool, auto: Bool = false) {
        let items = outcomes.filter { $0.succeeded || !$0.moves.isEmpty }.map {
            Item(name: $0.item.name, path: $0.item.path, bytes: $0.item.bytes, moves: $0.moves)
        }
        guard !items.isEmpty else { return nil }
        self.init(permanent: permanent, auto: auto, items: items)
    }

    init(permanent: Bool, auto: Bool = false, items: [Item]) {
        self.permanent = permanent
        self.auto = auto
        self.items = items
    }

    /// Moves that can still be undone: not put back yet, still in the Trash.
    var pending: [TrashMove] {
        items.flatMap(\.moves).filter { !$0.restored && FileManager.default.fileExists(atPath: $0.to) }
    }

    var canPutBack: Bool { !pending.isEmpty }
    var wasPutBack: Bool { items.contains { $0.moves.contains(where: \.restored) } }
}

/// The last cleanups, newest last, in trash-log.json next to the index.
/// The app and the `--auto-clean` agent both add to it, so every
/// read-modify-write holds a file lock. Writes are atomic, so a plain
/// read never sees half a file and needs no lock.
struct TrashLog: Sendable {
    let url: URL
    var limit = 20

    static let standard = TrashLog(url: URL(fileURLWithPath: Paths.supportDir + "/trash-log.json"))

    func load() -> [CleanupRecord] {
        read() ?? []
    }

    /// Adds a record, keeping the newest `limit`.
    @discardableResult
    func append(_ record: CleanupRecord) -> [CleanupRecord] {
        FileLock.withLock(url) { save(Array((readForWriting() + [record]).suffix(limit))) }
    }

    /// Replaces the record with the same id, e.g. after Put Back, or adds
    /// it when it isn't there yet: a cleanup in progress logs itself after
    /// every item, so quitting halfway still leaves it in the log.
    @discardableResult
    func update(_ record: CleanupRecord) -> [CleanupRecord] {
        FileLock.withLock(url) {
            var records = readForWriting()
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            } else {
                records.append(record)
            }
            return save(Array(records.suffix(limit)))
        }
    }

    /// Nil when there's a file but nothing in it could be read. Records
    /// that can't be read are skipped, not the whole log.
    private func read() -> [CleanupRecord]? {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode(LossyArray<CleanupRecord>.self, from: data))?.elements
    }

    /// Like `read()`, but an unreadable file is kept aside instead of being
    /// overwritten, so a format this version doesn't know never silently
    /// wipes what could be put back.
    private func readForWriting() -> [CleanupRecord] {
        if let records = read() { return records }
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return []
    }

    @discardableResult
    private func save(_ records: [CleanupRecord]) -> [CleanupRecord] {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: url, options: .atomic)
        return records
    }
}

// Missing keys fall back to defaults, so logs from older or newer versions
// still load and can be put back.
extension TrashMove {
    private enum CodingKeys: String, CodingKey { case from, to, restored }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        restored = try c.decodeIfPresent(Bool.self, forKey: .restored) ?? false
    }
}

extension CleanupRecord.Item {
    private enum CodingKeys: String, CodingKey { case name, path, bytes, moves }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? (path as NSString).lastPathComponent
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        moves = (try? c.decodeIfPresent(LossyArray<TrashMove>.self, forKey: .moves))?.elements ?? []
    }
}

extension CleanupRecord {
    private enum CodingKeys: String, CodingKey { case id, date, permanent, auto, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let items = (try? c.decodeIfPresent(LossyArray<Item>.self, forKey: .items))?.elements ?? []
        self.init(permanent: try c.decodeIfPresent(Bool.self, forKey: .permanent) ?? false,
                  auto: try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false,
                  items: items)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? .distantPast
    }
}

/// An array decoded element by element: one element that doesn't decode
/// (an unknown kind, a missing key) is dropped instead of failing the lot.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(Skipped.self)) == nil {
                // A failed decode doesn't move past the element; Skipped
                // does. If even that fails, stop rather than spin.
                break
            }
        }
        self.elements = elements
    }

    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// An advisory lock (flock) on a sidecar `<file>.lock`, shared by the app
/// and the command-line runs, so two read-modify-write cycles on the same
/// JSON file can't lose each other's changes. Locks taken on separate
/// descriptors exclude each other within one process too.
enum FileLock {
    /// Runs `body` holding the lock. If the lock file can't be opened, runs
    /// unlocked rather than not at all.
    static func withLock<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let fd = open(url)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { release(fd) }
        return try body()
    }

    /// Runs `body` only if nobody holds the lock; nil when someone does.
    /// Keeps an auto-clean run in the app and the agent's from overlapping.
    static func tryLock<T>(_ url: URL, _ body: () throws -> T) rethrows -> T? {
        let fd = open(url)
        guard fd >= 0 else { return try body() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        defer { release(fd) }
        return try body()
    }

    private static func open(_ url: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    }

    private static func release(_ fd: Int32) {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Moves a cleanup's items from the Trash back where they were, like
/// Finder's Put Back. Nothing is ever overwritten.
enum PutBack {
    struct Result: Sendable {
        var restored: [TrashMove] = []
        /// One plain sentence per item left in the Trash.
        var problems: [String] = []
    }

    static func run(_ record: inout CleanupRecord) -> Result {
        let fm = FileManager.default
        var result = Result()
        for i in record.items.indices {
            for j in record.items[i].moves.indices where !record.items[i].moves[j].restored {
                let move = record.items[i].moves[j]
                let name = (move.from as NSString).lastPathComponent
                guard fm.fileExists(atPath: move.to) else {
                    // Trashed on a drive that's unplugged now: it's still
                    // there, and Put Back works again once it's connected.
                    if let drive = Drives.facts(for: move.to), !drive.isConnected {
                        result.problems.append("\(name) is in the Trash on \(drive.name), which isn't connected.")
                    } else {
                        result.problems.append("\(name) is no longer in the Trash.")
                    }
                    continue
                }
                var st = stat()
                if lstat(move.from, &st) == 0 {
                    result.problems.append("A new \(name) exists there now, so it was left in the Trash.")
                    continue
                }
                do {
                    let parent = (move.from as NSString).deletingLastPathComponent
                    try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                    try fm.moveItem(atPath: move.to, toPath: move.from)
                    record.items[i].moves[j].restored = true
                    result.restored.append(move)
                } catch {
                    result.problems.append("\(name) couldn't be put back: \(error.localizedDescription)")
                }
            }
        }
        return result
    }
}
