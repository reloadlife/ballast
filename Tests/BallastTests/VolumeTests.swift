import Darwin
import Foundation
import Testing
@testable import Ballast

/// Which volumes are listed, and how.
@Suite struct VolumeFilterTests {
    private func drive(_ path: String = "/Volumes/Drive", configure: (inout VolumeCandidate) -> Void = { _ in }) -> VolumeCandidate {
        var candidate = VolumeCandidate(path: path, uuid: UUID().uuidString, name: "Drive", typeName: "apfs",
                                        formatDescription: "APFS", isJournaled: true, isRemovable: true)
        configure(&candidate)
        return candidate
    }

    @Test func listsALocalDriveWithAnIdentifier() {
        #expect(Volumes.classify(drive()) == .indexable)
    }

    @Test func listsReadOnlyDrivesForViewing() {
        #expect(Volumes.classify(drive { $0.isReadOnly = true; $0.typeName = "ntfs" }) == .indexable)
    }

    @Test func networkDrivesAreListedAsUnsupported() {
        guard case .unsupported(let reason) = Volumes.classify(drive { $0.isLocal = false; $0.typeName = "smbfs" }) else {
            Issue.record("a network drive should be unsupported")
            return
        }
        #expect(reason.contains("Network"))
    }

    @Test func drivesWithoutAnIdentifierCantBeIndexed() {
        #expect(Volumes.classify(drive { $0.uuid = nil }) != .indexable)
        #expect(Volumes.classify(drive { $0.uuid = "../../elsewhere" }) != .indexable)
    }

    @Test func hidesTheStartupDisk() {
        #expect(Volumes.classify(drive("/") { $0.isRootFileSystem = true }) == .hidden)
        #expect(Volumes.classify(drive("/System/Volumes/Data") { $0.isStartupData = true }) == .hidden)
        // Mounted somewhere else but the same device as the data volume.
        #expect(Volumes.classify(drive { $0.isStartupData = true }) == .hidden)
    }

    @Test func hidesTimeMachineBackupsEntirely() {
        #expect(Volumes.classify(drive { $0.roles = ["Backup"] }) == .hidden)
        #expect(Volumes.classify(drive { $0.hasTimeMachineFiles = true; $0.typeName = "hfs" }) == .hidden)
        #expect(Volumes.classify(drive("/Volumes/.timemachine/ABC/2026-09-01-120000.backup")) == .hidden)
        // A TM disk that's also a network share still isn't listed.
        #expect(Volumes.classify(drive { $0.roles = ["Backup"]; $0.isLocal = false }) == .hidden)
    }

    @Test(arguments: ["Preboot", "Recovery", "VM", "Update", "Hardware", "xART"])
    func hidesMacOSHelperVolumes(_ role: String) {
        #expect(Volumes.classify(drive { $0.roles = [role] }) == .hidden)
    }

    @Test func listsAnotherMacOSInstallForViewing() {
        // Cleaning it is blocked by the safety rules, not by the list.
        #expect(Volumes.classify(drive { $0.roles = ["Data"] }) == .indexable)
    }

    @Test func namesFormatsPeopleKnow() {
        #expect(Volumes.formatName(type: "apfs", description: "APFS") == "APFS")
        #expect(Volumes.formatName(type: "exfat", description: "ExFAT") == "ExFAT")
        #expect(Volumes.formatName(type: "msdos", description: "MS-DOS (FAT32)") == "FAT32")
        #expect(Volumes.formatName(type: "hfs", description: "Mac OS Extended (Journaled)") == "Mac OS Extended")
        #expect(Volumes.formatName(type: "ntfs", description: "Windows NT File System (NTFS)") == "NTFS")
    }
}

