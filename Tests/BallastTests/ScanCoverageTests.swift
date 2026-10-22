import Foundation
import Testing
@testable import Ballast

@Suite struct ScanCoverageTests {
    @Test func indexRefreshWaitsForAgeOrABigChange() {
        #expect(!IndexRefresh.isDue(age: 60, freeChange: 10 << 30))
        #expect(!IndexRefresh.isDue(age: 10 * 60, freeChange: 100 << 20))
        #expect(IndexRefresh.isDue(age: 10 * 60, freeChange: -(2 << 30)))
        #expect(IndexRefresh.isDue(age: 10 * 60, freeChange: 2 << 30))
        #expect(IndexRefresh.isDue(age: 45 * 60, freeChange: 0))
    }

    @Test func agentWorktreeFoldersAreListedButGitBookkeepingIsNot() throws {
        let root = URL(fileURLWithPath: Paths.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent("ballast-worktrees-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in [".codex/worktrees/abc/app", "repo/.claude/worktrees/task", "repo/.git/worktrees/task", "notes/worktrees/x"] {
            let url = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(count: 11 << 20).write(to: url.appendingPathComponent("data"))
        }
        let db = try IndexDB(path: root.appendingPathComponent("index.sqlite").path, mode: .build)
        try Walker.walk(Paths.onVolume(root.path)) { node in
            try db.upsert(id: node.local + 1, parent: node.parent < 0 ? nil : node.parent + 1, name: node.name, node: node)
        }
        try db.createIndexes()
        let results = AgentWorktrees.results(db)
        #expect(Set(results.map(\.target.path)) == [root.path + "/.codex/worktrees", root.path + "/repo/.claude/worktrees"])
        #expect(results.first { $0.target.path.hasSuffix("/repo/.claude/worktrees") }?.target.name == "Claude Code worktrees in repo")
        #expect(results.allSatisfy { $0.target.category == .developer && $0.target.action == nil })
    }

    @Test func containerDisksAreWhereTheToolsKeepThem() {
        let paths = Set(Catalog.targets.map(\.path))
        #expect(paths.contains(Catalog.home + "/Library/Group Containers/HUAQ24HBR6.dev.orbstack"))
        #expect(!paths.contains(Catalog.home + "/.orbstack"))
        #expect(paths.contains(Catalog.home + "/.colima"))
    }
}
