import CoreServices
import Darwin
import Foundation
import Testing
import os
@testable import Ballast

/// A temp folder indexed as if it were a volume, as in VolumeScanTests: it
/// keeps the real data volume's identity, so the still-mounted check and
/// the change-log checkpoint both hold.
private struct Drive {
    let base: URL
    let root: URL
    let index: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "ballast-engine-\(UUID().uuidString)")
        root = base.appending(path: "Drive")
        index = base.appending(path: "index/index.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    var target: IndexTarget {
        get throws {
            var st = stat()
            lstat(root.path, &st)
            let uuid = try #require(try root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
            let volume = MountedVolume(uuid: uuid, name: "Test", path: root.path, format: "APFS", isReadOnly: false,
                                       isJournaled: true, isRemovable: true, total: 0, free: 0, device: st.st_dev)
            return IndexTarget(index: index.path, root: root.path, device: st.st_dev, volume: volume)
        }
    }

    func path(_ relative: String) -> String { root.path + "/" + relative }

    func write(_ relative: String, bytes: Int) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    func link(_ existing: String, as new: String) throws {
        try FileManager.default.linkItem(atPath: path(existing), toPath: path(new))
    }

    func rootRow() throws -> DirRow {
        try #require(try IndexDB(path: index.path, mode: .read).root())
    }

    func row(_ relative: String) throws -> DirRow {
        let found = try #require(try IndexDB(path: index.path, mode: .read).locate(path(relative)).last)
        #expect(found.path == path(relative))
        return found.row
    }

    /// What a full scan of the drive as it is now says, without touching `index`.
    func freshTotals() throws -> (total: Int64, files: Int64) {
        let copy = Drive(base: base, root: root, index: base.appending(path: "fresh-\(UUID().uuidString)/index.sqlite"))
        try ScanEngine.fullScan(try copy.target, report: { _ in }, cancel: CancelFlag())
        let top = try copy.rootRow()
        return (top.total, top.files)
    }

    private init(base: URL, root: URL, index: URL) {
        self.base = base
        self.root = root
        self.index = index
    }
}

/// A change log that replays `events` (raw path, recursive) through the
/// update's own filter, the way the FSEvents callback does.
private func replaying(_ events: [(String, Bool)]) -> (ScanEngine.ReplayRequest, (Int) -> Void) -> ChangeLog.Outcome {
    { request, progress in
        var accumulator = request.accumulator
        for (path, recursive) in events {
            accumulator.add(path, recursive: recursive)
            if accumulator.isFull { return .tooMany(accumulator.folders.count) }
        }
        progress(accumulator.events)
        return .changes(accumulator.changes)
    }
}

@Suite struct ChangeLogAccumulatorTests {
    @Test func repeatsOfAFolderCountOnceAndOneRecursiveEventWins() {
        var accumulator = ChangeLog.Accumulator()  // trims trailing slashes by default
        for i in 0..<30_000 { accumulator.add("/d/f\(i % 10)/", recursive: false) }
        accumulator.add("/d/f3/", recursive: true)
        accumulator.add("/d/f3", recursive: false)  // doesn't undo the recursive one
        #expect(accumulator.events == 30_002)
        #expect(accumulator.folders.count == 10)
        #expect(accumulator.changes.filter(\.recursive).map(\.path) == ["/d/f3"])
        #expect(!accumulator.isFull)
    }

    @Test func dropsWhatTheFilterRejectsAndWhatARecursiveFolderCovers() {
        let filter: @Sendable (String) -> String? = { raw in
            let path = ChangeLog.trimmed(raw)
            return path.hasPrefix("/root/") && !path.hasPrefix("/root/skip") ? path : nil
        }
        var accumulator = ChangeLog.Accumulator(limit: 2, normalize: filter)
        accumulator.add("/elsewhere/a/", recursive: false)
        accumulator.add("/root/skip/x/", recursive: false)
        accumulator.add("/root/a/", recursive: true)
        accumulator.add("/root/a/b/c/", recursive: false)  // inside /root/a
        accumulator.add("/root/ab/", recursive: false)     // a sibling, not inside
        #expect(accumulator.changes == [.init(path: "/root/a", recursive: true), .init(path: "/root/ab", recursive: false)])
        #expect(!accumulator.isFull)
        accumulator.add("/root/c/", recursive: false)
        #expect(accumulator.isFull)
    }
}

