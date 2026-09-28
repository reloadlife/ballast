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
struct TrashLog: Sendable {
    let url: URL
    var limit = 20

    static let standard = TrashLog(url: URL(fileURLWithPath: Paths.supportDir + "/trash-log.json"))

    func load() -> [CleanupRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CleanupRecord].self, from: data)) ?? []
    }

    /// Adds a record, keeping the newest `limit`.
    @discardableResult
    func append(_ record: CleanupRecord) -> [CleanupRecord] {
        save(Array((load() + [record]).suffix(limit)))
    }

    /// Replaces the record with the same id, e.g. after Put Back.
    @discardableResult
    func update(_ record: CleanupRecord) -> [CleanupRecord] {
        save(load().map { $0.id == record.id ? record : $0 })
    }

    @discardableResult
    private func save(_ records: [CleanupRecord]) -> [CleanupRecord] {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(records).write(to: url, options: .atomic)
        return records
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
                    result.problems.append("\(name) is no longer in the Trash.")
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