/// Where each volume's index lives, and forgetting it.
@Suite struct VolumeIndexTests {
    @Test func indexPathIsDerivedFromTheCanonicalUUID() throws {
        let uuid = UUID()
        let dir = "/tmp/support/volumes"
        #expect(Paths.volumeIndex(uuid.uuidString, in: dir) == "\(dir)/\(uuid.uuidString)/index.sqlite")
        // Lower case comes back canonical, so one drive never gets two folders.
        #expect(Paths.volumeDir(uuid.uuidString.lowercased(), in: dir) == "\(dir)/\(uuid.uuidString)")
    }

    @Test(arguments: ["", "..", "../index", "ABC", "1ED2DA26-D2CF-4ED4-B5DB-28FE4F622AA9/../.."])
    func rejectsAnythingThatIsntAUUID(_ text: String) {
        #expect(Paths.volumeDir(text) == nil)
        #expect(Paths.volumeIndex(text) == nil)
    }

    @Test func startupIndexStaysWhereItWas() {
        #expect(Paths.index == Paths.supportDir + "/index.sqlite")
        #expect(IndexTarget.startup.index == Paths.index)
        #expect(IndexTarget.startup.root == "/System/Volumes/Data")
        #expect(IndexTarget.startup.isStartup)
    }

    @Test func forgetDeletesOnlyThatVolumesFolder() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "ballast-volumes-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: dir) }
        let gone = UUID().uuidString
        let kept = UUID().uuidString
        for uuid in [gone, kept] {
            try fm.createDirectory(atPath: dir + "/" + uuid, withIntermediateDirectories: true)
            try Data("index".utf8).write(to: URL(fileURLWithPath: dir + "/\(uuid)/index.sqlite"))
        }
        try Volumes.forget(gone, in: dir)
        #expect(!fm.fileExists(atPath: dir + "/" + gone))
        #expect(fm.fileExists(atPath: dir + "/\(kept)/index.sqlite"))
        #expect(throws: IndexError.self) { try Volumes.forget("../\(kept)", in: dir) }
        #expect(fm.fileExists(atPath: dir + "/\(kept)/index.sqlite"))
    }

    @Test func knownVolumesComeFromTheirIndexes() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "ballast-known-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: dir) }
        let uuid = UUID().uuidString
        try fm.createDirectory(atPath: dir + "/" + uuid, withIntermediateDirectories: true)
        let db = try IndexDB(path: dir + "/\(uuid)/index.sqlite", mode: .build)
        try db.setMeta("mountPath", "/Volumes/Photos SSD")
        try db.setMeta("volumeName", "Photos SSD")
        try db.setMeta("format", "ExFAT")
        try db.setMeta("journaled", "0")
        try db.setMeta("scannedAt", String(Date.now.addingTimeInterval(-3 * 86_400).timeIntervalSince1970))
        // A stray folder that isn't a UUID is ignored.
        try fm.createDirectory(atPath: dir + "/notes", withIntermediateDirectories: true)

        let known = Volumes.known(in: dir)
        #expect(known.count == 1)
        let volume = try #require(known.first)
        #expect(volume.name == "Photos SSD")
        #expect(!volume.isJournaled)

        // Unplugged: listed from its index, with nothing mounted.
        let disks = Disk.list(mounted: [], known: known)
        #expect(disks.count == 1)
        #expect(disks.first?.isConnected == false)
        #expect(disks.first?.isScanned == true)
        #expect(disks.first?.path == "/Volumes/Photos SSD")
    }

    @Test func connectedDisksMergeWithTheirIndex() {
        let uuid = UUID().uuidString
        let mounted = MountedVolume(uuid: uuid, name: "Work", path: "/Volumes/Work 1", format: "APFS", isReadOnly: false,
                                    isJournaled: true, isRemovable: true, total: 1_000, free: 400, device: 42)
        let known = Volumes.Known(uuid: uuid, name: "Work", format: "APFS", lastPath: "/Volumes/Work", scannedAt: .now,
                                  isJournaled: true, isRemovable: true, total: 1_000)
        let other = MountedVolume(uuid: UUID().uuidString, name: "Stick", path: "/Volumes/Stick", format: "ExFAT",
                                  isReadOnly: false, isJournaled: false, isRemovable: true, total: 10, free: 5, device: 43)
        let disks = Disk.list(mounted: [mounted, other], known: [known])
        #expect(disks.count == 2)
        // Where it's mounted now wins over where it was.
        #expect(disks[0].path == "/Volumes/Work 1")
        #expect(disks[0].isScanned && disks[0].isConnected)
        #expect(!disks[1].isScanned)
    }
}

