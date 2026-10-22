import Foundation
import Testing
@testable import Ballast

@Suite struct TemporarySuggestionsTests {
    @Test func recognizesOnlySpecificTemporaryKinds() {
        #expect(TemporarySuggestions.label(name: "go-build1234", area: "T") != nil)
        #expect(TemporarySuggestions.label(name: "go-build-my-source", area: "T") == nil)
        #expect(TemporarySuggestions.label(name: "bunx-501-next@latest", area: "T") != nil)
        #expect(TemporarySuggestions.label(name: "pixevel-deploy-example", area: "T") != nil)
        #expect(TemporarySuggestions.label(name: "Documents", area: "T") == nil)
        #expect(TemporarySuggestions.label(name: "clang", area: "C") != nil)
        #expect(TemporarySuggestions.label(name: "com.apple.service", area: "C") == nil)
        #expect(TemporarySuggestions.label(name: "com.google.Chrome.code_sign_clone", area: "X") != nil)
        #expect(TemporarySuggestions.label(name: "go-build1234", area: "X") == nil)
    }

    @Test func indexedSuggestionsExcludeUnrecognizedAndSmallFolders() throws {
        let root = URL(fileURLWithPath: Paths.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent("ballast-temp-index-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["go-build123", "go-build456", "personal"] {
            let folder = root.appendingPathComponent("T/" + name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: name == "go-build456" ? 10 : 11 << 20).write(to: folder.appendingPathComponent("data"))
        }
        let db = try IndexDB(path: root.appendingPathComponent("index.sqlite").path, mode: .build)
        try Walker.walk(Paths.onVolume(root.path)) { node in
            try db.upsert(id: node.local + 1, parent: node.parent < 0 ? nil : node.parent + 1, name: node.name, node: node)
        }
        try db.createIndexes()
        let results = TemporarySuggestions.results(db, root: root.path)
        #expect(results.count == 1)
        #expect(results.first?.target.path == root.path + "/T/go-build123")
        #expect(results.first?.target.category == .developer)
    }

    @Test func largeUnrecognizedItemsAndSharedTmpFoldersAreOffered() throws {
        let root = URL(fileURLWithPath: Paths.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent("ballast-temp-large-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for (folder, bytes) in [("user/T/project-copy", 21 << 20), ("user/T/small-copy", 11 << 20), ("user/C/big-cache", 21 << 20),
                                ("tmp/release-build", 21 << 20), ("tmp/scratch", 1 << 20)] {
            let url = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url.appendingPathComponent("data"))
        }
        let db = try IndexDB(path: root.appendingPathComponent("index.sqlite").path, mode: .build)
        try Walker.walk(Paths.onVolume(root.path)) { node in
            try db.upsert(id: node.local + 1, parent: node.parent < 0 ? nil : node.parent + 1, name: node.name, node: node)
        }
        try db.createIndexes()
        // Pretend the user root sits under /private/var/folders, as it does.
        #expect(root.path.hasPrefix("/private/var/folders/"))
        let results = TemporarySuggestions.results(db, root: root.path + "/user", shared: root.path + "/tmp", large: 20 << 20)
        #expect(Set(results.map(\.target.path)) == [root.path + "/user/T/project-copy", root.path + "/tmp/release-build"])
        #expect(results.allSatisfy { $0.target.category == .developer && $0.target.action == .remove })
    }

    @Test func sharedTmpOnlyOffersYourOwnItems() throws {
        let apps = AppInventory(running: [], installed: [])
        let mine = URL(fileURLWithPath: "/private/tmp/ballast-test-\(UUID())")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mine) }
        #expect(SafetyCheck.assess("/private/tmp", isDirectory: true, apps: apps, protected: []).level == .blocked)
        #expect(SafetyCheck.assess(mine.path, isDirectory: true, apps: apps, protected: []).level == .caution)
        #expect(SafetyCheck.assess("/private/tmp/ballast-missing-\(UUID())", isDirectory: true, apps: apps, protected: []).level == .blocked)
    }

    @Test func runtimeClonesAndSystemDataAreNotCleanable() {
        let apps = AppInventory(running: [], installed: [])
        for path in ["/var/db/powerlog", "/var/vm", "/private/var/db/powerlog", "/private/var/vm", "/private/var/folders/aa/user/X/com.google.Chrome.code_sign_clone"] {
            #expect(SafetyCheck.assess(path, isDirectory: true, apps: apps, protected: []).level == .blocked)
        }
    }

    @Test func temporaryFilesNeedExplicitReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ballast-temp-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SafetyCheck.assess(TemporarySuggestions.userRoot + "/T", isDirectory: true,
                                   apps: AppInventory(running: [], installed: []), protected: []).level == .blocked)
        let item = PlanItem.assess(name: "Temporary files", path: root.path, bytes: 100, action: .remove,
                                  isDirectory: true, apps: AppInventory(running: [], installed: []), protected: [])
        #expect(item.safety.level == .caution)
        #expect(!item.isReady)
        #expect(item.safety.reason.contains("Stop the related"))
    }
}
