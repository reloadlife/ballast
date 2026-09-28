import BallastCore
import Foundation
import Testing
@testable import Ballast

@Suite struct TreemapTests {
    @Test func tilesFillTheRectExactly() {
        let values: [Double] = [500, 300, 120, 50, 20, 7, 3]
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 400)
        let rects = TreemapLayout.layout(values, in: bounds)

        #expect(rects.count == values.count)
        let area = rects.reduce(0) { $0 + $1.width * $1.height }
        #expect(abs(area - bounds.width * bounds.height) < 1)
        for rect in rects {
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(rect))
        }
        // Proportional: the biggest value gets the biggest tile.
        #expect(rects[0].width * rects[0].height > rects[1].width * rects[1].height)
    }

    @Test func emptyInputIsHarmless() {
        #expect(TreemapLayout.layout([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(TreemapLayout.layout([1, 2], in: .zero) == [.zero, .zero])
    }
}

@Suite struct WalkerTests {
    @Test func measuresASmallTreeLikeDu() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ballast-walk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "a/b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "c"), withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: root.appending(path: "a/one.bin"))
        try Data(count: 50_000).write(to: root.appending(path: "a/b/two.bin"))
        try Data(count: 10_000).write(to: root.appending(path: "c/three.bin"))
        // A hard link must be counted once.
        try fm.linkItem(at: root.appending(path: "a/one.bin"), to: root.appending(path: "c/link.bin"))

        var nodes: [WalkNode] = []
        try Walker.walk(root.path) { nodes.append($0) }

        let top = try #require(nodes.last)
        #expect(top.local == 0)
        #expect(nodes.count == 4)            // root, a, a/b, c
        #expect(top.files == 3)              // the link is skipped
        #expect(top.total >= 160_000)        // allocated size is at least the logical size
        #expect(top.total < 400_000)
        // Children are emitted before parents.
        #expect(nodes.firstIndex { $0.name == "b" }! < nodes.firstIndex { $0.name == "a" }!)
    }
}

@Suite struct ExclusionTests {
    @Test func matchesVolumePathsOfExcludedFolders() {
        let excluded = Exclusions(["/Users/me/VMs", "/Users/me/Movies/"])
        #expect(excluded.contains("/System/Volumes/Data/Users/me/VMs"))
        #expect(excluded.contains("/System/Volumes/Data/Users/me/Movies"))  // trailing slash ignored
        #expect(!excluded.contains("/System/Volumes/Data/Users/me/VMs/disk.img"))
        #expect(excluded.covers("/System/Volumes/Data/Users/me/VMs/disk.img"))
        #expect(excluded.covers("/System/Volumes/Data/Users/me/VMs"))
    }

    @Test func siblingsWithTheSamePrefixAreNotExcluded() {
        let excluded = Exclusions(["/Users/me/VMs"])
        #expect(!excluded.contains("/System/Volumes/Data/Users/me/VMs2"))
        #expect(!excluded.covers("/System/Volumes/Data/Users/me/VMs2/a"))
        #expect(!excluded.covers("/System/Volumes/Data/Users/me"))
    }

    @Test func fingerprintRoundTrips() {
        let excluded = Exclusions(["/b", "/a"])
        #expect(Exclusions(fingerprint: excluded.fingerprint) == excluded)
        #expect(Exclusions(fingerprint: "").isEmpty)
    }

    @Test func walkerLeavesExcludedFoldersOut() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ballast-skip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "keep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "skip/inner"), withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: root.appending(path: "keep/a.bin"))
        try Data(count: 500_000).write(to: root.appending(path: "skip/inner/b.bin"))

        // Walk paths are real paths here, so build the set directly.
        let skip = Exclusions(fingerprint: root.path + "/skip")
        var nodes: [WalkNode] = []
        try Walker.walk(root.path, skip: skip) { nodes.append($0) }

        #expect(nodes.map(\.name).sorted() == [root.path, "keep"].sorted())
        let top = try #require(nodes.last)
        #expect(top.files == 1)
        #expect(top.total < 500_000)
    }
}

