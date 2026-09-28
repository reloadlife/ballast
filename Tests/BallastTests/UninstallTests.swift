import Foundation
import Testing
@testable import Ballast

/// A throwaway Applications folder and Library, so uninstall rules can be
/// tested without touching real apps.
private struct Sandbox {
    let root: URL
    var locations: AppLocations { AppLocations(roots: [root.appending(path: "Applications").path], library: library) }
    var library: String { root.appending(path: "Library").path }

    init() throws {
        // Inside home: trashItem only works on the user's own volume areas.
        root = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "ballast-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Applications"), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func app(_ name: String, id: String, in folder: String = "Applications") throws -> String {
        let path = root.appending(path: "\(folder)/\(name).app").path
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        try (["CFBundleIdentifier": id] as NSDictionary).write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        return path
    }

    /// A folder (or, with `file`, a file) under the fake Library.
    @discardableResult
    func library(_ relative: String, file: Bool = false, container id: String? = nil) throws -> String {
        let path = library + "/" + relative
        let fm = FileManager.default
        if file {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        } else {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        if let id {
            try (["MCMMetadataIdentifier": id] as NSDictionary)
                .write(to: URL(fileURLWithPath: path + "/.com.apple.containermanagerd.metadata.plist"))
        }
        return path
    }
}

@Suite struct AppDataTests {
    let foo = "com.example.Foo"

    @Test func matchesExactBundleIDAndNameOnly() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let path = try box.app("Foo", id: foo)
        let expected = [
            try box.library("Containers/\(foo)"),
            try box.library("Application Support/\(foo)"),
            try box.library("Application Support/Foo"),
            try box.library("Caches/\(foo)"),
            try box.library("Preferences/\(foo).plist", file: true),
            try box.library("Saved Application State/\(foo).savedState"),
            try box.library("HTTPStorages/\(foo)"),
            try box.library("WebKit/\(foo)"),
        ]
        // Lookalikes: a longer id, a name with more words, a prefix.
        for lookalike in ["Containers/\(foo).helper", "Caches/\(foo)Bar", "Caches/com.example",
                          "Application Support/Foo Helper", "Application Support/Fo", "WebKit/\(foo).extra"] {
            try box.library(lookalike)
        }
        try box.library("Preferences/\(foo).extra.plist", file: true)

        let app = try #require(AppBundle.read(path, entitlements: false))
        let found = AppData.folders(for: app, others: [app], locations: box.locations, readContainerMetadata: false)
        #expect(Set(found) == Set(expected))
    }

    @Test func containersByMetadataOnlyWithAccessAndOnlyWhenTheGroupIsTheAppsAlone() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let uuid = try box.library("Containers/\(UUID().uuidString)", container: foo)
        try box.library("Containers/\(UUID().uuidString)", container: "com.example.Other")
        let own = try box.library("Group Containers/ABCDE12345.com.example.Foo", container: "ABCDE12345.com.example.Foo")
        // Declared by Foo, but also by Bar: shared, so it stays.
        try box.library("Group Containers/ABCDE12345.suite", container: "ABCDE12345.suite")
        // Named like Foo's, but the metadata says otherwise.
        try box.library("Group Containers/ABCDE12345.com.example.Foo.x", container: "ABCDE12345.com.example.Else")
        // No metadata at all: never matched by name.
        try box.library("Group Containers/group.com.example.Foo")

        let app = AppBundle(path: try box.app("Foo", id: foo), name: "Foo", bundleID: foo,
                            groups: ["ABCDE12345.com.example.Foo", "ABCDE12345.suite", "group.com.example.Foo"])
        let bar = AppBundle(path: try box.app("Bar", id: "com.example.Bar"), name: "Bar", bundleID: "com.example.Bar",
                            groups: ["ABCDE12345.suite"])

        let withAccess = AppData.folders(for: app, others: [app, bar], locations: box.locations, readContainerMetadata: true)
        #expect(Set(withAccess) == [uuid, own])
        // Without Full Disk Access, containers aren't opened at all.
        #expect(AppData.folders(for: app, others: [app, bar], locations: box.locations, readContainerMetadata: false).isEmpty)
    }

    @Test func sharedNamesDuplicateCopiesAndAppleAppsKeepTheirData() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.library("Caches/\(foo)")
        try box.library("Application Support/Notes")
        let app = try #require(AppBundle.read(try box.app("Foo", id: foo), entitlements: false))

        // Another copy of the same app still uses the data.
        let copy = AppBundle(path: "/elsewhere/Foo.app", name: "Foo", bundleID: foo, groups: [])
        #expect(AppData.folders(for: app, others: [app, copy], locations: box.locations, readContainerMetadata: false).isEmpty)

        // "Notes" is also another app's name: not provably this one's.
        let notes = try #require(AppBundle.read(try box.app("Notes", id: "com.example.Notes"), entitlements: false))
        let other = AppBundle(path: "/elsewhere/Notes.app", name: "Notes", bundleID: "org.other.Notes", groups: [])
        #expect(AppData.folders(for: notes, others: [notes, other], locations: box.locations, readContainerMetadata: false).isEmpty)

        let apple = try #require(AppBundle.read(try box.app("Pages", id: "com.apple.iWork.Pages"), entitlements: false))
        try box.library("Containers/com.apple.iWork.Pages")
        #expect(AppData.folders(for: apple, others: [apple], locations: box.locations, readContainerMetadata: false).isEmpty)
    }
}

