import CoreServices
import Darwin
import Foundation
import os

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


/// Why an update had to give way to a full scan; logged, and carried by
/// `ScanEngine.Failure.needsFullScan`.
enum FullScanReason: String, Sendable, CustomStringConvertible {
    case noIndex = "there is no index yet"
    case notJournaled = "the drive keeps no change history"
    case outdatedSchema = "the index was saved by an older version"
    case noRoot = "the index is empty"
    case noCheckpoint = "the index has no change-log position"
    case historyReset = "the volume's change history was reset"
    case noHistory = "the volume has no change history"
    case historyLost = "the change log dropped events"
    case replayTimedOut = "the change log took too long to read"
    case replayUnavailable = "the change log couldn't be opened"
    case tooManyChanges = "too many folders changed"

    var description: String { rawValue }
}

/// Builds and maintains the index. Everything here is synchronous and meant
/// to run off the main thread.
enum ScanEngine {
    enum Failure: LocalizedError, Equatable {
        /// `catch ScanEngine.Failure.needsFullScan` still matches any reason.
        case needsFullScan(FullScanReason)
        /// The drive was ejected or unplugged; the last complete index stays.
        case volumeGone(String)
        /// Another Ballast process (the app, `--index`, the auto-clean agent)
        /// is writing this index.
        case busy

        var errorDescription: String? {
            switch self {
            case .needsFullScan(let reason): "The index needs a full scan: \(reason)."
            case .volumeGone(let name): "\(name) was disconnected, so the scan stopped. The last complete index is kept."
            case .busy: "Another Ballast scan is updating the index. Try again when it has finished."
            }
        }
    }

    static let log = Logger(subsystem: "dev.mamad.Ballast", category: "scan")

    /// Bumped whenever the table layout changes; older indexes get rebuilt,
    /// except those in `compatibleSchemas`.
    static let schemaVersion = "3"

    /// Layouts an update can bring up to date without a full scan. Version 2
    /// has no large-files table: opening it for writing adds one, empty, and
    /// the list shows once a full scan has filled it (`largeFilesKey`).
    static let compatibleSchemas: Set<String> = ["2", schemaVersion]

    /// Set by a full scan to the threshold its large-file list used. Updates
    /// keep the list current but can't fill in folders that didn't change,
    /// so only a full scan sets it.
    static let largeFilesKey = "largeFiles"

    /// More distinct changed folders than this (after nested ones collapse
    /// into the folders above them) and a full walk is cheaper.
    static let maxChanges = 60_000

    /// Where the change-log replay stops counting. Above `maxChanges`,
    /// because folders inside one rechecked recursively still collapse
    /// after the replay.
    static var replayLimit: Int { maxChanges * 2 }

    /// How often progress reaches the app during an update or rescan; each
    /// report is a hop to the main actor.
    static let reportInterval: UInt64 = 150

    // MARK: Lock

    /// An exclusive `flock` on `index.lock` beside an index, held by
    /// whichever process (the app, `--index`, the auto-clean agent) is
    /// writing it. Released when the process exits, however it exits.
    final class IndexLock {
        private var fd: Int32

        private init(fd: Int32) { self.fd = fd }

        static func path(for index: String) -> String {
            (index as NSString).deletingLastPathComponent + "/index.lock"
        }

