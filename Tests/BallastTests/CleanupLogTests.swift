import Foundation
import Testing
@testable import Ballast

@Suite struct InstallerTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ballast-installers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Zips `entries` (relative paths of empty files) with ditto, like Finder's Compress.
    private func zip(_ entries: [String], in root: URL, named name: String) throws -> String {
        let source = root.appending(path: "zip-source-\(name)")
        for entry in entries {
            let file = source.appending(path: entry)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }
        let output = root.appending(path: name).path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", source.path, output]
        try process.run()
        process.waitUntilExit()
        try FileManager.default.removeItem(at: source)
        return output
    }

    @Test func installerExtensionsAboveTheSizeFloor() {
        let big = Installers.minimumBytes
        for name in ["Foo.dmg", "Foo.PKG", "Foo.mpkg", "Xcode_26.xip"] {
            #expect(Installers.qualifies("/x/" + name, bytes: big), "\(name)")
            #expect(!Installers.qualifies("/x/" + name, bytes: big - 1), "\(name) is too small")
        }
        for name in ["Foo.iso", "Foo.app", "notes.txt", "Foo"] {
            #expect(!Installers.qualifies("/x/" + name, bytes: big * 10), "\(name)")
        }
    }

    @Test func zipsCountOnlyWithAnAppAtTheTop() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try zip(["Foo.app/Contents/Info.plist"], in: root, named: "app.zip")
        let nested = try zip(["docs/Foo.app/Contents/Info.plist"], in: root, named: "nested.zip")
        let plain = try zip(["docs/readme.txt", "setup.sh"], in: root, named: "plain.zip")
        #expect(Installers.zipHasApp(app))
        #expect(!Installers.zipHasApp(nested))
        #expect(!Installers.zipHasApp(plain))
        #expect(Installers.qualifies(app, bytes: Installers.minimumBytes))
        #expect(!Installers.qualifies(plain, bytes: Installers.minimumBytes))
        // Not a zip at all.
        let fake = root.appending(path: "fake.zip")
        try Data(repeating: 7, count: 4096).write(to: fake)
        #expect(!Installers.zipHasApp(fake.path))
    }

    @Test func installedOnlyWhenTheNameClearlyStartsWithTheApp() {
        let apps = ["Firefox", "Slack", "VLC", "Visual Studio Code", "Visual", "Go"]
        #expect(Installers.installedApp(named: "Firefox 130.0.dmg", among: apps) == "Firefox")
        #expect(Installers.installedApp(named: "vlc-3.0.21-arm64.dmg", among: apps) == "VLC")
        #expect(Installers.installedApp(named: "Visual Studio Code.zip", among: apps) == "Visual Studio Code")
        #expect(Installers.installedApp(named: "Slacker.dmg", among: apps) == nil)
        #expect(Installers.installedApp(named: "Setup.pkg", among: apps) == nil)
        // Too short to mean anything.
        #expect(Installers.installedApp(named: "Go 1.23.pkg", among: apps) == nil)
    }

    @Test func scansTwoLevelsAndSkipsSmallFilesAndPackages() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let big = Data(count: Int(Installers.minimumBytes) + 1)
        for dir in ["sub/deeper", "Foo.app/Contents"] {
            try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        try big.write(to: root.appending(path: "Firefox 130.dmg"))
        try big.write(to: root.appending(path: "sub/Tool.pkg"))
        try big.write(to: root.appending(path: "sub/deeper/Too Deep.dmg"))
        try big.write(to: root.appending(path: "Foo.app/Contents/Inside.dmg"))
        try Data(count: 1024).write(to: root.appending(path: "tiny.dmg"))
        try big.write(to: root.appending(path: "movie.mov"))

        let found = Installers.scan(folders: [root.path], apps: ["Firefox"])
        #expect(Set(found.map(\.name)) == ["Firefox 130.dmg", "Tool.pkg"])
        #expect(found.first { $0.name == "Firefox 130.dmg" }?.installedApp == "Firefox")
        #expect(found.first { $0.name == "Tool.pkg" }?.installedApp == nil)
        #expect(found.allSatisfy { $0.added != nil && $0.mountedAs == nil })
    }

    @Test func installersInHomeAreSafeToClean() {
        let safety = SafetyCheck.assess(NSHomeDirectory() + "/Downloads/Foo.dmg", isDirectory: false,
                                        apps: AppInventory(running: [], installed: []), protected: [])
        #expect(safety.level == .safe)
        #expect(safety.reason.contains("download it again"))
    }
}

@Suite struct TrashLogTests {
    private func log() -> TrashLog {
        TrashLog(url: FileManager.default.temporaryDirectory.appending(path: "ballast-log-\(UUID().uuidString).json"))
    }