@Suite struct AppScannerTests {
    @Test func findsAppsOneFolderDeepAndSkipsAliases() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let foo = try box.app("Foo", id: "com.example.Foo")
        let bar = try box.app("Bar", id: "com.example.Bar", in: "Applications/Vendor")
        try box.app("Deep", id: "com.example.Deep", in: "Applications/Vendor/Nested")
        try FileManager.default.createSymbolicLink(atPath: box.root.appending(path: "Applications/Alias.app").path,
                                                   withDestinationPath: foo)
        let found = AppScanner.bundles(in: box.locations.roots, entitlements: false).map(\.path)
        #expect(Set(found) == [foo, bar])
    }

    @Test func appleAppsOnlyWhenFromTheAppStore() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let system = try #require(AppBundle.read(try box.app("Chess", id: "com.apple.Chess"), entitlements: false))
        let store = try box.app("Keynote", id: "com.apple.iWork.Keynote")
        try FileManager.default.createDirectory(atPath: store + "/Contents/_MASReceipt", withIntermediateDirectories: true)
        let keynote = try #require(AppBundle.read(store, entitlements: false))
        let other = try #require(AppBundle.read(try box.app("Foo", id: "com.example.Foo"), entitlements: false))
        #expect(!AppScanner.isRemovable(system))
        #expect(AppScanner.isRemovable(keynote))
        #expect(AppScanner.isRemovable(other))
        #expect(!AppScanner.isRemovable(AppBundle(path: other.path, name: "Ballast", bundleID: "dev.mamad.Ballast", groups: [])))
    }

    @Test func unusedMeansSpotlightSaysSoOrNothingEverReadIt() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-300 * 86_400)
        let recent = now.addingTimeInterval(-10 * 86_400)
        #expect(AppScanner.isUnused(lastUsed: old, accessed: recent, installed: old, months: 6, now: now))
        #expect(!AppScanner.isUnused(lastUsed: recent, accessed: nil, installed: old, months: 6, now: now))
        // No Spotlight record: only when installed long ago and not read since.
        #expect(AppScanner.isUnused(lastUsed: nil, accessed: old, installed: old, months: 6, now: now))
        #expect(!AppScanner.isUnused(lastUsed: nil, accessed: recent, installed: old, months: 6, now: now))
        #expect(!AppScanner.isUnused(lastUsed: nil, accessed: nil, installed: recent, months: 6, now: now))
        #expect(!AppScanner.isUnused(lastUsed: nil, accessed: nil, installed: nil, months: 6, now: now))
        // A zip's 1980 placeholder date isn't a record of use.
        let placeholder = Date(timeIntervalSince1970: 315_532_800)
        #expect(!AppScanner.isUnused(lastUsed: placeholder, accessed: recent, installed: old, months: 6, now: now))
    }
}

@Suite struct UninstallSafetyTests {
    let id = "com.example.Foo"
    let nobody = AppInventory(running: [], installed: [])

    private func verdict(_ box: Sandbox, _ path: String, data: [String] = [], apps: AppInventory? = nil,
                         protected: [String] = []) -> Safety {
        SafetyCheck.uninstall(path, bundleID: id, data: data, apps: apps ?? nobody, protected: protected,
                              locations: box.locations)
    }

