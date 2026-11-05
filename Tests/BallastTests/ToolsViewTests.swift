import Foundation
import Testing
@testable import Ballast

/// The figures the Tools screens (Homebrew, Health, Settings) show, worked
/// out from plain model values.
struct ToolsViewTests {
    private let prefix = "/opt/homebrew"

    private func item(_ path: String, _ bytes: Int64?) -> HomebrewCleanupPreview.Item {
        .init(path: path, bytes: bytes, files: nil)
    }

    @Test func extrasFiguresSplitOldVersionsFromDownloads() {
        let cleanup = HomebrewCleanupPreview(items: [
            item(prefix + "/Cellar/node/22.9.0", 200),
            item("/Users/me/Library/Caches/Homebrew/downloads/old.tar.gz", 10),
        ], bytes: 210)
        let full = HomebrewCleanupPreview(items: cleanup.items + [
            item(prefix + "/Caskroom/zoom/6.0", 50),
            item("/Users/me/Library/Caches/Homebrew/downloads/ffmpeg.tar.gz", 1_000),
            item("/Users/me/Library/Caches/Homebrew/broken-link", nil),
        ], bytes: 1_260)
        let figures = HomebrewExtrasFigures(orphans: ["libyaml"], oldVersions: cleanup, fullCleanup: full, prefix: prefix)

        #expect(figures.cleanupBytes == 210)
        #expect(figures.fullBytes == 1_260)
        #expect(figures.reclaimable == 1_260)
        #expect(figures.downloadBytes == 1_050)
        #expect(figures.oldVersionCount == 2)
        #expect(figures.downloadCount == 3)
        // Largest first; an item without a size goes last.
        #expect(figures.largest.first?.bytes == 1_000)
        #expect(figures.largest.last?.bytes == nil)
        #expect(!figures.isClear)
        #expect(figures.isKnown)
    }

    @Test func extrasFiguresBeforeAnythingIsKnown() {
        let figures = HomebrewExtrasFigures(orphans: nil, oldVersions: nil, fullCleanup: nil, prefix: prefix)
        #expect(!figures.isKnown)
        #expect(!figures.isClear)
        #expect(figures.reclaimable == 0)
        #expect(figures.downloadBytes == 0)
        #expect(figures.largest.isEmpty)
    }

    @Test func extrasFiguresAllClear() {
        let empty = HomebrewCleanupPreview(items: [], bytes: 0)
        let figures = HomebrewExtrasFigures(orphans: [], oldVersions: empty, fullCleanup: empty, prefix: prefix)
        #expect(figures.isClear)
        #expect(figures.reclaimable == 0)
    }

    @Test func extrasFiguresWithOnlyTheLighterPreview() {
        // The full cleanup preview hasn't come back yet: downloads aren't
        // known, so nothing is claimed for them.
        let cleanup = HomebrewCleanupPreview(items: [item(prefix + "/Cellar/node/22.9.0", 200)], bytes: 200)
        let figures = HomebrewExtrasFigures(orphans: nil, oldVersions: cleanup, fullCleanup: nil, prefix: prefix)
        #expect(figures.reclaimable == 200)
        #expect(figures.downloadBytes == 0)
        #expect(figures.oldVersionCount == 1)
    }

    @Test func autoCleanStatsCountEachKindOnce() {
        let artifacts = [
            Artifact(path: "/p/a/node_modules", kind: .nodeModules, bytes: 300, projectNewest: 0),
            Artifact(path: "/p/b/node_modules", kind: .nodeModules, bytes: 200, projectNewest: 0),
            Artifact(path: "/p/c/.next", kind: .next, bytes: 900, projectNewest: 0),
        ]
        let stats = AutoCleanStats(artifacts: artifacts, due: [artifacts[1]])

        #expect(stats.rows.count == ArtifactKind.allCases.count)
        // Kinds found on this Mac first, biggest first.
        #expect(stats.rows.first?.kind == .next)
        #expect(stats.rows.first?.found.count == 1)
        #expect(stats.rows.first?.found.bytes == 900)
        let node = stats.rows.first { $0.kind == .nodeModules }
        #expect(node?.found.count == 2)
        #expect(node?.found.bytes == 500)
        #expect(node?.due.count == 1)
        #expect(node?.due.bytes == 200)
        #expect(stats.dueCount == 1)
        #expect(stats.dueBytes == 200)
        #expect(stats.rows.dropFirst(2).allSatisfy { $0.found.count == 0 })
    }

    @Test func healthStatesKeepTheirShape() {
        #expect(StatusMark.State(HealthFinding.State.passed) == .passed)
        #expect(StatusMark.State(HealthFinding.State.attention) == .attention)
        #expect(StatusMark.State(HealthFinding.State.unavailable) == .unavailable)
        #expect(StatusMark.State(HealthFinding.State.information) == .information)
        // Every state reads without color: no two share a symbol.
        let symbols = StatusMark.State.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
    }
}
