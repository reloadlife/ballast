import Foundation
import Testing
@testable import Ballast

@Suite struct DeveloperToolsTests {
    @Test func brewInventoryAndArguments() throws {
        let json = #"{"formulae":[{"name":"same","full_name":"team/tap/same","desc":"A tool","installed":[{"version":"1"},{"version":"2"}],"versions":{"stable":"3"},"outdated":true,"pinned":true}],"casks":[{"token":"same","full_token":"same","installed":"2","version":"2","desc":null,"outdated":false}]}"#
        let packages = try Homebrew.parse(Data(json.utf8))
        let formula = try #require(packages.first { $0.kind == .formula })
        #expect(formula.installed == "1, 2")
        #expect(formula.available == "3")
        #expect(formula.pinned && formula.outdated)
        #expect(Set(packages.map(\.id)).count == 2)
        #expect(Homebrew.arguments("upgrade", package: formula) == ["upgrade", "--formula", "--", "team/tap/same"])
        #expect(throws: (any Error).self) { try Homebrew.parse(Data("{}".utf8)) }
    }

    @Test func packageSortingKeepsUnknownValuesLast() {
        func package(_ name: String, size: Int64?, used: Double?) -> BrewPackage {
            BrewPackage(name: name, kind: .formula, installed: "1", available: "1", description: "",
                        outdated: false, pinned: false, bytes: size, lastUsed: used.map { Date(timeIntervalSince1970: $0) })
        }
        let packages = [package("unknown", size: nil, used: nil), package("big", size: 900, used: 200),
                        package("small", size: 10, used: 100), package("zero", size: 0, used: nil)]
        #expect(BrewPackage.sorted(packages, by: .size).map(\.name) == ["big", "small", "zero", "unknown"])
        #expect(BrewPackage.sorted(packages, by: .oldestUse).map(\.name) == ["small", "big", "unknown", "zero"])
        #expect(BrewPackage.sorted(packages, by: .newestUse).map(\.name) == ["big", "small", "unknown", "zero"])
        #expect(BrewPackage.sorted(packages, by: .name).map(\.name) == ["big", "small", "unknown", "zero"])
    }

