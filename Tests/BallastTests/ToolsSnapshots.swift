import AppKit
import SwiftUI
import Testing
@testable import Ballast

/// Renders the Tools track's pieces (Homebrew, Git worktrees, Health) with
/// fake data, light and dark. Runs only when BALLAST_SNAPSHOTS names an
/// output folder:
/// `BALLAST_SNAPSHOTS=/tmp/shots swift test --filter ToolsSnapshots`
/// Liquid Glass and native controls may not render; layout and color do.
@MainActor @Suite struct ToolsSnapshots {
    nonisolated static let folder = ProcessInfo.processInfo.environment["BALLAST_SNAPSHOTS"]

    static let prefix = "/opt/homebrew"

    static func package(_ name: String, _ installed: String, available: String? = nil, description: String,
                        bytes: Int64?, kind: BrewPackage.Kind = .formula, pinned: Bool = false,
                        orphaned: Bool = false, used: TimeInterval? = nil, old: [String] = []) -> BrewPackage {
        var package = BrewPackage(name: name, kind: kind, installed: installed, available: available ?? installed,
                                  description: description, outdated: available != nil, pinned: pinned)
        package.bytes = bytes
        package.lastUsed = used.map { Date(timeIntervalSinceNow: -$0) }
        package.orphaned = orphaned
        package.oldVersions = old
        package.oldVersionBytes = old.isEmpty ? nil : 412_000_000
        return package
    }

    static var packages: [BrewPackage] {
        [
            package("node", "22.11.0", available: "23.1.0", description: "Platform built on V8 to build network applications",
                    bytes: 214_000_000, old: ["22.9.0"]),
            package("ffmpeg", "7.1", description: "Play, record, convert, and stream audio and video", bytes: 98_400_000),
            package("visual-studio-code", "1.95.1", description: "Open-source code editor", bytes: 612_000_000,
                    kind: .cask, used: 3_600),
            package("python@3.11", "3.11.10", available: "3.11.11", description: "Interpreted, interactive, object-oriented programming language",
                    bytes: 88_000_000, pinned: true),
            package("libyaml", "0.2.5", description: "YAML Parser", bytes: 640_000, orphaned: true),
            package("homebrew/cask-fonts/font-inter", "4.0", description: "", bytes: nil, kind: .cask),
        ]
    }

    static var figures: HomebrewExtrasFigures {
        let cleanup = HomebrewCleanupPreview(items: [
            .init(path: prefix + "/Cellar/node/22.9.0", bytes: 212_000_000, files: 2_400),
            .init(path: prefix + "/Cellar/python@3.11/3.11.9", bytes: 84_000_000, files: 3_100),
            .init(path: NSHomeDirectory() + "/Library/Caches/Homebrew/downloads/old-wget.bottle.tar.gz", bytes: 1_400_000, files: nil),
        ], bytes: 297_400_000)
        var full = cleanup
        full.items.append(.init(path: NSHomeDirectory() + "/Library/Caches/Homebrew/downloads/ffmpeg--7.1.bottle.tar.gz",
                                bytes: 1_180_000_000, files: nil))
        full.bytes = 1_477_400_000
        return HomebrewExtrasFigures(orphans: ["libyaml", "gettext", "pcre2", "xz"], oldVersions: cleanup,
                                     fullCleanup: full, prefix: prefix)
    }

