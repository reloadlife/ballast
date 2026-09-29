import CoreServices
import Darwin
import Foundation

struct ScanStatus: Sendable {
    var title: String
    var walk: WalkProgress?
}

typealias StatusHandler = @Sendable (ScanStatus) -> Void

/// One index and the volume it measures: the startup disk's data volume,
/// or another mounted volume (external drive, disk image, other APFS
/// volume) with its own index under `volumes/<UUID>/`.
struct IndexTarget: Sendable {
    /// The SQLite file.
    let index: String
    /// Where walks start, and the name of the index's root row.
    let root: String
    let device: dev_t
    /// Set for every volume but the startup disk.
    let volume: MountedVolume?

    var isStartup: Bool { volume == nil }

    static var startup: IndexTarget {
        IndexTarget(index: Paths.index, root: Paths.volumeRoot, device: Volume.device, volume: nil)
    }

    static func volume(_ volume: MountedVolume) -> IndexTarget? {
        guard let index = Paths.volumeIndex(volume.uuid) else { return nil }
        return IndexTarget(index: index, root: volume.path, device: volume.device, volume: volume)
    }

    /// Title while walking the whole volume; the app shows a percentage
    /// next to it when the last scan's file count is known.
    var scanTitle: String { volume.map { "Scanning \($0.name)" } ?? "Scanning disk" }

    /// Excluded folders as paths on this volume. The startup disk's are
    /// computed exactly as before, so its stored fingerprint still matches.
    var excluded: Exclusions {
        guard let volume else { return .current }
        return Exclusions(drive: volume.path, Preferences.current.excludedFolders)
    }

    var eventsUUID: String? { Volume.eventsUUID(device) }

    /// Display path → path in the index. Other volumes' paths are the
    /// same both ways ("/Volumes/Drive/…").
    func onVolume(_ display: String) -> String { isStartup ? Paths.onVolume(display) : display }
    func display(_ path: String) -> String { isStartup ? Paths.display(path) : path }

    /// A drive unplugged or force-ejected mid-walk leaves fts reporting
    /// every folder as unreadable, which would look like a finished scan
    /// of an empty drive. Checked before anything is saved.
    func checkStillMounted() throws {
        guard let volume else { return }
        var st = stat()
        let uuid = try? URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        guard lstat(root, &st) == 0, st.st_dev == device,
              uuid.flatMap(UUID.init(uuidString:))?.uuidString == volume.uuid else {
            throw ScanEngine.Failure.volumeGone(volume.name)
        }
    }
}

/// Builds and maintains the index. Everything here is synchronous and meant
/// to run off the main thread.
enum ScanEngine {
    enum Failure: LocalizedError {
        case needsFullScan
        /// The drive was ejected or unplugged; the last complete index stays.
        case volumeGone(String)

        var errorDescription: String? {
            switch self {
            case .needsFullScan: "The index needs a full scan."
            case .volumeGone(let name): "\(name) was disconnected, so the scan stopped. The last complete index is kept."
            }
        }
    }

    /// Bumped whenever the table layout changes; older indexes get rebuilt.
    static let schemaVersion = "2"

    /// More changed folders than this and a full walk is cheaper.
    private static let maxChanges = 25_000

    // MARK: Full scan