    @Test func caskAppsRespectCustomInstallLocationsAndDeduplicateVersions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ballast-cask-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("custom-apps/Example.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let storage = root.appendingPathComponent("Caskroom/example")
        for version in ["1", "2"] {
            let folder = storage.appendingPathComponent(version)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Example.app"), withDestinationURL: app)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Missing.app"), withDestinationURL: root.appendingPathComponent("missing"))
        }
        #expect(Homebrew.linkedApps(in: storage.path) == [Paths.canonical(app.path)])
    }

    @Test func porcelainPreservesUnusualPaths() {
        let records = "worktree /tmp/main\0HEAD abc\0branch refs/heads/main\0\0worktree /tmp/a\nb \"c\"\0HEAD def\0detached\0locked reason\0\0worktree /tmp/gone\0HEAD ghi\0prunable gone\0\0"
        let trees = GitWorktrees.parse(records)
        #expect(trees.count == 3)
        #expect(trees[0].isMain)
        #expect(trees[1].path == "/tmp/a\nb \"c\"")
        #expect(trees[1].locked && trees[1].branch == nil)
        #expect(trees[2].prunable)
    }

    @Test func realWorktreesOutsideHomeStaySafe() throws {
        let root = URL(fileURLWithPath: "/private/tmp/ballast-git-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appending(path: "main").path
        _ = try ToolCommand.run("/usr/bin/git", ["init", "--initial-branch=main", repo])
        _ = try GitWorktrees.git(repo, ["config", "user.name", "Ballast Test"])
        _ = try GitWorktrees.git(repo, ["config", "user.email", "test@example.invalid"])
        _ = try GitWorktrees.git(repo, ["config", "commit.gpgsign", "false"])
        _ = try GitWorktrees.git(repo, ["config", "core.hooksPath", "/dev/null"])
        try Data("initial\n".utf8).write(to: URL(fileURLWithPath: repo + "/tracked"))
        try Data("ignored\n".utf8).write(to: URL(fileURLWithPath: repo + "/.gitignore"))
        _ = try GitWorktrees.git(repo, ["add", "."])
        _ = try GitWorktrees.git(repo, ["commit", "-m", "Initial"])
        let path = root.appending(path: "linked worktree\nwith newline").path
        _ = try GitWorktrees.git(repo, ["worktree", "add", "-b", "feature", path])
        let trees = try GitWorktrees.list(repo)
        let tree = try #require(trees.first { $0.path == path })
        #expect(!tree.path.hasPrefix(NSHomeDirectory()))
        #expect(try GitWorktrees.check(tree) == nil)
        #expect(throws: (any Error).self) { try GitWorktrees.remove(trees[0], repository: repo) }
        // Build cleanup works outside home and on the main working copy,
        // without offering ignored credentials or arbitrary ignored folders.
        try Data("ignored\nnode_modules/\nsecrets/\n".utf8).write(to: URL(fileURLWithPath: repo + "/.gitignore"))
        try Data("{}".utf8).write(to: URL(fileURLWithPath: repo + "/package.json"))
        for folder in ["node_modules", "secrets"] {
            try FileManager.default.createDirectory(atPath: repo + "/" + folder, withIntermediateDirectories: true)
            try Data("test".utf8).write(to: URL(fileURLWithPath: repo + "/" + folder + "/file"))
        }
        #expect(try GitWorktrees.buildFolders(trees[0]).map(\.lastPathComponent) == ["node_modules"])
        #expect(FileManager.default.fileExists(atPath: repo + "/secrets/file"))
        // Untracked and ignored files must survive even if the displayed row was clean.
        for name in ["untracked", "ignored", "tracked"] {
            let file = URL(fileURLWithPath: path + "/" + name)
            try Data("changed\n".utf8).write(to: file)
            #expect(try GitWorktrees.check(tree) != nil)
            #expect(throws: (any Error).self) { try GitWorktrees.remove(tree, repository: repo) }
            #expect(FileManager.default.fileExists(atPath: file.path))
            if name == "tracked" { _ = try GitWorktrees.git(path, ["restore", "tracked"]) }
            else { try FileManager.default.removeItem(at: file) }
        }
        _ = try GitWorktrees.git(repo, ["worktree", "lock", path])
        #expect(throws: (any Error).self) { try GitWorktrees.remove(tree, repository: repo) }
        _ = try GitWorktrees.git(repo, ["worktree", "unlock", path])
        // Unique commits on a branch are retained after removal.
        _ = try GitWorktrees.git(path, ["commit", "--allow-empty", "-m", "Feature work"])
        #expect(throws: (any Error).self) { try GitWorktrees.remove(tree, repository: repo) }
        let updated = try #require(GitWorktrees.list(repo).first { $0.path == path })
        try GitWorktrees.remove(updated, repository: repo)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try GitWorktrees.git(repo, ["rev-parse", "feature"]).trimmingCharacters(in: .whitespacesAndNewlines) == updated.head)
        // Unreferenced detached commits must not be abandoned.
        let detached = root.appending(path: "detached").path
        _ = try GitWorktrees.git(repo, ["worktree", "add", "--detach", detached])
        _ = try GitWorktrees.git(detached, ["commit", "--allow-empty", "-m", "Detached work"])
        let detachedTree = try #require(GitWorktrees.list(repo).first { $0.path == detached })
        #expect(try GitWorktrees.check(detachedTree) != nil)
        #expect(throws: (any Error).self) { try GitWorktrees.remove(detachedTree, repository: repo) }
        _ = try GitWorktrees.git(detached, ["branch", "saved-detached"])
        try GitWorktrees.remove(detachedTree, repository: repo)
    }

    @Test func commandHandlesLargeOutputAndFailure() throws {
        let output = try ToolCommand.run("/usr/bin/printf", ["%100000s", "x"])
        #expect(output.count == 100_000)
        #expect(throws: (any Error).self) { try ToolCommand.run("/usr/bin/git", ["ballast-not-a-command"]) }
    }
}