@Suite struct IncrementalUpdateTests {
    @Test func manyRepeatedEventsAreAnUpdateNotAFullScan() throws {
        let drive = try Drive()
        defer { drive.remove() }
        for i in 0..<40 { try drive.write("projects/p\(i)/build/out.o", bytes: 20_000) }
        let target = try drive.target
        try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag())

        for i in 0..<40 where i % 2 == 0 { try drive.write("projects/p\(i)/build/more.o", bytes: 50_000) }
        try FileManager.default.removeItem(atPath: drive.path("projects/p1"))
        // Far more raw events than the old 25,000 cap, naming 40 folders
        // plus noise from elsewhere: what a busy hour of builds looks like.
        var events: [(String, Bool)] = []
        for round in 0..<2_500 {
            for i in 0..<40 { events.append((drive.path("projects/p\(i)/build") + "/", false)) }
            events.append(("/private/var/elsewhere/\(round % 7)/", false))
        }
        events.append((drive.path("projects") + "/", false))
        #expect(events.count > 100_000)

        let titles = OSAllocatedUnfairLock(initialState: [String]())
        let checked = try ScanEngine.update(target, report: { status in titles.withLock { $0.append(status.title) } }, cancel: CancelFlag(),
                                            changes: replaying(events))
        #expect(checked == 41)
        // Throttled: nowhere near one report per folder.
        #expect(titles.withLock { $0.count } < checked)

        let fresh = try drive.freshTotals()
        let top = try drive.rootRow()
        #expect(top.total == fresh.total)
        #expect(top.files == fresh.files)
        #expect(try IndexDB(path: drive.index.path, mode: .read).locate(drive.path("projects/p1")).last?.path
                == drive.path("projects"))
    }

    @Test func tooManyDistinctFoldersStillAsksForAFullScan() throws {
        let drive = try Drive()
        defer { drive.remove() }
        try drive.write("a/one.bin", bytes: 10_000)
        let target = try drive.target
        try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag())

        let events = (0...ScanEngine.replayLimit).map { (drive.path("a/\($0)"), false) }
        #expect(throws: ScanEngine.Failure.needsFullScan(.tooManyChanges)) {
            try ScanEngine.update(target, report: { _ in }, cancel: CancelFlag(), changes: replaying(events))
        }
        // The old call sites' pattern still matches whatever the reason.
        do {
            try ScanEngine.update(target, report: { _ in }, cancel: CancelFlag(), changes: { _, _ in .historyLost })
            Issue.record("expected needsFullScan")
        } catch ScanEngine.Failure.needsFullScan {
        }
    }

    @Test func aRecursiveEventAtTheRootRechecksTopLevelFoldersInPlace() throws {
        let drive = try Drive()
        defer { drive.remove() }
        try drive.write("a/one.bin", bytes: 30_000)
        try drive.write("b/c/two.bin", bytes: 30_000)
        let target = try drive.target
        try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag())

        try drive.write("b/c/three.bin", bytes: 80_000)
        try drive.write("new/four.bin", bytes: 10_000)
        try FileManager.default.removeItem(atPath: drive.path("a"))

        let checked = try ScanEngine.update(target, report: { _ in }, cancel: CancelFlag(),
                                            changes: replaying([(drive.root.path + "/", true)]))
        #expect(checked == 3)  // b and new deeply, then the root itself
        let fresh = try drive.freshTotals()
        #expect(try drive.rootRow().total == fresh.total)
        #expect(try drive.rootRow().files == fresh.files)
        #expect(try drive.row("new").files == 1)
    }

    @Test func shallowUpdatesCountHardLinksOnceLikeAFullScan() throws {
        let drive = try Drive()
        defer { drive.remove() }
        try drive.write("a/keep.bin", bytes: 10_000)
        let target = try drive.target
        try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag())

        // Three names for one file, in the folder being re-listed.
        try drive.write("a/data.bin", bytes: 200_000)
        try drive.link("a/data.bin", as: "a/data-1.bin")
        try drive.link("a/data.bin", as: "a/data-2.bin")
        // A path that's gone: its parent `a` is re-listed, not rewalked.
        try ScanEngine.rescan([drive.path("a/gone")], target: target, title: "", report: { _ in }, cancel: CancelFlag())

        let relisted = try drive.row("a")
        #expect(relisted.ownFiles == 2)
        let fresh = try drive.freshTotals()
        #expect(try drive.rootRow().total == fresh.total)
        #expect(try drive.rootRow().files == fresh.files)
    }

    @Test func aFolderReachedTwiceInOneUpdateKeepsItsHardLinks() throws {
        let drive = try Drive()
        defer { drive.remove() }
        try drive.write("p/data.bin", bytes: 200_000)
        try drive.link("p/data.bin", as: "p/data-1.bin")
        try drive.link("p/data.bin", as: "p/data-2.bin")
        let target = try drive.target
        try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag())
        let before = try drive.row("p")

        // A new folder (found by re-listing p) and p itself: p is reached twice.
        try drive.write("p/new/x.bin", bytes: 30_000)
        try ScanEngine.update(target, report: { _ in }, cancel: CancelFlag(),
                              changes: replaying([(drive.path("p/new"), true), (drive.path("p"), false)]))

        #expect(try drive.row("p").ownFiles == before.ownFiles)
        let fresh = try drive.freshTotals()
        #expect(try drive.rootRow().total == fresh.total)
        #expect(try drive.rootRow().files == fresh.files)
    }
}