/// Walks stay on the volume they started on, like `du -x`.
@Suite struct DeviceBoundaryTests {
    @Test func descendsOnlyOnTheSameDevice() {
        #expect(Walker.descends(into: 16_777_234, from: 16_777_234))
        // A disk image or USB drive mounted inside the walk.
        #expect(!Walker.descends(into: 16_777_250, from: 16_777_234))
        // A network share mounted in the home folder.
        #expect(!Walker.descends(into: 872_415_232, from: 16_777_234))
    }

    @Test func walkOfAFolderCountsEverythingOnItsDevice() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ballast-dev-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "a/b"), withIntermediateDirectories: true)
        try Data(count: 40_000).write(to: root.appending(path: "a/b/f.bin"))

        var nodes: [WalkNode] = []
        try Walker.walk(root.path) { nodes.append($0) }
        #expect(nodes.count == 3)
        #expect(nodes.last?.files == 1)
        #expect(nodes.allSatisfy { $0.err == 0 })
    }

    @Test func exclusionsOnADriveUseItsOwnPaths() {
        let excluded = Exclusions(drive: "/Volumes/Work", ["/Volumes/Work/VMs/", "/Users/me/VMs", "/Volumes/Workshop/x"])
        #expect(excluded.paths == ["/Volumes/Work/VMs"])
        #expect(excluded.covers("/Volumes/Work/VMs/disk.img"))
        // The startup disk's list is computed exactly as before.
        #expect(Exclusions(["/Users/me/VMs"]).contains("/System/Volumes/Data/Users/me/VMs"))
    }
}

/// Indexing a folder as if it were another volume: the scan, remeasuring,
/// a new mount point, and a drive that goes away mid-scan.
@Suite struct VolumeScanTests {
    let fm = FileManager.default