@Suite struct CleanerTests {
    @Test func structuralGuard() {
        let home = NSHomeDirectory()
        #expect(!Cleaner.canRemove(home))
        #expect(!Cleaner.canRemove(home + "/Documents"))
        #expect(!Cleaner.canRemove(home + "/Library/Caches"))
        #expect(!Cleaner.canRemove("/usr/local/lib"))
        #expect(Cleaner.canRemove(home + "/projects/app/node_modules"))
        #expect(Cleaner.canRemove(home + "/Library/Caches/com.example.app"))
    }
}

@Suite struct SystemDataTests {
    @Test func readsTheBootContainer() {
        let layout = SystemVolumes.read()
        // Every APFS Mac has a data volume and a sealed system volume.
        #expect((layout.dataVolumeBytes ?? 0) > 0)
        #expect(layout.volumes.contains { $0.role == "System" })
        #expect(layout.volumes.allSatisfy { $0.bytes > 0 && $0.role != "Data" })
    }

    @Test func everyVolumeRoleGetsPlainWords() {
        for role in ["System", "Preboot", "VM", "Recovery", "Update"] {
            let item = SystemDataCatalog.volume(.init(name: "x", role: role, bytes: 1))
            #expect(item.name != "x")
            #expect(!item.detail.contains("`"))
        }
    }
}

@Suite struct CommandCleanupTests {
    @Test func toolCommandsRunEvenWhenTheirFolderIsOutsideHome() {
        // Homebrew lives in /opt/homebrew; `brew cleanup` must still run.
        let item = PlanItem(name: "Homebrew", path: "/opt/homebrew", bytes: 1, action: .command("true"),
                            isDirectory: true, safety: .safe("tool"), included: true)
        let outcome = Cleaner.clean([item], permanently: true, apps: AppInventory(running: [], installed: []),
                                    protected: [], cancel: CancelFlag()) { _, _ in }
        #expect(outcome.first?.succeeded == true)
    }

    @Test func removingOutsideHomeIsStillRefused() {
        let item = PlanItem(name: "x", path: "/opt/homebrew", bytes: 1, action: .remove,
                            isDirectory: true, safety: .safe("forged"), included: true)
        let outcome = Cleaner.clean([item], permanently: true, apps: AppInventory(running: [], installed: []),
                                    protected: [], cancel: CancelFlag()) { _, _ in }
        #expect(outcome.first?.succeeded == false)
    }
}

@Suite struct CatalogTests {
    let home = NSHomeDirectory()

    @Test func pathsAreUnique() {
        let paths = Catalog.targets.map(\.path)
        #expect(Set(paths).count == paths.count)
    }

    @Test func entriesOnlyNestInsideFoldersThatGetEmptied() {
        // Nested inside something removed whole, or cleaned by a command,
        // an entry would be counted and cleaned twice.
        for outer in Catalog.targets {
            for inner in Catalog.targets where inner.path.hasPrefix(outer.path + "/") {
                #expect(outer.action == .contents, "\(inner.name) sits inside \(outer.name)")
                #expect(Catalog.keptWhenEmptying.contains(inner.path))
            }
        }
    }

    @Test func emptyingCachesLeavesSeparateEntriesAlone() {
        let caches = home + "/Library/Caches"
        #expect(!Catalog.covers(caches, action: .contents, caches + "/pip"))
        #expect(!Catalog.covers(caches, action: .contents, caches + "/pip/http"))
        #expect(Catalog.covers(caches, action: .contents, caches + "/com.example.editor"))
        #expect(!Catalog.covers(home + "/Library/Logs", action: .contents, Paths.logsDir))
        #expect(Catalog.covers(home + "/.cache", action: .contents, home + "/.cache/uv"))
        #expect(!Catalog.covers(home + "/.cache", action: .contents, home + "/.cache/huggingface"))
        // Removing a folder takes everything in it.
        #expect(Catalog.covers(home + "/projects/app", action: .remove, home + "/projects/app/node_modules"))
        #expect(!Catalog.covers(home + "/projects/app", action: .remove, home + "/projects/app2"))
    }