@Suite struct IndexFileTests {
    @Test func aFullScanSwapsTheFileUnderAnOpenReader() throws {
        let drive = try Drive()
        defer { drive.remove() }
        try drive.write("a/one.bin", bytes: 100_000)
        let target = try drive.target
        try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag())
        // Written once through WAL, as an update leaves it.
        try ScanEngine.rescan([drive.path("a")], target: target, title: "", report: { _ in }, cancel: CancelFlag())

        let reader = try IndexDB(path: drive.index.path, mode: .read)
        let before = try #require(try reader.root()).total
        try drive.write("b/two.bin", bytes: 400_000)
        try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag())

        // A connection still open on the replaced file reads it as it was
        // or fails (its log went with it); it never mixes in the new one.
        if let old = try? reader.root() { #expect(old.total == before) }
        // A new one sees the new file, with nothing of the old one's log.
        let fresh = try IndexDB(path: drive.index.path, mode: .read)
        #expect(try #require(try fresh.root()).total >= before + 400_000)
        let names = try FileManager.default.contentsOfDirectory(atPath: drive.index.deletingLastPathComponent().path)
        #expect(!names.contains { $0.contains(".building") })
        #expect(!names.contains("index.sqlite-wal"))
        // And it can still be updated.
        try ScanEngine.rescan([drive.path("b")], target: target, title: "", report: { _ in }, cancel: CancelFlag())
        #expect(try IndexDB(path: drive.index.path, mode: .read).root()?.total == fresh.root()?.total)
    }

    @Test func anotherWriterHoldingTheIndexIsReportedNotRaced() throws {
        let drive = try Drive()
        defer { drive.remove() }
        try drive.write("a/one.bin", bytes: 10_000)
        let target = try drive.target
        try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag())
        let saved = try Data(contentsOf: drive.index)

        let held = try ScanEngine.IndexLock.acquire(index: drive.index.path, wait: false, cancel: CancelFlag(), report: { _ in })
        #expect(throws: ScanEngine.Failure.busy) {
            try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag(), waitForLock: false)
        }
        #expect(throws: ScanEngine.Failure.busy) {
            try ScanEngine.rescan([drive.path("a")], target: target, title: "", report: { _ in }, cancel: CancelFlag(),
                                  waitForLock: false)
        }
        // Waiting gives up when cancelled.
        let cancel = CancelFlag()
        cancel.set()
        #expect(throws: CancellationError.self) {
            try ScanEngine.update(target, report: { _ in }, cancel: cancel, changes: replaying([]))
        }
        #expect(try Data(contentsOf: drive.index) == saved)

        held.release()
        try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag(), waitForLock: false)
    }

    @Test func readersCantWrite() throws {
        let drive = try Drive()
        defer { drive.remove() }
        try drive.write("a/one.bin", bytes: 10_000)
        try ScanEngine.fullScan(try drive.target, report: { _ in }, cancel: CancelFlag())
        let reader = try IndexDB(path: drive.index.path, mode: .read)
        #expect(throws: IndexError.self) { try reader.setMeta("x", "y") }
        // Opening a missing file to read never creates it.
        #expect(throws: IndexError.self) { try IndexDB(path: drive.base.appending(path: "none.sqlite").path, mode: .read) }
        #expect(!FileManager.default.fileExists(atPath: drive.base.appending(path: "none.sqlite").path))
    }

    @Test func nameLookupsUseAnIndexOldIndexesGainToo() throws {
        let drive = try Drive()
        defer { drive.remove() }
        try drive.write("a/node_modules/x.js", bytes: 1_000)
        try ScanEngine.fullScan(try drive.target, report: { _ in }, cancel: CancelFlag())
        func hasNameIndex() throws -> Bool {
            try !IndexDB(path: drive.index.path, mode: .read)
                .query("SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'dirs_name'") { _ in true }.isEmpty
        }
        #expect(try hasNameIndex())
        try IndexDB(path: drive.index.path, mode: .write).exec("DROP INDEX dirs_name")
        #expect(try !hasNameIndex())
        _ = try IndexDB(path: drive.index.path, mode: .write)
        #expect(try hasNameIndex())
        #expect(try IndexDB(path: drive.index.path, mode: .read).rows(named: ["node_modules"]).count == 1)
    }

    @Test func theGrowthStoreGetsNoIndexTables() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "ballast-growth-\(UUID().uuidString).sqlite").path
        defer { GrowthStore.clear(path: path) }
        // What older versions left behind.
        try IndexDB(path: path, mode: .write).exec("SELECT 1")
        #expect(try IndexDB(path: path, mode: .read).tableExists("files"))
        _ = try GrowthStore(path: path)
        let db = try IndexDB(path: path, mode: .read)
        #expect(try !db.tableExists("files"))
        #expect(try db.tableExists("sizes"))
    }
}