    /// A target whose "volume" is a temp folder on the data volume, with
    /// that volume's real identity so the still-mounted check passes.
    private func target(root: URL, index: URL, uuid: String? = nil) throws -> IndexTarget {
        var st = stat()
        lstat(root.path, &st)
        let real = try #require(try root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        let volume = MountedVolume(uuid: uuid ?? real, name: "Test", path: root.path, format: "APFS", isReadOnly: false,
                                   isJournaled: true, isRemovable: true, total: 0, free: 0, device: st.st_dev)
        return IndexTarget(index: index.path, root: root.path, device: st.st_dev, volume: volume)
    }

    private func scratch() throws -> (root: URL, index: URL, cleanup: () -> Void) {
        let base = fm.temporaryDirectory.appending(path: "ballast-vol-\(UUID().uuidString)")
        let root = base.appending(path: "Drive")
        try fm.createDirectory(at: root.appending(path: "photos/2026"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "app/node_modules/pkg"), withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: root.appending(path: "photos/2026/a.raw"))
        try Data(count: 120_000).write(to: root.appending(path: "app/node_modules/pkg/index.js"))
        try Data("{}".utf8).write(to: root.appending(path: "app/package.json"))
        return (root, base.appending(path: "index/index.sqlite"), { try? FileManager.default.removeItem(at: base) })
    }

    @Test func fullScanIndexesTheDriveUnderItsMountPath() throws {
        let (root, index, cleanup) = try scratch()
        defer { cleanup() }
        let target = try target(root: root, index: index)
        try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag())

        let db = try IndexDB(path: index.path, mode: .read)
        let top = try #require(try db.root())
        #expect(top.name == root.path)
        #expect(top.total >= 420_000)
        #expect(try db.meta("mountPath") == root.path)
        #expect(try db.meta("volumeName") == "Test")
        let photos = try #require(try db.locate(root.path + "/photos").last)
        #expect(photos.path == root.path + "/photos")

        // Build folders are found on it like on the startup disk.
        let artifacts = ArtifactScanner.scan(db)
        #expect(artifacts.map(\.path) == [root.path + "/app/node_modules"])
    }

    @Test func remeasuringDropsWhatWasCleaned() throws {
        let (root, index, cleanup) = try scratch()
        defer { cleanup() }
        let target = try target(root: root, index: index)
        try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag())
        let before = try #require(try IndexDB(path: index.path, mode: .read).root()).total

        try fm.removeItem(at: root.appending(path: "app/node_modules"))
        try ScanEngine.rescan([root.path + "/app/node_modules"], target: target, title: "Measuring",
                              report: { _ in }, cancel: CancelFlag())
        let db = try IndexDB(path: index.path, mode: .read)
        #expect(try db.root()!.total < before - 100_000)
        #expect(try db.locate(root.path + "/app/node_modules").last?.path == root.path + "/app")
    }

    @Test func aDriveBackUnderAnotherNameKeepsItsIndex() throws {
        let (root, index, cleanup) = try scratch()
        defer { cleanup() }
        try ScanEngine.fullScan(try target(root: root, index: index), report: { _ in }, cancel: CancelFlag())

        let renamed = root.deletingLastPathComponent().appending(path: "Drive 1")
        try fm.moveItem(at: root, to: renamed)
        ScanEngine.adopt(try target(root: renamed, index: index))
        let db = try IndexDB(path: index.path, mode: .read)
        #expect(try db.root()?.name == renamed.path)
        #expect(try db.meta("mountPath") == renamed.path)
        #expect(try db.locate(renamed.path + "/photos/2026").last?.path == renamed.path + "/photos/2026")
    }

    @Test func aDriveThatWentAwayLeavesTheOldIndexAlone() throws {
        let (root, index, cleanup) = try scratch()
        defer { cleanup() }
        try ScanEngine.fullScan(try target(root: root, index: index), report: { _ in }, cancel: CancelFlag())
        let saved = try Data(contentsOf: index)

        // Another identity at the same mount point: what a scan sees when
        // the drive is swapped or force-ejected mid-walk.
        let swapped = try target(root: root, index: index, uuid: UUID().uuidString)
        #expect(throws: ScanEngine.Failure.self) {
            try ScanEngine.fullScan(swapped, report: { _ in }, cancel: CancelFlag())
        }
        #expect(try Data(contentsOf: index) == saved)
        #expect(!fm.fileExists(atPath: index.path + ".building"))
    }

    @Test func cancellingAScanKeepsNothingHalfDone() throws {
        let (root, index, cleanup) = try scratch()
        defer { cleanup() }
        for i in 0..<1_500 { try fm.createDirectory(at: root.appending(path: "many/\(i)"), withIntermediateDirectories: true) }
        let cancel = CancelFlag()
        cancel.set()
        #expect(throws: CancellationError.self) {
            try ScanEngine.fullScan(try target(root: root, index: index), report: { _ in }, cancel: cancel)
        }
        #expect(!fm.fileExists(atPath: index.path))
        #expect(!fm.fileExists(atPath: index.path + ".building"))
    }
}

/// The safety rules for other drives.
@Suite struct DriveSafetyTests {
    let nobody = AppInventory(running: [], installed: [])
    let drive = DriveFacts(mountPath: "/Volumes/Work", name: "Work")

    private func verdict(_ path: String, _ facts: DriveFacts? = nil, directory: Bool = true) -> Safety {
        SafetyCheck.drive(facts ?? drive, rules: path, isDirectory: directory)
    }