    @Test func anUnusedAppNeedsConfirmation() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let path = try box.app("Foo", id: id)
        let safety = verdict(box, path, data: [try box.library("Caches/\(id)")])
        #expect(safety.level == .caution)
        #expect(safety.reason.contains("Trash"))
    }

    @Test func aRunningAppMustQuitFirst() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let path = try box.app("Foo", id: id)
        let running = RunningApp(name: "Foo", bundleID: id, pid: 1, bundlePath: path)
        #expect(verdict(box, path, apps: AppInventory(running: [running], installed: [])).level == .quitFirst)
        // A helper from inside the bundle counts too.
        let helper = RunningApp(name: "Foo Helper", bundleID: "com.example.Foo.helper", pid: 2,
                                bundlePath: path + "/Contents/Library/LoginItems/Helper.app")
        #expect(verdict(box, path, apps: AppInventory(running: [helper], installed: [])).level == .quitFirst)
    }

    @Test func systemComponentsNeedTheAppsOwnUninstaller() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let path = try box.app("Foo", id: id)
        try FileManager.default.createDirectory(atPath: path + "/Contents/Library/SystemExtensions/com.example.Foo.ext.systemextension",
                                                withIntermediateDirectories: true)
        let safety = verdict(box, path)
        #expect(safety.level == .caution)
        #expect(safety.reason.contains("system components"))
    }

    @Test func appStoreAppsSayTheyCanBeReinstalled() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let path = try box.app("Foo", id: id)
        try FileManager.default.createDirectory(atPath: path + "/Contents/_MASReceipt", withIntermediateDirectories: true)
        #expect(verdict(box, path).reason.contains("App Store"))
    }

    @Test func appsThatNeedAnAdministratorAreSkipped() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let path = try box.app("Foo", id: id)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        let safety = verdict(box, path)
        #expect(safety.level == .blocked)
        #expect(safety.reason.contains("administrator"))
    }

    @Test func onlyAppsInApplicationsFoldersAndOnlyTheSameApp() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let elsewhere = try box.app("Foo", id: id, in: "Downloads")
        #expect(verdict(box, elsewhere).level == .blocked)
        // Replaced by a different app since it was added.
        let path = try box.app("Foo", id: "com.example.Impostor")
        #expect(verdict(box, path).level == .blocked)
    }

    @Test func dataOutsideTheLibraryOrProtectedBlocksTheUninstall() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let path = try box.app("Foo", id: id)
        #expect(verdict(box, path, data: [NSHomeDirectory() + "/Documents"]).level == .blocked)
        let support = try box.library("Application Support/Foo")
        #expect(verdict(box, path, data: [support], protected: [support]).level == .blocked)
    }

    @Test func appDataOutsideAnUninstallStaysProtected() {
        // The uninstall rules don't weaken the installed-app rule.
        let home = NSHomeDirectory()
        let apps = AppInventory(running: [], installed: [InstalledApp(name: "Foo", bundleID: id)])
        for path in ["/Library/Containers/\(id)", "/Library/Application Support/Foo", "/Library/Application Support/\(id)"] {
            #expect(SafetyCheck.assess(home + path, isDirectory: true, apps: apps, protected: []).level == .blocked)
        }
        #expect(SafetyCheck.assess(home + "/Library/Preferences/\(id).plist", isDirectory: false, apps: apps, protected: []).level == .blocked)
    }
}

@Suite struct UninstallCleanerTests {
    @Test func movesTheAppAndItsMatchedDataToTheTrashEvenWhenDeleting() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let id = "com.example.Foo"
        let path = try box.app("Foo", id: id)
        let cache = try box.library("Caches/\(id)")
        let prefs = try box.library("Preferences/\(id).plist", file: true)
        // Listed at the time, but no longer matched: a folder that now
        // belongs to an app of the same name.
        let support = try box.library("Application Support/Foo")
        try box.app("Foo", id: "org.other.Foo", in: "Applications/Other")

        let item = PlanItem(name: "Uninstall Foo", path: path, bytes: 3, action: .uninstall(bundleID: id, data: [cache, prefs, support]),
                            isDirectory: true, safety: .caution("test"), included: true)
        let outcome = try #require(Cleaner.clean([item], permanently: true, apps: AppInventory(running: [], installed: []),
                                                 protected: [], locations: box.locations, cancel: CancelFlag()) { _, _ in }.first)
        defer { for move in outcome.moves { try? FileManager.default.removeItem(atPath: move.to) } }

        #expect(outcome.succeeded)
        #expect(Set(outcome.moves.map(\.from)) == [path, cache, prefs])
        #expect(outcome.moves.allSatisfy { $0.to.hasPrefix(NSHomeDirectory() + "/.Trash/") })
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: support))
        #expect(outcome.note?.contains("Kept 1") == true)

        // And it all comes back.
        var record = CleanupRecord(permanent: true, items: [.init(name: item.name, path: path, bytes: 3, moves: outcome.moves)])
        let result = PutBack.run(&record)
        #expect(result.problems.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path + "/Contents/Info.plist"))
        #expect(FileManager.default.fileExists(atPath: prefs))
        #expect(!record.canPutBack)
    }

    @Test func aRunningAppIsLeftAlone() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let id = "com.example.Foo"
        let path = try box.app("Foo", id: id)
        let item = PlanItem(name: "Uninstall Foo", path: path, bytes: 1, action: .uninstall(bundleID: id, data: []),
                            isDirectory: true, safety: .caution("added while closed"), included: true)
        let running = AppInventory(running: [RunningApp(name: "Foo", bundleID: id, pid: 1, bundlePath: path)], installed: [])
        let outcome = Cleaner.clean([item], permanently: false, apps: running, protected: [], locations: box.locations,
                                    cancel: CancelFlag()) { _, _ in }
        #expect(outcome.first?.succeeded == false)
        #expect(FileManager.default.fileExists(atPath: path))
    }
}