@Suite struct AdminScanArgumentTests {
    @Test func skipsAndTheMarkerAreSeparatedFromPaths() {
        let request = AdminScan.Request(arguments: [
            "/System/Volumes/Data/Library/a", "--skip=/System/Volumes/Data/Users/me/VMs", "/b", "--alive=/tmp/x.alive",
        ])
        #expect(request.paths == ["/System/Volumes/Data/Library/a", "/b"])
        #expect(request.excluded.contains("/System/Volumes/Data/Users/me/VMs"))
        #expect(request.alive == "/tmp/x.alive")
        #expect(AdminScan.Request(arguments: ["/only"]).alive == nil)
    }

    @Test func theRootProcessStopsOnceTheMarkerIsGone() throws {
        let drive = try Drive()
        defer { drive.remove() }
        try drive.write("a/one.bin", bytes: 10_000)
        try drive.write("skip/two.bin", bytes: 10_000)
        let output = drive.base.appending(path: "out.plist").path

        #expect(AdminScan.main(output: output, paths: [drive.root.path, "--skip=" + drive.path("skip")]) == 0)
        let results = try PropertyListDecoder().decode([AdminResult].self, from: Data(contentsOf: URL(fileURLWithPath: output)))
        #expect(results.count == 1)
        #expect(!results[0].nodes.contains { $0.name == "skip" })

        let gone = drive.base.appending(path: "gone.alive").path
        #expect(AdminScan.main(output: output + "2", paths: [drive.root.path, "--alive=" + gone]) == 2)
        #expect(!FileManager.default.fileExists(atPath: output + "2"))
    }
}

@Suite struct DuplicateChunkTests {
    @Test func filesThatDifferEarlyAreDroppedWithoutReadingThemWhole() throws {
        let drive = try Drive()
        defer { drive.remove() }
        let size = 8 << 20
        var content = Data(count: size)
        for i in stride(from: 0, to: size, by: 4096) { content[i] = UInt8(truncatingIfNeeded: i / 4096) }
        try content.write(to: drive.root.appending(path: "a.img"))
        try content.write(to: drive.root.appending(path: "b.img"))
        content[200_000] ^= 0xFF  // inside the first chunk, past the sampled edges
        try content.write(to: drive.root.appending(path: "c.img"))
        let files = ["a.img", "b.img", "c.img"].enumerated().map { i, name -> LargeFile in
            var st = stat()
            lstat(drive.path(name), &st)
            return LargeFile(id: Int64(i), dir: 1, name: name, bytes: Int64(st.st_blocks) * 512, size: Int64(st.st_size),
                             modified: 0, inode: UInt64(st.st_ino), path: drive.path(name))
        }

        var read: Int64 = 0
        let matched = try Duplicates.compare(files, cancel: CancelFlag(), read: { read += $0 })
        #expect(matched.count == 1)
        let (hash, same) = try #require(matched.first)
        #expect(Set(same.map(\.name)) == ["a.img", "b.img"])
        #expect(hash == (try Duplicates.fullHash(drive.path("a.img"), cancel: CancelFlag())))
        // c.img stopped after its first megabyte.
        #expect(read == Int64(2 * size + Duplicates.chunk))
    }
}
