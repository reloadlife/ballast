import Foundation

/// Folders where coding agents and editors check out a Git worktree per
/// task: ~/.codex/worktrees, ~/.t3/worktrees, <repo>/.claude/worktrees. Each
/// checkout carries its own dependencies and build output, and agents rarely
/// remove them, so they pile up. Git marks a worktree with a `.git` *file*,
/// which the index (folders only) can't see; the folder holding them can.
enum AgentWorktrees {
    /// Tool folders whose `worktrees` folder holds checkouts. A repository's
    /// own `.git/worktrees` is Git's bookkeeping and never matches.
    static let tools: [String: String] = [
        ".claude": "Claude Code", ".codex": "Codex", ".cursor": "Cursor", ".t3": "T3 Code",
        ".grok": "Grok", ".superset": "Superset", "superpowers": "Superpowers", ".conductor": "Conductor",
        ".windsurf": "Windsurf", ".gemini": "Gemini", ".opencode": "opencode", ".kiro": "Kiro",
    ]

    static func results(_ db: IndexDB, atLeast floor: Int64 = 10 << 20) -> [ScanResult] {
        guard let rows = try? db.rows(named: ["worktrees"]) else { return [] }
        return rows.compactMap { row in
            guard row.total >= floor, row.err == 0, let parentID = row.parent,
                  let parent = try? db.row(parentID), let tool = tools[parent.name],
                  let path = try? db.path(of: row.id) else { return nil }
            let display = Paths.display(path)
            let project = (display as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            // A repository's .claude/worktrees: name it after the repository.
            let owner = (project as NSString).deletingLastPathComponent
            let name = owner == "~" || owner == "/" ? "\(tool) worktrees" : "\(tool) worktrees in \((owner as NSString).lastPathComponent)"
            return ScanResult(target: Target(name: name, path: display, category: .developer, action: nil),
                              bytes: row.total, newest: row.newest)
        }
    }
}
