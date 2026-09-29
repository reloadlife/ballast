import Darwin
import Foundation
import Testing
@testable import Ballast

/// Scratch folders scanned as if they were a volume, as in VolumeScanTests.
private struct Scratch {
    let base: URL
    let root: URL
    let index: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "ballast-files-\(UUID().uuidString)")
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

    /// Writes real (not sparse) bytes, so the allocated size matches.
    @discardableResult
    func write(_ relative: String, bytes: Int, fill: UInt8 = 0) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
        return url
    }
}

private let big = Int(LargeFiles.threshold) + (1 << 20)

@Suite struct LargeFileWalkTests {
    @Test func walkerListsFilesAtOrAboveTheThresholdOnly() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let threshold: Int64 = 50 * 4096
        try scratch.write("a/exact.bin", bytes: Int(threshold))
        try scratch.write("a/under.bin", bytes: Int(threshold) - 4096)
        try scratch.write("b/over.mov", bytes: Int(threshold) * 2)
        // A hard link to a listed file is listed once, like it's counted once.
        try FileManager.default.linkItem(at: scratch.root.appending(path: "b/over.mov"),
                                         to: scratch.root.appending(path: "a/link.mov"))

        var nodes: [WalkNode] = []
        try Walker.walk(scratch.root.path, largeFiles: threshold) { nodes.append($0) }
        let listed = nodes.flatMap(\.large)
        #expect(Set(listed.map(\.name)).count == 2)
        #expect(listed.contains { $0.name == "exact.bin" && $0.bytes == threshold && $0.size == threshold })
        #expect(!listed.contains { $0.name == "under.bin" })
        #expect(listed.filter { $0.name == "over.mov" || $0.name == "link.mov" }.count == 1)
        // Still counted in the folder sizes as before.
        #expect(nodes.last!.total >= threshold * 4 - 4096)
    }

    @Test func kindsFromNameAndPlace() {
        let home = NSHomeDirectory()
        let cases: [(String, FileKind)] = [
            ("/Users/me/Movies/trip.MOV", .video),
            ("/Users/me/Downloads/Xcode_27.xip", .archive),
            ("/Users/me/Downloads/ubuntu.iso", .archive),
            ("/Users/me/backup.tar.gz", .archive),
            ("/Users/me/Backups/Mac.sparsebundle/bands/1f", .archive),
            ("/Users/me/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", .virtualMachine),
            ("/Users/me/VMs/Linux.utm/Data/efi_vars.fd", .virtualMachine),
            ("/Users/me/VMs/win.vmdk", .virtualMachine),
            ("/Users/me/.orbstack/data/data.img", .virtualMachine),
            (home + "/.android/avd/Pixel.avd/userdata-qemu.img", .virtualMachine),
            ("/Users/me/models/llama.gguf", .other),
            ("/Users/me/data.sqlite", .other),
        ]
        for (path, kind) in cases {
            #expect(FileKind(path: path) == kind, "\(path)")
        }
    }
}

@Suite struct LargeFileIndexTests {
    @Test func fullScanListsLargeFilesAndMarksTheListComplete() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.write("videos/big.mov", bytes: big)
        try scratch.write("videos/small.mov", bytes: 100_000)
        try ScanEngine.fullScan(try scratch.target, report: { _ in }, cancel: CancelFlag())