    static func fullScan(_ target: IndexTarget = .startup, report: StatusHandler, cancel: CancelFlag) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (target.index as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let building = target.index + ".building"
        // Also a journal left beside it by a scan that crashed or was killed:
        // SQLite would treat it as belonging to the fresh file.
        let removeBuilding = { for suffix in ["", "-journal", "-wal", "-shm"] { try? fm.removeItem(atPath: building + suffix) } }
        removeBuilding()

        // Taken before walking, so changes made during the walk get replayed next update.
        let startEvent = FSEventsGetCurrentEventId()
        let excluded = target.excluded
        do {
            let db = try IndexDB(path: building, mode: .build)
            try db.exec("BEGIN")
            var pending = 0
            let title = target.scanTitle
            try Walker.walk(
                target.root,
                skip: excluded,
                cancelled: { cancel.isSet },
                progress: { report(ScanStatus(title: title, walk: $0)) }
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
            try target.checkStillMounted()
            report(ScanStatus(title: "Saving index"))
            try db.createIndexes()
            try saveCheckpoint(db, target: target, event: startEvent, excluded: excluded)
            try target.checkStillMounted()
        } catch {
            removeBuilding()
            throw error
        }

        for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: target.index + suffix) }
        try fm.moveItem(atPath: building, toPath: target.index)
    }

    // MARK: Incremental update

    /// Rechecks only folders FSEvents reports as changed since the last scan.
    /// Throws `needsFullScan` when there is no usable history.
    ///
    /// Other volumes are only updated this way when their file system keeps
    /// its change log across mounts (APFS, Mac OS Extended) and the log is
    /// still the one the index was saved against; ExFAT and FAT drives start
    /// a new log every time they're plugged in, so they're rescanned.
    static func update(_ target: IndexTarget = .startup, report: StatusHandler, cancel: CancelFlag) throws {
        guard FileManager.default.fileExists(atPath: target.index) else { throw Failure.needsFullScan }
        if let volume = target.volume, !volume.isJournaled { throw Failure.needsFullScan }
        let db = try IndexDB(path: target.index, mode: .write)
        let current = target.eventsUUID
        // Schema first: older layouts fail on the row queries below.
        guard try db.meta("schema") == schemaVersion,
              try db.root() != nil,
              let since = try db.meta("eventId").flatMap(UInt64.init),
              try db.meta("volume") == current,
              target.isStartup || current != nil
        else { throw Failure.needsFullScan }
        if !target.isStartup { try adopt(db, target: target) }

        report(ScanStatus(title: "Reading change log"))
        let now = FSEventsGetCurrentEventId()
        let log = target.isStartup
            ? ChangeLog.changes(under: target.root, since: since)
            : ChangeLog.changes(onDevice: target.device, root: target.root, since: since)
        guard let changes = log, changes.count <= maxChanges else { throw Failure.needsFullScan }

        let excluded = target.excluded
        let (deep, shallow) = plan(changes, target: target, excluding: excluded)
        if deep.contains(target.root) { throw Failure.needsFullScan }

        // Folders excluded or included since the index was saved: re-listing
        // each one's parent drops newly excluded folders and walks newly
        // included ones, so sizes match the list without a full scan.
        let before = Exclusions(fingerprint: try db.meta("excluded") ?? "")
        let toggled = before.paths.symmetricDifference(excluded.paths).compactMap { parent(of: $0, root: target.root) }

        let updater = Updater(db: db, device: target.device, excluded: excluded, cancel: cancel)
        let work = toggled.map { ($0, false) } + deep.map { ($0, true) } + shallow.map { ($0, false) }
        let total = work.count
        try db.transaction {
            for (i, path) in work.enumerated() {
                if cancel.isSet { throw CancellationError() }
                report(ScanStatus(title: "Updating \(i + 1) of \(total) changed folders",
                                  walk: WalkProgress(path: target.display(path.0))))
                try updater.refresh(path.0, deep: path.1)
            }
            try target.checkStillMounted()
            try saveCheckpoint(db, target: target, event: now, excluded: excluded)
        }
    }

    /// A volume that came back under another name ("/Volumes/Drive 1")
    /// keeps its index: only the root row's name, which every lookup
    /// starts from, changes.
    static func adopt(_ db: IndexDB, target: IndexTarget) throws {
        guard let root = try db.root(), root.name != target.root else { return }
        try db.setName(root.id, target.root)
        try db.setMeta("mountPath", target.root)
    }

    /// Opens a volume's index to `adopt` it; for the app, before reading.
    static func adopt(_ target: IndexTarget) {
        guard !target.isStartup, FileManager.default.fileExists(atPath: target.index),
              let db = try? IndexDB(path: target.index, mode: .write) else { return }
        try? adopt(db, target: target)
    }

    /// Normalises event paths and drops ones already covered by a deep
    /// rescan or inside an excluded folder.
    private static func plan(
        _ changes: [ChangeLog.Change], target: IndexTarget, excluding excluded: Exclusions
    ) -> (deep: [String], shallow: [String]) {
        var deep = Set<String>()
        var shallow = Set<String>()
        for change in changes {
            var path = change.path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            path = target.onVolume(path)
            guard path == target.root || path.hasPrefix(target.root + "/") else { continue }
            if !excluded.isEmpty, excluded.covers(path) { continue }
            if change.recursive { deep.insert(path) } else { shallow.insert(path) }
        }

        func covered(_ path: String, by set: Set<String>, includingSelf: Bool) -> Bool {
            var current = path
            if !includingSelf { current = parent(of: current, root: target.root) ?? "" }
            while !current.isEmpty {
                if set.contains(current) { return true }
                current = parent(of: current, root: target.root) ?? ""
            }
            return false
        }

        let keptDeep = deep.filter { !covered($0, by: deep, includingSelf: false) }
        let keptShallow = shallow.filter { !covered($0, by: keptDeep, includingSelf: true) }
        return (keptDeep.sorted(), keptShallow.sorted())
    }

    private static func parent(of path: String, root: String) -> String? {
        guard path.count > root.count, let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<slash])
    }

    // MARK: Locked folders

    /// Rewalks the given folders as the current user: locked ones after Full
    /// Disk Access was granted, or ones that were just cleaned. Paths that no
    /// longer exist are dropped from their parent.
    static func rescan(
        _ paths: [String], target: IndexTarget = .startup, title: String, report: StatusHandler, cancel: CancelFlag
    ) throws {
        let db = try IndexDB(path: target.index, mode: .write)
        // Sticks to the exclusions the index was built with; update() applies changes.
        let excluded = Exclusions(fingerprint: try db.meta("excluded") ?? "")
        let updater = Updater(db: db, device: target.device, excluded: excluded, cancel: cancel)
        try db.transaction {
            for (i, path) in paths.enumerated() {
                if cancel.isSet { throw CancellationError() }
                report(ScanStatus(title: "\(title) \(i + 1) of \(paths.count)",
                                  walk: WalkProgress(path: target.display(path))))
                try updater.refresh(path, deep: true)
            }
            try target.checkStillMounted()
        }
    }

    /// Remeasures display paths after a cleanup or Put Back, each in the
    /// index of the volume it's on: the startup disk's, or one of `volumes`
    /// that has been scanned. Paths on other volumes are skipped.
    static func remeasure(_ displayPaths: [String], volumes: [MountedVolume], report: StatusHandler) {
        var startup: [String] = []
        var byVolume: [String: (MountedVolume, [String])] = [:]
        for path in Set(displayPaths) {
            if let volume = volumes.filter({ path == $0.path || path.hasPrefix($0.path + "/") })
                .max(by: { $0.path.count < $1.path.count }) {
                byVolume[volume.uuid, default: (volume, [])].1.append(path)
            } else if !path.hasPrefix("/Volumes/") {
                startup.append(Paths.onVolume(path))
            }
        }
        if !startup.isEmpty {
            try? rescan(startup.sorted(), title: "Measuring", report: report, cancel: CancelFlag())
        }
        for (volume, paths) in byVolume.values {
            guard let target = IndexTarget.volume(volume), FileManager.default.fileExists(atPath: target.index) else { continue }
            try? rescan(paths.sorted(), target: target, title: "Measuring", report: report, cancel: CancelFlag())
        }
    }

    /// Merges subtrees measured by the privileged helper into the index.
    static func graft(_ results: [AdminResult]) throws {
        let db = try IndexDB(path: Paths.index, mode: .write)
        let excluded = Exclusions(fingerprint: try db.meta("excluded") ?? "")
        let updater = Updater(db: db, device: Volume.device, excluded: excluded, cancel: CancelFlag())
        try db.transaction {
            for result in results { try updater.graft(result) }
        }
    }

    private static func saveCheckpoint(
        _ db: IndexDB, target: IndexTarget, event: FSEventStreamEventId, excluded: Exclusions
    ) throws {
        try db.setMeta("excluded", excluded.fingerprint)
        try db.setMeta("eventId", String(event))
        try db.setMeta("volume", target.eventsUUID ?? "")
        try db.setMeta("scannedAt", String(Date.now.timeIntervalSince1970))
        try db.setMeta("schema", schemaVersion)
        // What the volume list shows while the drive is unplugged.
        if let volume = target.volume {
            try db.setMeta("mountPath", volume.path)
            try db.setMeta("volumeName", volume.name)
            try db.setMeta("format", volume.format)
            try db.setMeta("journaled", volume.isJournaled ? "1" : "0")
            try db.setMeta("removable", volume.isRemovable ? "1" : "0")
            try db.setMeta("totalBytes", String(volume.total))
        }
    }
}

/// Applies changes to single folders while keeping every ancestor's totals right.
private struct Updater {
    let db: IndexDB
    let device: dev_t
    /// Folders left out of the index, matched on volume paths.
    let excluded: Exclusions
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
            try Walker.walk(target.path, skip: excluded, cancelled: { cancel.isSet }, emit: emit)
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
        if lstat(target.path, &dirStat) == 0 {
            newest = Walker.plausible(Int64(dirStat.st_mtimespec.tv_sec))
            own = Int64(dirStat.st_blocks) * 512  // the folder's own entries, as in Walker
        }
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            guard lstat(target.path + "/" + name, &st) == 0 else { continue }
            if st.st_mode & S_IFMT == S_IFDIR {
                if Walker.descends(into: st.st_dev, from: device), !excluded.contains(target.path + "/" + name) {
                    subdirs.insert(name)
                }
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
                try Walker.walk(target.path + "/" + name, skip: excluded, cancelled: { cancel.isSet }, emit: emit)
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
