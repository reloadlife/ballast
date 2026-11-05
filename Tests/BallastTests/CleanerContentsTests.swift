import Foundation
import Testing
@testable import Ballast

@Suite struct CleanerContentsTests {
    let nobody = AppInventory(running: [], installed: [])

    /// Under home: the cleaner refuses folders outside it.
    private func folder() throws -> URL {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "ballast-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "cache"), withIntermediateDirectories: true)
        return root
    }

    /// A child the user can't delete from: its own folder is read-only.
    private func lock(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: folder.appending(path: "file"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    }

    private func unlock(_ folder: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    }

    private func contents(_ path: String) -> PlanItem {
        PlanItem(name: "x", path: path, bytes: 1, action: .contents, isDirectory: true, safety: .safe("cache"), included: true)
    }

    @Test func protectedEntriesDoNotFailAnOtherwiseGoodClean() throws {
        let root = try folder()
        let cache = root.appending(path: "cache")
        let locked = cache.appending(path: "locked")
        defer { unlock(locked); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: cache.appending(path: "junk"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: cache.appending(path: "junk.tmp"))
        try lock(locked)

        let outcome = try #require(Cleaner.clean([contents(cache.path)], permanently: true, apps: nobody, protected: [],
                                                 stagingRoot: root.appending(path: "staging").path, cancel: CancelFlag()) { _, _ in }.first)
        #expect(outcome.succeeded)
        #expect(outcome.note?.contains("macOS protects") == true)
        #expect(!FileManager.default.fileExists(atPath: cache.appending(path: "junk").path))
        #expect(!FileManager.default.fileExists(atPath: cache.appending(path: "junk.tmp").path))
        #expect(FileManager.default.fileExists(atPath: locked.appending(path: "file").path))
    }

    @Test func aFolderWhereNothingCouldBeRemovedFails() throws {
        let root = try folder()
        let cache = root.appending(path: "cache")
        let locked = cache.appending(path: "locked")
        defer { unlock(locked); try? FileManager.default.removeItem(at: root) }
        try lock(locked)

        let outcome = try #require(Cleaner.clean([contents(cache.path)], permanently: true, apps: nobody, protected: [],
                                                 stagingRoot: root.appending(path: "staging").path, cancel: CancelFlag()) { _, _ in }.first)
        #expect(!outcome.succeeded)
        #expect(outcome.error?.contains("macOS protects") == true)
    }

    @Test func anAlreadyEmptyFolderIsNotAFailure() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = Cleaner.clean([contents(root.appending(path: "cache").path)], permanently: true, apps: nobody, protected: [],
                                    stagingRoot: root.appending(path: "staging").path, cancel: CancelFlag()) { _, _ in }
        #expect(outcome.first?.succeeded == true)
    }

    @Test func bigPermanentDeletesAreMovedAsideAndFinishInTheBackground() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "cache/big")
        try FileManager.default.createDirectory(at: target.appending(path: "inner"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: target.appending(path: "inner/blob"))
        let staging = root.appending(path: "staging")
        // Something an earlier run left behind is swept too.
        try FileManager.default.createDirectory(at: staging.appending(path: "leftover"), withIntermediateDirectories: true)
        let item = PlanItem(name: "big", path: target.path, bytes: 4096, action: .remove, isDirectory: true,
                            safety: .safe("cache"), included: true)

        let outcome = try #require(Cleaner.clean([item], permanently: true, apps: nobody, protected: [], stagingThreshold: 0,
                                                 stagingRoot: staging.path, cancel: CancelFlag()) { _, _ in }.first)
        #expect(outcome.succeeded)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty)
    }

    @Test func foldersHoldingLinkedWorktreesAreLeftToGit() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appending(path: "cache/worktrees")
        try FileManager.default.createDirectory(at: container.appending(path: "repo/feature"), withIntermediateDirectories: true)
        try Data("gitdir: /somewhere/.git/worktrees/feature\n".utf8).write(to: container.appending(path: "repo/feature/.git"))
        #expect(Cleaner.linkedWorktree(in: container.path) == "repo/feature")
        // A repository's own .git folder isn't a linked worktree.
        #expect(Cleaner.linkedWorktree(in: container.appending(path: "repo/feature").path) == nil)

        let item = PlanItem(name: "worktrees", path: container.path, bytes: 1, action: .remove, isDirectory: true,
                            safety: .safe("cache"), included: true)
        let outcome = Cleaner.clean([item], permanently: true, apps: nobody, protected: [],
                                    stagingRoot: root.appending(path: "staging").path, cancel: CancelFlag()) { _, _ in }
        #expect(outcome.first?.succeeded == false)
        #expect(FileManager.default.fileExists(atPath: container.appending(path: "repo/feature/.git").path))
    }

    @Test func aCancelledEmptyingIsNotReportedAsDone() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "cache")
        for name in ["a", "b", "c"] { try Data("x".utf8).write(to: cache.appending(path: name)) }
        let cancel = CancelFlag()
        // Cancelled once the item has started, as the user pressing Stop mid-clean.
        let outcome = try #require(Cleaner.clean([contents(cache.path)], permanently: true, apps: nobody, protected: [],
                                                 stagingRoot: root.appending(path: "staging").path, cancel: cancel) { _, _ in cancel.set() }.first)
        #expect(!outcome.succeeded)
        #expect(outcome.error?.contains("Stopped") == true)
        #expect(FileManager.default.fileExists(atPath: cache.appending(path: "a").path))
    }

    @Test func commandsReportAMissingTool() {
        #expect(Cleaner.missingTool("ballast-no-such-tool cleanup", path: "/usr/bin:/bin") != nil)
        #expect(Cleaner.missingTool("true", path: "/usr/bin:/bin") == nil)
    }
}

