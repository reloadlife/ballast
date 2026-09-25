import CoreServices
import Darwin
import Foundation

struct ScanStatus: Sendable {
    var title: String
    var walk: WalkProgress?
}

typealias StatusHandler = @Sendable (ScanStatus) -> Void

/// Builds and maintains the index. Everything here is synchronous and meant
/// to run off the main thread.
enum ScanEngine {
    enum Failure: Error {
        case needsFullScan
    }

    /// Bumped whenever the table layout changes; older indexes get rebuilt.
    static let schemaVersion = "2"

    /// More changed folders than this and a full walk is cheaper.
    private static let maxChanges = 25_000

    // MARK: Full scan

    static func fullScan(report: StatusHandler, cancel: CancelFlag) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        let building = Paths.index + ".building"
        try? fm.removeItem(atPath: building)

        // Taken before walking, so changes made during the walk get replayed next update.
        let startEvent = FSEventsGetCurrentEventId()
        do {
            let db = try IndexDB(path: building, mode: .build)
            try db.exec("BEGIN")
            var pending = 0
            try Walker.walk(
                Paths.volumeRoot,
                cancelled: { cancel.isSet },
                progress: { report(ScanStatus(title: "Scanning disk", walk: $0)) }
            ) { node in
                // Walk-local ids are unique, so they become row ids directly.
                try db.upsert(id: node.local + 1, parent: node.parent < 0 ? nil : node.parent + 1, name: node.name, node: node)
                pending += 1
                if pending == 50_000 {
                    try db.exec("COMMIT; BEGIN")
                    pending = 0
                }
            }
            try db.exec("COMMIT")
            report(ScanStatus(title: "Saving index"))
            try db.createIndexes()
            try saveCheckpoint(db, event: startEvent)
        } catch {
            try? fm.removeItem(atPath: building)
            throw error
        }

        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: Paths.index + suffix) }
        try fm.moveItem(atPath: building, toPath: Paths.index)
    }

    // MARK: Incremental update

    /// Rechecks only folders FSEvents reports as changed since the last scan.
    /// Throws `needsFullScan` when there is no usable history.
    static func update(report: StatusHandler, cancel: CancelFlag) throws {
        guard FileManager.default.fileExists(atPath: Paths.index) else { throw Failure.needsFullScan }
        let db = try IndexDB(path: Paths.index, mode: .write)
        // Schema first: older layouts fail on the row queries below.
        guard try db.meta("schema") == schemaVersion,
              try db.root() != nil,
              let since = try db.meta("eventId").flatMap(UInt64.init),
              try db.meta("volume") == Volume.eventsUUID
        else { throw Failure.needsFullScan }

        report(ScanStatus(title: "Reading change log"))
        let now = FSEventsGetCurrentEventId()
        guard let changes = ChangeLog.changes(under: Paths.volumeRoot, since: since),
              changes.count <= maxChanges
        else { throw Failure.needsFullScan }

        let (deep, shallow) = plan(changes)
        if deep.contains(Paths.volumeRoot) { throw Failure.needsFullScan }

        let updater = Updater(db: db, device: Volume.device, cancel: cancel)
        let total = deep.count + shallow.count
        try db.transaction {
            for (i, path) in (deep.map { ($0, true) } + shallow.map { ($0, false) }).enumerated() {
                if cancel.isSet { throw CancellationError() }
                report(ScanStatus(title: "Updating \(i + 1) of \(total) changed folders",
                                  walk: WalkProgress(path: Paths.display(path.0))))
                try updater.refresh(path.0, deep: path.1)
            }
            try saveCheckpoint(db, event: now)
        }
    }

    /// Normalises event paths and drops ones already covered by a deep rescan.
    private static func plan(_ changes: [ChangeLog.Change]) -> (deep: [String], shallow: [String]) {
        var deep = Set<String>()
        var shallow = Set<String>()
        for change in changes {
            var path = change.path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            path = Paths.onVolume(path)
            if change.recursive { deep.insert(path) } else { shallow.insert(path) }
        }

        func covered(_ path: String, by set: Set<String>, includingSelf: Bool) -> Bool {
            var current = path
            if !includingSelf { current = parent(of: current) ?? "" }
            while !current.isEmpty {
                if set.contains(current) { return true }
                current = parent(of: current) ?? ""
            }
            return false
        }

        let keptDeep = deep.filter { !covered($0, by: deep, includingSelf: false) }
        let keptShallow = shallow.filter { !covered($0, by: keptDeep, includingSelf: true) }
        return (keptDeep.sorted(), keptShallow.sorted())
    }

    private static func parent(of path: String) -> String? {
        guard path.count > Paths.volumeRoot.count, let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<slash])
    }

    // MARK: Locked folders

    /// Rewalks the given folders as the current user: locked ones after Full
    /// Disk Access was granted, or ones that were just cleaned. Paths that no
    /// longer exist are dropped from their parent.
    static func rescan(_ paths: [String], title: String, report: StatusHandler, cancel: CancelFlag) throws {
        let db = try IndexDB(path: Paths.index, mode: .write)
        let updater = Updater(db: db, device: Volume.device, cancel: cancel)
        try db.transaction {
            for (i, path) in paths.enumerated() {
                if cancel.isSet { throw CancellationError() }
                report(ScanStatus(title: "\(title) \(i + 1) of \(paths.count)",
                                  walk: WalkProgress(path: Paths.display(path))))
                try updater.refresh(path, deep: true)
            }
        }
    }

    /// Merges subtrees measured by the privileged helper into the index.
    static func graft(_ results: [AdminResult]) throws {
        let db = try IndexDB(path: Paths.index, mode: .write)
        let updater = Updater(db: db, device: Volume.device, cancel: CancelFlag())
        try db.transaction {
            for result in results { try updater.graft(result) }
        }
    }

    private static func saveCheckpoint(_ db: IndexDB, event: FSEventStreamEventId) throws {
        try db.setMeta("eventId", String(event))
        try db.setMeta("volume", Volume.eventsUUID ?? "")
        try db.setMeta("scannedAt", String(Date.now.timeIntervalSince1970))
        try db.setMeta("schema", schemaVersion)
    }
}

