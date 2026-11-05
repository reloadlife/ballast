import BallastCore
import Foundation

/// What the Overview, the disk Overview and the menu bar read from the
/// model: computed only (AppModel's stored state is frozen for this track).
extension AppModel {
    /// What sits in ~/.Trash on the startup disk, as the index last
    /// measured it. Zero when it couldn't read it (the Trash needs Full Disk
    /// Access): the bar then shows no Trash band rather than a guess.
    var trashBytes: Int64 {
        overview?.homeChildren.first { $0.name == ".Trash" }?.total ?? 0
    }

    /// The startup disk's storage bands: the widget's categories with the
    /// Trash carved out of Your files. Filters the suggestions, so screens
    /// work it out when `depthKey` changes, not in a body.
    var depthSegments: [DepthBar.Segment] {
        guard let overview else { return [] }
        let snapshot = StatusSnapshot.segments(overview: overview, cleanup: startupCleanup, used: usedBytes)
        return DepthBar.segments(snapshot, trash: trashBytes)
    }

    /// Changes whenever `depthSegments` can: cheap to read in a body.
    var depthKey: DepthKey {
        DepthKey(scannedAt: overview?.scannedAt, root: overview?.root.total ?? 0, home: overview?.home?.total ?? 0,
                 trash: trashBytes, used: usedBytes, suggestions: startupCleanup.count)
    }

    struct DepthKey: Equatable, Sendable {
        let scannedAt: Date?
        let root: Int64
        let home: Int64
        let trash: Int64
        let used: Int64
        let suggestions: Int
    }

    /// Less than a tenth of the disk free: the one storage hazard the user
    /// can act on, drawn in chart magenta.
    var isLowOnSpace: Bool {
        totalBytes > 0 && freeBytes * 10 < totalBytes
    }

    /// A cleanup the user started is moving files right now: Clean Up or
    /// Empty Trash, not Put Back. Its run titles are "Cleaning…" and
    /// "Emptying the Trash"; Put Back's is "Putting back". Observable
    /// through `isScanning` and `status`, which change as runs start.
    var isDroppingBallast: Bool {
        guard isScanning, isCleaning, let title = status?.title else { return false }
        return title.hasPrefix("Cleaning") || title.hasPrefix("Emptying")
    }

    /// Each Cleanup List item's band, for the drop moment. Read when a
    /// cleanup starts, while the suggestions still list what it cleans.
    func depthCategories(of items: [PlanItem]) -> [String: DepthBar.Category] {
        guard !items.isEmpty else { return [:] }
        let wanted = Set(items.map(\.path))
        var suggested: [String: DepthBar.Category] = [:]
        for result in cleanup where wanted.contains(result.target.path) {
            switch result.target.category {
            case .caches: suggested[result.target.path] = .caches
            case .artifacts: suggested[result.target.path] = .build
            default: break
            }
        }
        var categories: [String: DepthBar.Category] = [:]
        for item in items {
            categories[item.path] = DepthBar.Category.of(path: item.path, home: Catalog.home, suggested: suggested[item.path])
        }
        return categories
    }

    /// The stage a finished cleanup plays, from its report. `known` is what
    /// `depthCategories(of:)` said when it started; anything missing is
    /// placed by its location.
    func dropStage(for report: CleanReport, known: [String: DepthBar.Category]) -> BallastDrop.Stage? {
        let emptied = report.outcomes.contains { $0.succeeded && $0.item.action == .emptyTrash }
        var bytes: [DepthBar.Category: Int64] = [:]
        for outcome in report.outcomes where outcome.succeeded && outcome.item.action != .emptyTrash {
            let category = known[outcome.item.path] ?? DepthBar.Category.of(path: outcome.item.path, home: Catalog.home)
            bytes[category, default: 0] += outcome.item.bytes
        }
        return BallastDrop.Stage.decide(movedToTrash: report.movedToTrash, freed: report.freed, emptiedTrash: emptied,
                                        dominant: BallastDrop.Stage.dominant(bytes))
    }

    /// The other drive's bands: build folders, the rest of its folders, and
    /// used space no folder holds (land: it can't be cleaned from here).
    /// Before a scan, used space is one band.
    func depthSegments(for disk: Disk) -> [DepthBar.Segment] {
        guard disk.isConnected, let mounted = disk.mounted else { return [] }
        let used = max(mounted.total - mounted.free, 0)
        return Self.diskSegments(used: used, folders: diskOverview?.root.total, builds: buildBytes(on: disk))
    }

    /// See `depthSegments(for:)`; plain values, for tests.
    nonisolated static func diskSegments(used: Int64, folders: Int64?, builds: Int64) -> [DepthBar.Segment] {
        guard let folders else { return used > 0 ? [DepthBar.Segment(category: .other, name: "Used", bytes: used)] : [] }
        let builds = min(max(builds, 0), folders)
        return [
            DepthBar.Segment(category: .build, bytes: builds),
            DepthBar.Segment(category: .yourFiles, name: "Folders", bytes: folders - builds),
            DepthBar.Segment(category: .system, name: "Not in folders", bytes: max(used - folders, 0)),
        ].filter { $0.bytes > 0 }
    }

    /// Rows' list items, assessed off the main thread with the current apps
    /// and protected folders (see `RowItems`).
    func resolve(_ requests: [RowRequest]) async -> RowItems {
        await RowItems.resolve(requests, apps: apps, protected: preferences.protectedFolders)
    }
}