@Suite struct WorktreeVerdictTests {
    private func worktree(_ path: String, branch: String? = "refs/heads/feature") -> GitWorktree {
        GitWorktree(path: path, head: "abc", branch: branch, isMain: false, locked: false, prunable: false)
    }

    @Test func buildOutputDoesNotBlockRemovalButOtherIgnoredFilesDo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ballast-tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("web/node_modules"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("web/package.json"))
        let tree = worktree(root.path)

        #expect(GitWorktrees.ignoredKeepers("web/node_modules/\0.DS_Store\0web/.DS_Store\0", root: root.path).isEmpty)
        #expect(GitWorktrees.verdict(tree, status: "", ignored: "web/node_modules/\0", detachedRefs: nil) == nil)
        #expect(GitWorktrees.ignoredKeepers("web/node_modules/\0.env\0", root: root.path) == [".env"])
        #expect(GitWorktrees.verdict(tree, status: "", ignored: ".env\0", detachedRefs: nil)?.contains(".env") == true)
        // A folder that only looks like build output still counts.
        #expect(GitWorktrees.ignoredKeepers("notes/node_modules/\0", root: root.path) == ["notes/node_modules/"])
        #expect(GitWorktrees.verdict(tree, status: " M file\0", ignored: "", detachedRefs: nil) != nil)
    }

    @Test func detachedCommitsNeedARef() {
        let tree = worktree("/tmp/x", branch: nil)
        #expect(GitWorktrees.verdict(tree, status: "", ignored: "", detachedRefs: "") != nil)
        #expect(GitWorktrees.verdict(tree, status: "", ignored: "", detachedRefs: "refs/heads/main\n") == nil)
    }

    @Test func discoveredRepositoriesSkipToolsAndDependencies() {
        let home = "/Users/me"
        #expect(GitWorktrees.isCandidate("/Users/me/projects/app", home: home))
        #expect(!GitWorktrees.isCandidate("/Users/me/Library/Caches/thing", home: home))
        #expect(!GitWorktrees.isCandidate("/Users/me/.oh-my-zsh", home: home))
        #expect(!GitWorktrees.isCandidate("/Users/me/projects/app/node_modules/dep", home: home))
        #expect(!GitWorktrees.isCandidate("/opt/homebrew/Library/Taps/homebrew/homebrew-core", home: home))
    }
}

@Suite struct HealthParsingTests {
    private func check(_ suffix: String) throws -> SecurityCheck {
        try #require(SecurityCheck.all.first { $0.path.hasSuffix(suffix) })
    }

    @Test func everyFirewallStateIsUnderstood() throws {
        let firewall = try check("/socketfilterfw")
        #expect(HealthChecks.security(firewall, output: "Firewall is enabled. (State = 1)\n").state == .passed)
        let strict = HealthChecks.security(firewall, output: "Firewall is blocking all non-essential incoming connections. (State = 2)")
        #expect(strict.state == .passed)
        #expect(strict.detail.contains("blocks all incoming"))
        #expect(HealthChecks.security(firewall, output: "Firewall is disabled. (State = 0)").state == .attention)
        #expect(HealthChecks.security(firewall, output: "garbled").state == .unavailable)
    }

    @Test func encryptionInProgressIsInformationNotAFailure() throws {
        let fileVault = try check("/fdesetup")
        let finding = HealthChecks.security(fileVault, output: "FileVault is Off.\nEncryption in progress: Percent completed = 42.0\n")
        #expect(finding.state == .information)
        #expect(HealthChecks.security(fileVault, output: "FileVault is On.\n").state == .passed)
    }

    @Test func theReportKeepsItsOrderWhateverFinishesFirst() {
        func finding(_ id: String) -> HealthFinding { .init(id: id, title: id, state: .passed, detail: "", source: "") }
        var report = LocalHealthReport()
        report.insert(HealthUpdate(storage: false, order: 2, findings: [finding("firewall")]))
        report.insert(HealthUpdate(storage: false, order: 0, findings: [finding("filevault")]))
        report.insert(HealthUpdate(storage: true, order: 1, findings: [finding("capacity")]))
        report.insert(HealthUpdate(storage: true, order: 0, findings: [finding("disk0-smart"), finding("disk0-wear")]))
        #expect(report.security.map(\.id) == ["filevault", "firewall"])
        #expect(report.storage.map(\.id) == ["disk0-smart", "disk0-wear", "capacity"])
        // A rerun replaces a check's rows instead of adding to them.
        report.insert(HealthUpdate(storage: false, order: 0, findings: [finding("filevault")]))
        #expect(report.security.count == 2)
    }
}