    private func record(_ name: String, moves: [TrashMove] = []) -> CleanupRecord {
        CleanupRecord(permanent: moves.isEmpty, items: [.init(name: name, path: "/x/" + name, bytes: 10, moves: moves)])
    }

    @Test func keepsTheNewestTwenty() {
        let log = log()
        defer { try? FileManager.default.removeItem(at: log.url) }
        #expect(log.load().isEmpty)
        for i in 0..<25 { log.append(record("item\(i)")) }
        let records = log.load()
        #expect(records.count == 20)
        #expect(records.first?.items.first?.name == "item5")
        #expect(records.last?.items.first?.name == "item24")
    }

    @Test func updatesARecordInPlace() {
        let log = log()
        defer { try? FileManager.default.removeItem(at: log.url) }
        var first = record("a", moves: [TrashMove(from: "/x/a", to: "/t/a")])
        log.append(first)
        log.append(record("b"))
        first.items[0].moves[0].restored = true
        log.update(first)
        let records = log.load()
        #expect(records.count == 2)
        #expect(records[0].items[0].moves[0].restored)
        #expect(records[0].wasPutBack)
    }
}

@Suite struct PutBackTests {
    /// A fake Trash beside the original, so nothing leaves the temp folder.
    private func setUp() throws -> (root: URL, trash: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "ballast-putback-\(UUID().uuidString)")
        let trash = root.appending(path: "Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return (root, trash)
    }

    @Test func putsBackAndRecreatesMissingParents() throws {
        let (root, trash) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("keep".utf8).write(to: trash.appending(path: "notes.txt"))
        let original = root.appending(path: "gone/parent/notes.txt").path
        var record = CleanupRecord(permanent: false, items: [.init(name: "notes", path: original, bytes: 4, moves: [
            TrashMove(from: original, to: trash.appending(path: "notes.txt").path),
        ])])
        #expect(record.canPutBack)

        let result = PutBack.run(&record)
        #expect(result.restored.count == 1)
        #expect(result.problems.isEmpty)
        #expect(try String(contentsOfFile: original, encoding: .utf8) == "keep")
        #expect(!record.canPutBack)
        #expect(record.wasPutBack)
    }

    @Test func neverOverwritesWhatTookItsPlace() throws {
        let (root, trash) = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        // node_modules was cleaned, then an install recreated it.
        try fm.createDirectory(at: trash.appending(path: "node_modules"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "app/node_modules/new"), withIntermediateDirectories: true)
        let original = root.appending(path: "app/node_modules").path
        let trashed = trash.appending(path: "node_modules").path
        // And one that was emptied from the Trash since.
        let emptied = TrashMove(from: root.appending(path: "app/dist").path, to: trash.appending(path: "dist").path)
        var record = CleanupRecord(permanent: false, items: [.init(name: "app", path: original, bytes: 1, moves: [
            TrashMove(from: original, to: trashed), emptied,
        ])])

        let result = PutBack.run(&record)
        #expect(result.restored.isEmpty)
        #expect(result.problems == [
            "A new node_modules exists there now, so it was left in the Trash.",
            "dist is no longer in the Trash.",
        ])
        #expect(fm.fileExists(atPath: trashed))
        #expect(fm.fileExists(atPath: original + "/new"))
        #expect(record.pending.map(\.to) == [trashed])
    }

    @Test func aRealTrashRoundTrip() throws {
        // The Cleaner's own path: into ~/.Trash, recorded, and back. Tiny
        // file in a test folder under home, removed afterwards.
        let parent = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "ballast-test-\(UUID().uuidString)")
        let file = parent.appending(path: "old.dmg")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("dmg".utf8).write(to: file)
        let item = PlanItem(name: "old.dmg", path: file.path, bytes: 3, action: .remove, isDirectory: false,
                            safety: .safe("test"), included: true)

        let outcome = try #require(Cleaner.clean([item], permanently: false, apps: AppInventory(running: [], installed: []),
                                                 protected: [], cancel: CancelFlag()) { _, _ in }.first)
        let move = try #require(outcome.moves.first)
        defer { try? FileManager.default.removeItem(atPath: move.to) }
        #expect(outcome.succeeded)
        #expect(move.from == file.path)
        #expect(move.to.hasPrefix(NSHomeDirectory() + "/.Trash/"))
        #expect(!FileManager.default.fileExists(atPath: file.path))

        var record = CleanupRecord(permanent: false, items: [.init(name: item.name, path: item.path, bytes: 3, moves: outcome.moves)])
        #expect(PutBack.run(&record).restored.count == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