        let db = try IndexDB(path: scratch.index.path, mode: .read)
        let list = IndexReader.largeFiles(db)
        #expect(list.isComplete)
        #expect(list.files.map(\.path) == [scratch.root.path + "/videos/big.mov"])
        #expect(list.files[0].bytes >= LargeFiles.threshold)
        #expect(try db.meta("schema") == ScanEngine.schemaVersion)
    }

    @Test func rescanningAFolderReplacesItsFileRows() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.write("a/one.bin", bytes: big)
        try scratch.write("a/inner/two.bin", bytes: big)
        let target = try scratch.target
        try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag())

        // Deep: the folder is walked again.
        try FileManager.default.removeItem(at: scratch.root.appending(path: "a/one.bin"))
        try scratch.write("a/three.bin", bytes: big)
        try ScanEngine.rescan([scratch.root.path + "/a"], target: target, title: "", report: { _ in }, cancel: CancelFlag())
        var names = Set(IndexReader.largeFiles(try IndexDB(path: scratch.index.path, mode: .read)).files.map(\.name))
        #expect(names == ["two.bin", "three.bin"])

        // Shallow: a subfolder that's gone makes its parent be re-listed,
        // which drops the subfolder's files and re-reads the parent's own.
        try FileManager.default.removeItem(at: scratch.root.appending(path: "a/inner"))
        try scratch.write("a/four.bin", bytes: big)
        try ScanEngine.rescan([scratch.root.path + "/a/inner"], target: target, title: "", report: { _ in }, cancel: CancelFlag())
        names = Set(IndexReader.largeFiles(try IndexDB(path: scratch.index.path, mode: .read)).files.map(\.name))
        #expect(names == ["three.bin", "four.bin"])
    }

    /// An index saved before large files were recorded: schema 2, no
    /// `files` table.
    private func makeOldIndex(_ scratch: Scratch) throws {
        try ScanEngine.fullScan(try scratch.target, report: { _ in }, cancel: CancelFlag())
        let db = try IndexDB(path: scratch.index.path, mode: .read)
        try db.exec("DROP TABLE files; DELETE FROM meta WHERE key = '\(ScanEngine.largeFilesKey)'; UPDATE meta SET value = '2' WHERE key = 'schema';")
    }

    @Test func anOldIndexStillOpensAndSaysTheListIsntReady() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.write("a/one.bin", bytes: big)
        try makeOldIndex(scratch)

        let old = try IndexDB(path: scratch.index.path, mode: .read)
        #expect(IndexReader.overview(old, home: false)?.root.total ?? 0 >= LargeFiles.threshold)
        #expect(throws: IndexError.self) { try old.largeFiles() }
        #expect(!IndexReader.largeFiles(old).isComplete)
        #expect(ScanEngine.compatibleSchemas.contains("2"))

        // Opening it to update adds the table, empty; nothing is rescanned.
        let migrated = try IndexDB(path: scratch.index.path, mode: .write)
        #expect(try migrated.largeFiles().isEmpty)
        #expect(try migrated.meta("schema") == "2")
    }

    @Test func updatesFillAnOldIndexButOnlyAFullScanCompletesTheList() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.write("a/one.bin", bytes: big)
        try scratch.write("b/two.bin", bytes: big)
        try makeOldIndex(scratch)
        let target = try scratch.target

        try ScanEngine.rescan([scratch.root.path + "/a"], target: target, title: "", report: { _ in }, cancel: CancelFlag())
        let db = try IndexDB(path: scratch.index.path, mode: .read)
        #expect(try db.largeFiles().map(\.file.name) == ["one.bin"])
        #expect(!IndexReader.largeFiles(db).isComplete)

        try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag())
        let rebuilt = IndexReader.largeFiles(try IndexDB(path: scratch.index.path, mode: .read))
        #expect(rebuilt.isComplete)
        #expect(Set(rebuilt.files.map(\.name)) == ["one.bin", "two.bin"])
    }

    @Test func explorerGetsAFoldersOwnFiles() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.write("a/one.bin", bytes: big)
        try scratch.write("a/b/two.bin", bytes: big)
        try ScanEngine.fullScan(try scratch.target, report: { _ in }, cancel: CancelFlag())

        let reader = IndexReader(index: scratch.index.path, isStartup: false)
        await reader.reopen()
        let id = try #require(await reader.deepest(scratch.root.path + "/a"))
        let files = try #require(await reader.explore(id).files)
        #expect(files.map(\.path) == [scratch.root.path + "/a/one.bin"])
    }
}