    @Test(.enabled(if: folder != nil)) func renderHomebrew() throws {
        let board = VStack(alignment: .leading, spacing: 28) {
            HomebrewExtrasPanel(figures: Self.figures,
                                state: HomebrewExtrasActivity(checkedAt: Date(timeIntervalSinceNow: -300)))
            HomebrewExtrasPanel(figures: HomebrewExtrasFigures(),
                                state: HomebrewExtrasActivity(isLoadingOrphans: true, isLoadingCleanup: true, canCancel: true))
            ToolOutcomeLine(failure: "brew cleanup couldn't remove a locked file.", command: "brew cleanup", dismiss: {})
            ChartSection(title: "Installed packages", note: "6 installed · 2 updates available · 1 unneeded.",
                         total: 1_012_000_000, padded: false) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        ToolActivityLine(activity: "Measuring package sizes…", canCancel: true)
                    }
                    .padding(Theme.Space.inset)
                    ToolHairline()
                    ForEach(Self.packages) { package in
                        if package.id != Self.packages.first?.id { ToolHairline().padding(.leading, Theme.Space.inset + 32) }
                        PackageRow(package: package, change: package.name == "ffmpeg" ? "Updating…" : nil, prefix: Self.prefix)
                    }
                }
            }
            ChartSection(title: "Installed packages", padded: false) {
                SkeletonRows(count: 3).padding(.horizontal, Theme.Space.inset)
            }
        }
        try Self.renderBoth(board, name: "tools-homebrew")
    }

    /// The states the main boards don't show: all clear, saved figures
    /// being rechecked, only downloads left, the list's empty states and
    /// the Settings status lines.
    @Test(.enabled(if: folder != nil)) func renderToolStates() throws {
        let clear = HomebrewExtrasFigures(orphans: [], oldVersions: HomebrewCleanupPreview(items: [], bytes: 0),
                                          fullCleanup: HomebrewCleanupPreview(items: [], bytes: 0), prefix: Self.prefix)
        let downloadsOnly = HomebrewExtrasFigures(
            orphans: [], oldVersions: HomebrewCleanupPreview(items: [], bytes: 0),
            fullCleanup: HomebrewCleanupPreview(items: [.init(path: NSHomeDirectory() + "/Library/Caches/Homebrew/downloads/a.bottle.tar.gz",
                                                              bytes: 320_000_000, files: nil)], bytes: 320_000_000),
            prefix: Self.prefix)
        let board = VStack(alignment: .leading, spacing: 28) {
            HomebrewExtrasPanel(figures: clear, state: HomebrewExtrasActivity(checkedAt: Date(timeIntervalSinceNow: -60)))
            HomebrewExtrasPanel(figures: Self.figures, state: HomebrewExtrasActivity(isLoadingCleanup: true, canCancel: true))
            HomebrewExtrasPanel(figures: downloadsOnly, state: HomebrewExtrasActivity())
            ChartSection(title: "Installed packages", padded: false) {
                EmptyChart(symbol: "magnifyingglass", title: "No matching packages",
                           message: "Nothing installed matches \u{201C}zz\u{201D} with an update waiting.") {
                    Button("Show All Packages") {}.buttonStyle(.glass)
                }
            }
            EmptyChart(symbol: "shippingbox", title: "Homebrew isn't installed",
                       message: "Ballast looks for brew in /opt/homebrew and /usr/local. Install it from brew.sh, then open this screen again.") {
                Link("Open brew.sh", destination: URL(string: "https://brew.sh")!)
            }
            VStack(alignment: .leading, spacing: 10) {
                StatusMark(state: .passed, title: "Full Disk Access is on")
                StatusMark(state: .attention, title: "Full Disk Access is off")
                StatusMark(state: .problem, title: "Couldn't read the login item status.")
                ToolOutcomeLine(failure: "Couldn't look for build folders: permission denied", dismiss: {})
            }
        }
        try Self.renderBoth(board, name: "tools-states")
    }

    @Test(.enabled(if: folder != nil)) func renderWorktrees() throws {
        func tree(_ name: String, main: Bool = false, locked: Bool = false, branch: String? = nil) -> GitWorktree {
            GitWorktree(path: NSHomeDirectory() + "/projects/ballast" + (main ? "" : "-" + name), head: "abc123",
                        branch: branch ?? "refs/heads/" + name, isMain: main, locked: locked, prunable: false)
        }
        let rows: [(GitWorktree, DeveloperToolsModel.WorktreeState)] = [
            (tree("main", main: true), .blocked("The main working tree stays in place. Use Clean Build Files to reclaim generated files.")),
            (tree("feature-dock"), .removable),
            (tree("spike"), .checking),
            (tree("wip", locked: true), .blocked("Locked by Git. Unlock it in your terminal after reviewing why it was locked.")),
            (tree("old-release"), .removing),
        ]
        let board = VStack(alignment: .leading, spacing: 28) {
            ToolActivityLine(activity: "Checking 2 worktrees…", canCancel: true)
            ToolOutcomeLine(message: "Worktree removed. Its branch and commits were kept.", dismiss: {})
            ChartSection(title: "ballast", note: "5 worktrees · ~/projects/ballast", padded: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.0.id) { row in
                        if row.0.id != rows.first?.0.id { ToolHairline().padding(.leading, Theme.Space.inset + 32) }
                        WorktreeRow(tree: row.0, state: row.1)
                    }
                }
            }
            EmptyChart(symbol: "point.3.connected.trianglepath.dotted", title: "Choose a Git repository",
                       message: "Add a folder, including one outside your home folder. Repositories in the disk index show up here on their own.") {
                Button("Add Repository…") {}.buttonStyle(.ink)
            }
        }
        try Self.renderBoth(board, name: "tools-worktrees")
    }

    @Test(.enabled(if: folder != nil)) func renderHealth() throws {
        var report = LocalHealthReport()
        report.insert(HealthUpdate(storage: true, order: 0, findings: [
            HealthFinding(id: "smart", title: "APPLE SSD AP1024Z", state: .passed, detail: "SMART status: Verified.", source: "diskutil info"),
            HealthFinding(id: "free", title: "Startup disk space", state: .attention,
                          detail: "8.2 GB free of 994 GB. macOS needs room for updates and swap.", source: "statfs"),
            HealthFinding(id: "wear", title: "SSD endurance", state: .unavailable,
                          detail: "macOS doesn't report wear for this drive.", source: "smartctl not installed"),
        ]))
        report.insert(HealthUpdate(storage: false, order: 0, findings: [
            HealthFinding(id: "fv", title: "FileVault", state: .passed, detail: "FileVault is On.", source: "fdesetup status"),
            HealthFinding(id: "fw", title: "Firewall", state: .information, detail: "The firewall is off. Your router may already filter connections.",
                          source: "socketfilterfw"),
        ]))
        let matches = VulnerabilityReport(checked: 212, excluded: 14, matches: [
            VulnerabilityMatch(package: VulnerabilityPackage(name: "openssl@3", version: "3.3.1"), advisory: "CVE-2024-6119"),
            VulnerabilityMatch(package: VulnerabilityPackage(name: "curl", version: "8.9.0"), advisory: "CVE-2024-8096"),
        ])
        let board = VStack(alignment: .leading, spacing: 28) {
            HealthSummary(report: report, isChecking: false)
            HealthSummary(report: nil, isChecking: true)
            HealthFindingsSection(title: "Storage health", note: "SMART can't predict every failure. Keep a current backup.",
                                  findings: report.storage, pending: 0) {
                Button("Open Disk Utility") {}
            }
            HealthFindingsSection(title: "Mac security", note: "FileVault, System Integrity Protection, Gatekeeper and the firewall.",
                                  findings: report.security, pending: 2)
            HealthFindingsSection(title: "Mac security", note: "Not run yet.", findings: nil, pending: 0)
            ChartSection(title: "Known vulnerabilities") {
                VStack(alignment: .leading, spacing: 14) {
                    VulnerabilityResults(report: matches)
                    ToolHairline()
                    VulnerabilityResults(report: VulnerabilityReport(checked: 212, excluded: 14, matches: []))
                    StatusMark(state: .problem, title: "The online check was stopped. Nothing more was sent.")
                }
            }
            HStack(spacing: 18) {
                ForEach(StatusMark.State.allCases, id: \.self) { StatusMark(state: $0, title: $0.spoken) }
            }
        }
        try Self.renderBoth(board, name: "tools-health")
    }

    static func renderBoth(_ board: some View, name: String) throws {
        let page = board
            .padding(32)
            .frame(width: 820)
            .background(Theme.water)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try ComponentSnapshots.render(page, name: "\(name)-\(appearance == .aqua ? "light" : "dark")", appearance: appearance)
        }
    }
}