    @Test func readOnlyDrivesAreProtected() {
        var readOnly = drive
        readOnly.isReadOnly = true
        let safety = verdict("/Volumes/Work/old/stuff", readOnly)
        #expect(safety.level == .blocked)
        #expect(safety.reason == "This drive is read-only.")
        // Through the full check too, with the drive looked up.
        let assessed = SafetyCheck.assess("/Volumes/Work/old/stuff", isDirectory: true, apps: nobody, protected: [],
                                          drives: { _ in readOnly })
        #expect(assessed.level == .blocked)
        #expect(assessed.reason == "This drive is read-only.")
    }

    @Test func unpluggedNetworkAndBackupDrivesAreProtected() {
        var facts = drive
        facts.isConnected = false
        #expect(verdict("/Volumes/Work/a", facts).level == .blocked)
        facts = drive
        facts.isLocal = false
        #expect(verdict("/Volumes/Work/a", facts).level == .blocked)
        facts = drive
        facts.isTimeMachine = true
        #expect(verdict("/Volumes/Work/Backups.backupdb", facts).level == .blocked)
        #expect(verdict("/Volumes/Work/a", facts).level == .blocked)
    }

    @Test func theDriveItselfAndItsHousekeepingAreProtected() {
        #expect(verdict("/Volumes/Work").level == .blocked)
        #expect(verdict("/Volumes/Work/").level == .blocked)
        #expect(verdict("/Volumes/Workshop/a").level == .blocked)
        #expect(verdict("/Volumes/Work/a/../../Other").level == .blocked)
        for item in [".Trashes", ".Trashes/501", ".fseventsd", ".Spotlight-V100", ".DocumentRevisions-V100",
                     "System Volume Information", "$RECYCLE.BIN"] {
            #expect(verdict("/Volumes/Work/" + item).level == .blocked, "\(item)")
        }
    }

    @Test func aDriveWithMacOSOnItIsLeftAlone() {
        var facts = drive
        facts.holdsMacOS = true
        #expect(verdict("/Volumes/Work/Users/me/Downloads/x.zip", facts, directory: false).level == .blocked)
    }

    @Test func versionHistoryAndSecretsStayProtected() {
        #expect(verdict("/Volumes/Work/code/app/.git").level == .blocked)
        #expect(verdict("/Volumes/Work/backup/.ssh").level == .blocked)
        #expect(verdict("/Volumes/Work/Photos Library.photoslibrary/originals").level == .blocked)
    }

    @Test func ownFilesAndBuildFoldersCanBeCleaned() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "ballast-drive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appending(path: "app/node_modules"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: base.appending(path: "app/package.json"))
        let facts = DriveFacts(mountPath: base.path, name: "Work")

        let modules = verdict(base.path + "/app/node_modules", facts)
        #expect(modules.level == .safe)
        #expect(modules.reason.contains("Build output"))
        #expect(verdict(base.path + "/movies/old.mov", facts, directory: false).level == .safe)
        #expect(verdict(base.path + "/Tools.app", facts).level == .caution)
    }

    @Test func protectedFoldersApplyOnDrivesToo() {
        let safety = SafetyCheck.assess("/Volumes/Work/keep/this", isDirectory: true, apps: nobody,
                                        protected: ["/Volumes/Work/keep"], drives: { _ in drive })
        #expect(safety.level == .blocked)
        #expect(safety.reason.contains("protected"))
    }

    @Test func startupDiskPathsAreNotDrives() {
        #expect(Drives.facts(for: NSHomeDirectory() + "/Downloads") == nil)
        #expect(Drives.facts(for: "/Applications/Safari.app") == nil)
        // A /Volumes path with nothing mounted there is an unplugged drive.
        let gone = Drives.facts(for: "/Volumes/Ballast-Not-Mounted-\(UUID().uuidString)/a")
        #expect(gone?.isConnected == false)
        #expect(!Drives.isInsideMountedDrive("/Volumes/Ballast-Not-Mounted/a"))
    }
}