@Suite struct DuplicateTests {
    private func file(_ url: URL, id: Int64) throws -> LargeFile {
        var st = stat()
        #expect(lstat(url.path, &st) == 0)
        return LargeFile(id: id, dir: 1, name: url.lastPathComponent, bytes: Int64(st.st_blocks) * 512,
                         size: Int64(st.st_size), modified: Int64(st.st_mtimespec.tv_sec), inode: UInt64(st.st_ino),
                         path: url.path)
    }

    private func random(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    @Test func sameContentIsADuplicateSameSizeAloneIsNot() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let content = random(400_000)
        var differentMiddle = content
        differentMiddle[200_000] ^= 0xFF  // same first and last 64 KB
        var differentStart = content
        differentStart[0] ^= 0xFF
        let urls = [("a.bin", content), ("b.bin", content), ("c.bin", differentMiddle), ("d.bin", differentStart)]
            .map { name, data -> URL in
                let url = scratch.root.appending(path: name)
                try? data.write(to: url)
                return url
            }
        // Another name for a.bin: not a copy.
        let link = scratch.root.appending(path: "link.bin")
        try FileManager.default.linkItem(at: urls[0], to: link)

        let files = try (urls + [link]).enumerated().map { try file($1, id: Int64($0)) }
        let report = try Duplicates.find(files, isProtected: { _ in false }, cancel: CancelFlag())
        #expect(report.groups.count == 1)
        #expect(Set(report.groups[0].copies.map(\.name)) == ["a.bin", "b.bin"])
        #expect(report.hardLinks == 1)
        #expect(report.checked == 5)
    }