    @Test func keptFoldersAreCountedOnce() {
        let kept = [home + "/a/b", home + "/a/b/c", home + "/a/d", home + "/x"]
        #expect(Catalog.kept(inside: home + "/a", kept: kept) == [home + "/a/b", home + "/a/d"])
    }

    @Test func safeTotalCountsNestedEntriesAlongsideTheirFolder() {
        func result(_ path: String, _ action: CleanAction, _ bytes: Int64) -> ScanResult {
            ScanResult(target: Target(name: path, path: path, category: .caches, action: action), bytes: bytes)
        }
        let caches = home + "/Library/Caches"
        let cleanup = [result(caches, .contents, 100), result(caches + "/pip", .command("pip3 cache purge"), 40),
                       result(caches + "/com.example", .remove, 10)]
        let safe = StatusSnapshot.safeSuggestions(cleanup) { item in
            PlanItem(name: item.target.name, path: item.target.path, bytes: item.bytes, action: item.target.action!,
                     isDirectory: true, safety: .safe("test"), included: true)
        }
        #expect(safe.map(\.target.path) == [caches, caches + "/pip"])
    }
}

@Suite struct CommandFailureTests {
    @Test func missingToolsAreNamed() {
        let message = Cleaner.failure("pod cache clean --all", status: 127, output: "zsh:1: command not found: pod")
        #expect(message.contains("`pod` isn't installed"))
    }

    @Test func dockerNotRunningIsExplained() {
        let output = "Cannot connect to the Docker daemon at unix:///Users/me/.orbstack/run/docker.sock. Is the docker daemon running?"
        #expect(Cleaner.failure(Catalog.dockerPrune, status: 1, output: output) == "Docker isn't running. Open Docker Desktop or OrbStack, then try again.")
    }

    @Test func otherFailuresKeepTheToolsLastLine() {
        let message = Cleaner.failure("deno clean", status: 1, output: "\u{1B}]7;file://x\u{07}\nerror: something broke\n")
        #expect(message == "`deno clean` failed: error: something broke")
    }
}

@Suite struct LocalSnapshotTests {
    let listing = """
        Snapshots for volume group containing disk /:
        com.apple.TimeMachine.2026-09-27-093012.local
        com.apple.TimeMachine.2026-09-28-101510.local
        com.apple.os.update-5203530F8BB20B9DABC5CE76A0FFE87CCC885EE69B8A5488C24B458A7555E3AB
        """

    @Test func parsesTheListing() {
        let names = LocalSnapshots.parse(listing)
        #expect(names.count == 3)
        #expect(names.filter(LocalSnapshots.isTimeMachine).count == 2)
    }

    @Test func readsDatesFromNames() throws {
        let date = try #require(LocalSnapshots.date(of: "com.apple.TimeMachine.2026-09-28-101510.local"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second] == [2026, 9, 28, 10, 15, 10])
        #expect(LocalSnapshots.date(of: "com.apple.os.update-MSUPrepareUpdate") == nil)
        #expect(LocalSnapshots.date(of: "Snapshots for volume group containing disk /:") == nil)
    }

    @Test func countsWhatThinningRemoved() {
        let output = """
            Thinned local snapshots:
            2026-09-27-093012
            2026-09-28-101510
            """
        #expect(LocalSnapshots.parseThinned(output).count == 2)
        #expect(LocalSnapshots.parseThinned("Thinned local snapshots:\n").isEmpty)
    }

    @Test func saysWhenAnAdministratorIsNeeded() {
        let message = LocalSnapshots.failure("tmutil: thinlocalsnapshots requires root privileges.")
        #expect(message.contains("administrator"))
        #expect(LocalSnapshots.failure("Something else\n").hasSuffix(": Something else"))
    }

    @Test func outcomeMessagesArePlain() {
        #expect(LocalSnapshots.Outcome(thinned: 0, freed: 0, error: nil).message.contains("none could be removed"))
        #expect(LocalSnapshots.Outcome(thinned: 2, freed: 3 << 30, error: nil).message.hasPrefix("Removed 2 local snapshots."))
    }
}