/// Applies changes to single folders while keeping every ancestor's totals right.
private struct Updater {
    let db: IndexDB
    let device: dev_t
    let cancel: CancelFlag

    /// `deep` rewalks the whole subtree; otherwise only direct children are
    /// re-listed and unchanged subfolders keep their stored totals.
    func refresh(_ path: String, deep: Bool) throws {
        // The deepest indexed folder on this path that still exists: new
        // folders are picked up by their parent, deleted ones vanish from it.
        let known = try db.locate(path)
        guard let target = known.last(where: { isDirectory($0.path) }) else { return }
        if deep && target.path == path {
            try replace(target)
        } else {
            try relist(target)
        }
    }

    func graft(_ result: AdminResult) throws {
        guard let target = try db.locate(result.path).last, target.path == result.path else { return }
        try db.deleteDescendants(of: target.row.id)
        let root = try store(rootID: target.row.id, parent: target.row.parent, name: target.row.name) { emit in
            for node in result.nodes { try emit(node) }
        }
        try db.propagate(from: target.row.parent, bytes: root.total - target.row.total, files: root.files - target.row.files, newest: root.newest)
    }

    private func replace(_ target: Located) throws {
        try db.deleteDescendants(of: target.row.id)
        let root = try store(rootID: target.row.id, parent: target.row.parent, name: target.row.name) { emit in
            try Walker.walk(target.path, cancelled: { cancel.isSet }, emit: emit)
        }
        try db.propagate(from: target.row.parent, bytes: root.total - target.row.total, files: root.files - target.row.files, newest: root.newest)
    }

    private func relist(_ target: Located) throws {
        let row = target.row
        guard let dir = opendir(target.path) else {
            try db.setError(row.id, errno)  // keep the old sizes, mark as locked
            return
        }
        defer { closedir(dir) }

        var own: Int64 = 0
        var ownFiles: Int64 = 0
        var newest: Int64 = 0
        var subdirs = Set<String>()
        var dirStat = stat()
        if lstat(target.path, &dirStat) == 0 { newest = Walker.plausible(Int64(dirStat.st_mtimespec.tv_sec)) }
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard lstat(target.path + "/" + name, &st) == 0 else { continue }
            if st.st_mode & S_IFMT == S_IFDIR {
                if st.st_dev == device { subdirs.insert(name) }
            } else {
                own += Int64(st.st_blocks) * 512
                ownFiles += 1
                newest = max(newest, Walker.plausible(Int64(st.st_mtimespec.tv_sec)))
            }
        }

        var total = own
        var files = ownFiles
        for child in try db.children(of: row.id) {
            if subdirs.remove(child.name) != nil {
                total += child.total
                files += child.files
                newest = max(newest, child.newest)
            } else {
                try db.deleteSubtree(child.id)
            }
        }
        for name in subdirs {
            let node = try store(rootID: nil, parent: row.id, name: name) { emit in
                try Walker.walk(target.path + "/" + name, cancelled: { cancel.isSet }, emit: emit)
            }
            total += node.total
            files += node.files
            newest = max(newest, node.newest)
        }

        try db.setSizes(row.id, own: own, ownFiles: ownFiles, total: total, files: files, newest: newest)
        try db.propagate(from: row.parent, bytes: total - row.total, files: files - row.files, newest: newest)
    }

    /// Inserts walk output under `parent`, mapping walk-local ids onto fresh
    /// row ids. `rootID` reuses an existing row for the walk root.
    private func store(
        rootID: Int64?, parent: Int64?, name: String,
        produce: ((WalkNode) throws -> Void) throws -> Void
    ) throws -> WalkNode {
        let base = try db.maxID() + 1
        let rootRow = rootID ?? base
        func id(_ local: Int64) -> Int64 { local == 0 ? rootRow : base + local }

        var root: WalkNode?
        try produce { node in
            let isRoot = node.local == 0
            try db.upsert(
                id: id(node.local),
                parent: isRoot ? parent : id(node.parent),
                name: isRoot ? name : node.name,
                node: node
            )
            if isRoot { root = node }
        }
        guard let root else { throw IndexError(message: "walk of \(name) produced no root") }
        return root
    }

    private func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }
}