    @Test func protectedPlacesAreLeftOut() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let content = random(100_000)
        let a = scratch.root.appending(path: "a.bin")
        let b = scratch.root.appending(path: "Photos Library.photoslibrary/b.bin")
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: a)
        try content.write(to: b)
        let report = try Duplicates.find([try file(a, id: 1), try file(b, id: 2)],
                                         isProtected: { $0.contains(".photoslibrary") }, cancel: CancelFlag())
        #expect(report.groups.isEmpty)
        #expect(report.protectedFiles == 1)
    }

    @Test func clonesAreDetectedAndFreeNothing() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let a = scratch.root.appending(path: "a.bin")
        let clone = scratch.root.appending(path: "clone.bin")
        let copy = scratch.root.appending(path: "copy.bin")
        let content = random(1 << 20)
        try content.write(to: a)
        try content.write(to: copy)
        // Only APFS clones; elsewhere there's nothing to test.
        guard clonefile(a.path, clone.path, 0) == 0 else {
            #expect(errno == ENOTSUP || errno == EXDEV)
            return
        }

        let original = try #require(StorageSharing.of(a.path))
        let cloned = try #require(StorageSharing.of(clone.path))
        #expect(cloned.sharesAll && original.sharesAll)
        #expect(cloned.cloneID != nil && cloned.cloneID == original.cloneID)
        #expect(cloned.cloneCount == 2)
        #expect(cloned.privateBytes == 0)
        let separate = try #require(StorageSharing.of(copy.path))
        #expect(!separate.sharesAll && separate.privateBytes > 0 && separate.cloneID != original.cloneID)

        let files = try [a, clone, copy].enumerated().map { try file($1, id: Int64($0)) }
        let report = try Duplicates.find(files, isProtected: { _ in false }, cancel: CancelFlag())
        let group = try #require(report.groups.first)
        #expect(group.copies.count == 3)
        let bytes = files[0].bytes
        // Keeping the original: its clone frees nothing, the copy frees all of itself.
        #expect(group.reclaimable(keeping: a.path) == bytes)
        #expect(group.freed(keeping: a.path)[clone.path] == 0)
        // Keeping the copy: the two clones go together and free their storage once.
        #expect(group.reclaimable(keeping: copy.path) == bytes)

        // Only the clones: already sharing, so not a suggestion at all.
        let clonesOnly = try Duplicates.find(Array(files.prefix(2)), isProtected: { _ in false }, cancel: CancelFlag())
        #expect(clonesOnly.groups.isEmpty)
        #expect(clonesOnly.cloned.count == 1)
    }

    @Test func reclaimableCountsEachCopysOwnStorage() {
        func copy(_ path: String, _ bytes: Int64, modified: Int64 = 100, _ sharing: StorageSharing? = nil) -> DuplicateCopy {
            DuplicateCopy(path: path, bytes: bytes, modified: modified, sharing: sharing)
        }
        let plain = DuplicateGroup(copies: [copy("/x/a", 100), copy("/x/b", 100), copy("/x/c", 100)], size: 90, hash: "h")
        #expect(plain.reclaimable(keeping: "/x/a") == 200)

        // A clone whose storage something outside the group also uses frees only what it changed.
        let shared = StorageSharing(privateBytes: 0, cloneID: 7, cloneCount: 3, sharesAll: true)
        let partly = DuplicateGroup(copies: [copy("/x/a", 100), copy("/x/b", 100, shared), copy("/x/c", 100, shared)],
                                    size: 90, hash: "h2")
        #expect(partly.reclaimable(keeping: "/x/a") == 0)

        // Blocks changed since cloning are the copy's own.
        let diverged = StorageSharing(privateBytes: 30, cloneID: 8, cloneCount: 1, sharesAll: false)
        let edited = DuplicateGroup(copies: [copy("/x/a", 100), copy("/x/b", 100, diverged)], size: 90, hash: "h3")
        #expect(edited.reclaimable(keeping: "/x/a") == 30)
        #expect(edited.reclaimable(keeping: "/x/b") == 100)
    }

    @Test func keepsTheOldestCopyOutsideDownloadsByDefault() {
        let home = NSHomeDirectory()
        let group = DuplicateGroup(copies: [
            DuplicateCopy(path: home + "/Downloads/movie.mov", bytes: 1, modified: 10, sharing: nil),
            DuplicateCopy(path: home + "/Movies/new/movie.mov", bytes: 1, modified: 30, sharing: nil),
            DuplicateCopy(path: home + "/Movies/movie.mov", bytes: 1, modified: 20, sharing: nil),
        ], size: 1, hash: "h")
        #expect(group.suggestedKeep == home + "/Movies/movie.mov")
    }
}

@Suite struct LargeFileSafetyTests {
    let home = NSHomeDirectory()

    @Test func aRunningVMsDiskMustWait() {
        let utm = RunningApp(name: "UTM", bundleID: "com.utmapp.UTM", pid: 1, bundlePath: "/Applications/UTM.app")
        let disk = home + "/VMs/Linux.utm/Data/disk.qcow2"
        #expect(SafetyCheck.assess(disk, isDirectory: false, apps: AppInventory(running: [utm], installed: []),
                                   protected: []).level == .quitFirst)
        #expect(SafetyCheck.assess(disk, isDirectory: false, apps: AppInventory(running: [], installed: []),
                                   protected: []).level == .safe)
        // A video isn't a VM's disk, whatever runs.
        #expect(SafetyCheck.assess(home + "/Movies/a.mov", isDirectory: false, apps: AppInventory(running: [utm], installed: []),
                                   protected: []).level == .safe)
    }

    @Test(arguments: [
        "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
        "/Pictures/Photos Library.photoslibrary/originals/A/IMG.mov",
        "/Library/Mail/V10/attachment.zip",
        "/projects/app/.git/objects/pack/pack-1.pack",
    ])
    func filesInProtectedPlacesStayProtected(_ relative: String) {
        let apps = AppInventory(running: [], installed: [InstalledApp(name: "Docker", bundleID: "com.docker.docker")])
        #expect(SafetyCheck.assess(home + relative, isDirectory: false, apps: apps, protected: []).level == .blocked)
    }
}