        /// Without `wait`, throws `Failure.busy` straight away when another
        /// process holds it; otherwise waits, cancellably, up to `timeout`.
        static func acquire(
            index: String, wait: Bool, timeout: TimeInterval = 30 * 60,
            cancel: CancelFlag, report: StatusHandler
        ) throws -> IndexLock {
            let path = path(for: index)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw IndexError(message: "can't open \(path): \(String(cString: strerror(errno)))") }
            let deadline = Date.now.addingTimeInterval(timeout)
            var announced = false
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let err = errno
                if err == EINTR { continue }
                guard err == EWOULDBLOCK else {
                    close(fd)
                    throw IndexError(message: "can't lock \(path): \(String(cString: strerror(err)))")
                }
                guard wait, Date.now < deadline else {
                    close(fd)
                    log.notice("Index \(index, privacy: .public) is locked by another process")
                    throw Failure.busy
                }
                if cancel.isSet {
                    close(fd)
                    throw CancellationError()
                }
                if !announced {
                    report(ScanStatus(title: "Waiting for another Ballast scan to finish"))
                    announced = true
                }
                usleep(200_000)
            }
            return IndexLock(fd: fd)
        }

        func release() {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }

        deinit { release() }
    }

    // MARK: Full scan

    /// Returns how many folders it measured. Builds a new file beside the
    /// index and swaps it in only once it's complete and on disk, so the
    /// index is never missing, half-written or mixed with another build.
    @discardableResult
    static func fullScan(
        _ target: IndexTarget = .startup, report: StatusHandler, cancel: CancelFlag, waitForLock: Bool = true
    ) throws -> Int {
        let lock = try IndexLock.acquire(index: target.index, wait: waitForLock, cancel: cancel, report: report)
        defer { lock.release() }
        // Under the lock no other build is running: whatever is left was
        // abandoned by a scan that crashed or was killed.
        removeAbandonedBuilds(of: target.index)
        let building = target.index + ".building-\(getpid())-\(UUID().uuidString)"
        // Also a journal beside it: SQLite would treat it as the file's own.
        let removeBuilding = { for suffix in ["", "-journal", "-wal", "-shm"] { unlink(building + suffix) } }

        // Taken before walking, so changes made during the walk get replayed next update.
        let startEvent = FSEventsGetCurrentEventId()
        let excluded = target.excluded
        var folders = 0
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
                try db.upsert(id: node.local + 1, parent: node.parent < 0 ? nil : node.parent + 1, name: node.name,
                              node: node, fresh: true)
                folders += 1
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
            try db.setMeta(largeFilesKey, String(LargeFiles.threshold))
            try target.checkStillMounted()
            db.close()
            // Written without a journal: on disk before it replaces anything.
            try syncToDisk(building)
            try publish(building, as: target.index)
        } catch {
            removeBuilding()
            throw error
        }
        return folders
    }

    /// `index.sqlite.building…` files beside `index`.
    private static func removeAbandonedBuilds(of index: String) {
        let directory = (index as NSString).deletingLastPathComponent
        let prefix = (index as NSString).lastPathComponent + ".building"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where name.hasPrefix(prefix) {
            unlink(directory + "/" + name)
        }
    }

    private static func syncToDisk(_ path: String) throws {
        let fd = open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw IndexError(message: "can't open \(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        // F_FULLFSYNC reaches the drive's own cache; fsync is the fallback
        // for file systems that don't support it.
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            throw IndexError(message: "can't save \(path): \(String(cString: strerror(errno)))")
        }
    }

    /// Replaces `index` with `building` in one atomic rename: readers see
    /// the old file or the new one, never neither. Connections still open
    /// on the old file keep reading it until they reopen.
    static func publish(_ building: String, as index: String) throws {
        guard rename(building, index) == 0 else {
            throw IndexError(message: "can't save the index: \(String(cString: strerror(errno)))")
        }
        // The old file's log and shared-memory files aren't the new one's:
        // SQLite would replay a leftover -wal into it. The new file is in
        // rollback mode, and no writer can recreate them under the lock.
        for suffix in ["-wal", "-shm", "-journal"] { unlink(index + suffix) }
        let directory = open((index as NSString).deletingLastPathComponent, O_RDONLY | O_CLOEXEC)
        if directory >= 0 {
            fsync(directory)
            close(directory)
        }
    }

    // MARK: Incremental update

    /// What an update asks the change log for.
    struct ReplayRequest {
        let target: IndexTarget
        let since: FSEventStreamEventId
        /// Filters events to the target's root and exclusions, and merges repeats.
        let accumulator: ChangeLog.Accumulator
    }

    /// Reads the volume's FSEvents history; tests pass their own.
    /// `progress` gets the raw events read so far.
    static func replayLog(_ request: ReplayRequest, progress: (Int) -> Void) -> ChangeLog.Outcome {
        let target = request.target
        return target.isStartup
            ? ChangeLog.replay(under: target.root, since: request.since, accumulator: request.accumulator,
                               progress: progress)
            : ChangeLog.replay(onDevice: target.device, root: target.root, since: request.since,
                               accumulator: request.accumulator, progress: progress)
    }

    /// Rechecks only folders FSEvents reports as changed since the last scan.
    /// Throws `needsFullScan` when there is no usable history. Returns how
    /// many folders it rechecked.
    ///
    /// Other volumes are only updated this way when their file system keeps
    /// its change log across mounts (APFS, Mac OS Extended) and the log is
    /// still the one the index was saved against; ExFAT and FAT drives start
    /// a new log every time they're plugged in, so they're rescanned.
    @discardableResult
    static func update(
        _ target: IndexTarget = .startup, report: StatusHandler, cancel: CancelFlag, waitForLock: Bool = true
    ) throws -> Int {
        try update(target, report: report, cancel: cancel, waitForLock: waitForLock, changes: replayLog)
    }

    /// `update` with the change log supplied by the caller.
    @discardableResult
    static func update(
        _ target: IndexTarget, report: StatusHandler, cancel: CancelFlag, waitForLock: Bool = true,
        changes source: (ReplayRequest, (Int) -> Void) -> ChangeLog.Outcome
    ) throws -> Int {
        guard FileManager.default.fileExists(atPath: target.index) else { throw fullScanNeeded(.noIndex, target) }
        if let volume = target.volume, !volume.isJournaled { throw fullScanNeeded(.notJournaled, target) }
        let lock = try IndexLock.acquire(index: target.index, wait: waitForLock, cancel: cancel, report: report)
        defer { lock.release() }
        let throttle = Throttle(milliseconds: reportInterval)
        func send(_ status: ScanStatus) { if throttle.ready() { report(status) } }

        let db = try IndexDB(path: target.index, mode: .write)
        let current = target.eventsUUID
        // Schema first: older layouts fail on the row queries below.
        guard let schema = try db.meta("schema"), compatibleSchemas.contains(schema) else {
            throw fullScanNeeded(.outdatedSchema, target)
        }
        guard try db.root() != nil else { throw fullScanNeeded(.noRoot, target) }
        guard let since = try db.meta("eventId").flatMap(UInt64.init) else { throw fullScanNeeded(.noCheckpoint, target) }
        guard target.isStartup || current != nil else { throw fullScanNeeded(.noHistory, target) }
        // Saved as "" when the volume had no events UUID.
        guard try db.meta("volume") == (current ?? "") else { throw fullScanNeeded(.historyReset, target) }
        if !target.isStartup { try adopt(db, target: target) }

        send(ScanStatus(title: "Reading change log"))
        let now = FSEventsGetCurrentEventId()
        let excluded = target.excluded
        let request = ReplayRequest(
            target: target, since: since,
            accumulator: ChangeLog.Accumulator(limit: replayLimit, normalize: eventFilter(target, excluding: excluded)))
        // The replay is synchronous: `report` doesn't outlive this call.
        let outcome = withoutActuallyEscaping(report) { report in
            source(request) { events in
                if throttle.ready() { report(ScanStatus(title: "Reading change log (\(events.formatted()) events)")) }
            }
        }
        let changes: [ChangeLog.Change]
        switch outcome {
        case .changes(let found): changes = found
        case .tooMany: throw fullScanNeeded(.tooManyChanges, target)
        case .historyLost: throw fullScanNeeded(.historyLost, target)
        case .timedOut: throw fullScanNeeded(.replayTimedOut, target)
        case .unavailable: throw fullScanNeeded(.replayUnavailable, target)
        }

        var (deep, shallow) = plan(changes, target: target, excluding: excluded)
        if deep.contains(target.root) {
            // FSEvents lost track somewhere below the root without saying
            // where. Every top-level folder is rechecked in place instead
            // of rebuilding: the index stays usable and the work can be
            // cancelled, though on a whole disk it walks just as much.
            deep = topLevelFolders(target, excluding: excluded)
            shallow = [target.root]
            log.notice("Change log asks for a rescan of \(target.root, privacy: .public); rechecking \(deep.count) top-level folders")
        }
        guard deep.count + shallow.count <= maxChanges else { throw fullScanNeeded(.tooManyChanges, target) }

        // Folders excluded or included since the index was saved: re-listing
        // each one's parent drops newly excluded folders and walks newly
        // included ones, so sizes match the list without a full scan.
        let before = Exclusions(fingerprint: try db.meta("excluded") ?? "")
        let toggled = before.paths.symmetricDifference(excluded.paths).compactMap { parent(of: $0, root: target.root) }

        let updater = Updater(db: db, device: target.device, excluded: excluded, cancel: cancel)
        // Deep first: a folder measured once isn't measured again (see
        // `Updater.refresh`), so a rewalk must not come after a re-listing.
        let work = deep.map { ($0, true) } + toggled.map { ($0, false) } + shallow.map { ($0, false) }
        let total = work.count
        try db.transaction {
            for (i, item) in work.enumerated() {
                if cancel.isSet { throw CancellationError() }
                let title = "Updating \(i + 1) of \(total) changed folders"
                send(ScanStatus(title: title, walk: WalkProgress(path: target.display(item.0))))
                try updater.refresh(item.0, deep: item.1) { walk in
                    var walk = walk
                    walk.path = target.display(walk.path)
                    send(ScanStatus(title: title, walk: walk))
                }
            }
            try target.checkStillMounted()
            try saveCheckpoint(db, target: target, event: now, excluded: excluded)
        }
        return total
    }

    private static func fullScanNeeded(_ reason: FullScanReason, _ target: IndexTarget) -> Failure {
        log.notice("Full scan needed for \(target.root, privacy: .public): \(reason.description, privacy: .public)")
        return .needsFullScan(reason)
    }

    /// Raw event path → volume path of a folder inside the target and not
    /// excluded, or nil.
    static func eventFilter(_ target: IndexTarget, excluding excluded: Exclusions) -> @Sendable (String) -> String? {
        let root = target.root
        let prefix = root + "/"
        return { raw in
            let path = target.onVolume(ChangeLog.trimmed(raw))
            guard path == root || path.hasPrefix(prefix) else { return nil }
            if !excluded.isEmpty, excluded.covers(path) { return nil }
            return path
        }
    }

    /// The root's folders on its own volume, excluded ones left out.
    private static func topLevelFolders(_ target: IndexTarget, excluding excluded: Exclusions) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: target.root)) ?? []
        return names.map { target.root + "/" + $0 }.filter { path in
            var st = stat()
            return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
                && Walker.descends(into: st.st_dev, from: target.device) && !excluded.contains(path)
        }.sorted()
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
    /// Reads first and writes only when the name changed; skipped while
    /// another process holds the index.
    static func adopt(_ target: IndexTarget) {
        guard !target.isStartup, FileManager.default.fileExists(atPath: target.index) else { return }
        do {
            let reader = try IndexDB(path: target.index, mode: .read)
            guard let root = try reader.root(), root.name != target.root else { return }
            reader.close()
            let lock = try IndexLock.acquire(index: target.index, wait: false, cancel: CancelFlag(), report: { _ in })
            defer { lock.release() }
            try adopt(IndexDB(path: target.index, mode: .write), target: target)
        } catch {
            log.error("Couldn't adopt \(target.root, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Normalises event paths and drops ones already covered by a deep
    /// rescan or inside an excluded folder.
    static func plan(
        _ changes: [ChangeLog.Change], target: IndexTarget, excluding excluded: Exclusions
    ) -> (deep: [String], shallow: [String]) {
        let filter = eventFilter(target, excluding: excluded)
        var deep = Set<String>()
        var shallow = Set<String>()
        for change in changes {
            guard let path = filter(change.path) else { continue }
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
        _ paths: [String], target: IndexTarget = .startup, title: String, report: StatusHandler, cancel: CancelFlag,
        waitForLock: Bool = true
    ) throws {
        let lock = try IndexLock.acquire(index: target.index, wait: waitForLock, cancel: cancel, report: report)
        defer { lock.release() }
        let throttle = Throttle(milliseconds: reportInterval)
        func send(_ status: ScanStatus) { if throttle.ready() { report(status) } }
        let db = try IndexDB(path: target.index, mode: .write)
        // Sticks to the exclusions the index was built with; update() applies changes.
        let excluded = Exclusions(fingerprint: try db.meta("excluded") ?? "")
        let updater = Updater(db: db, device: target.device, excluded: excluded, cancel: cancel)
        try db.transaction {
            for (i, path) in paths.enumerated() {
                if cancel.isSet { throw CancellationError() }
                let step = "\(title) \(i + 1) of \(paths.count)"
                send(ScanStatus(title: step, walk: WalkProgress(path: target.display(path))))
                try updater.refresh(path, deep: true) { walk in
                    var walk = walk
                    walk.path = target.display(walk.path)
                    send(ScanStatus(title: step, walk: walk))
                }
            }
            try target.checkStillMounted()
        }
    }

    /// Remeasures display paths after a cleanup or Put Back, each in the
    /// index of the volume it's on: the startup disk's, or one of `volumes`
    /// that has been scanned. Paths on other volumes are skipped. Returns
    /// what went wrong, one error per index that couldn't be remeasured,
    /// so the caller can tell the index is behind.
    @discardableResult
    static func remeasure(_ displayPaths: [String], volumes: [MountedVolume], report: StatusHandler) -> [any Error] {
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
        var errors: [any Error] = []
        func attempt(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
            } catch {
                log.error("Remeasuring \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                errors.append(error)
            }
        }
        if !startup.isEmpty {
            attempt("the startup disk") {
                try rescan(startup.sorted(), title: "Measuring", report: report, cancel: CancelFlag())
            }
        }
        for (volume, paths) in byVolume.values {
            guard let target = IndexTarget.volume(volume), FileManager.default.fileExists(atPath: target.index) else { continue }
            attempt(volume.name) {
                try rescan(paths.sorted(), target: target, title: "Measuring", report: report, cancel: CancelFlag())
            }
        }
        return errors
    }

    /// Merges subtrees measured by the privileged helper into the index.
    static func graft(_ results: [AdminResult], waitForLock: Bool = true) throws {
        let lock = try IndexLock.acquire(index: Paths.index, wait: waitForLock, cancel: CancelFlag(), report: { _ in })
        defer { lock.release() }
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
    /// Hard-linked files counted so far in this transaction, so a file
    /// with several names is counted once, as a full scan counts it.
    let hardLinks = HardLinks()
    /// Folders already measured in this transaction. Measuring one again
    /// would find nothing new, and would skip its hard-linked files as
    /// already counted.
    let measured = Measured()

    final class Measured {
        private var paths = Set<String>()

        /// True the first time a folder is seen.
        func insert(_ path: String) -> Bool { paths.insert(path).inserted }
    }

    /// `deep` rewalks the whole subtree; otherwise only direct children are
    /// re-listed and unchanged subfolders keep their stored totals.
    func refresh(_ path: String, deep: Bool, progress: (WalkProgress) -> Void = { _ in }) throws {
        // The deepest indexed folder on this path that still exists: new
        // folders are picked up by their parent, deleted ones vanish from it.
        let known = try db.locate(path)
        guard let target = known.last(where: { isDirectory($0.path) }), measured.insert(target.path) else { return }
        if deep && target.path == path {
            try replace(target, progress: progress)
        } else {
            try Walker.leavingDatalessFilesInCloud { try relist(target, progress: progress) }
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

    private func replace(_ target: Located, progress: (WalkProgress) -> Void) throws {
        try db.deleteDescendants(of: target.row.id)
        let root = try store(rootID: target.row.id, parent: target.row.parent, name: target.row.name) { emit in
            try Walker.walk(target.path, skip: excluded, cancelled: { cancel.isSet }, progress: progress,
                            hardLinks: hardLinks, emit: emit)
        }
        try db.propagate(from: target.row.parent, bytes: root.total - target.row.total, files: root.files - target.row.files, newest: root.newest)
    }

    private func relist(_ target: Located, progress: (WalkProgress) -> Void) throws {
        let row = target.row
        let dir = opendir(target.path)
        // A dataless folder (iCloud Drive, File Provider) isn't listed
        // without downloading it; nothing of it is on this disk.
        if dir == nil, errno != EDEADLK {
            try db.setError(row.id, errno)  // keep the old sizes, mark as locked
            return
        }
        defer { if let dir { closedir(dir) } }

        var own: Int64 = 0
        var ownFiles: Int64 = 0
        var newest: Int64 = 0
        var subdirs = Set<String>()
        var large: [WalkFile] = []
        var dirStat = stat()
        if lstat(target.path, &dirStat) == 0 {
            newest = Walker.plausible(Int64(dirStat.st_mtimespec.tv_sec))
            own = Int64(dirStat.st_blocks) * 512  // the folder's own entries, as in Walker
        }
        while let dir, let entry = readdir(dir) {
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
                let isFile = st.st_mode & S_IFMT == S_IFREG
                // Count each hard-linked file once, like the full walk.
                if isFile, st.st_nlink > 1, !hardLinks.insert(st.st_ino) { continue }
                own += Int64(st.st_blocks) * 512
                ownFiles += 1
                if isFile, Int64(st.st_blocks) * 512 >= LargeFiles.threshold {
                    large.append(WalkFile(name: name, stat: st))
                }
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
        for name in subdirs.sorted() {
            if cancel.isSet { throw CancellationError() }
            let node = try store(rootID: nil, parent: row.id, name: name) { emit in
                try Walker.walk(target.path + "/" + name, skip: excluded, cancelled: { cancel.isSet }, progress: progress,
                                hardLinks: hardLinks, emit: emit)
            }
            total += node.total
            files += node.files
            newest = max(newest, node.newest)
        }

        try db.replaceFiles(in: row.id, with: large)
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
