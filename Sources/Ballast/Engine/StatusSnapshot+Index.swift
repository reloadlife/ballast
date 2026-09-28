import BallastCore
import Foundation
import WidgetKit

/// Building snapshots from the index. Kept apart from StatusSnapshot.swift,
/// which has to compile without the rest of Ballast.
extension StatusSnapshot {
    /// The Overview storage bar: Applications, the home folder split into
    /// caches, build files and the rest, and System Data as everything else
    /// that's used. `cleanup` is the Suggestions list.
    static func segments(overview: Overview, cleanup: [ScanResult], used: Int64) -> [Segment] {
        let apps = overview.top.first { $0.name == "Applications" }?.total ?? 0
        let homePath = NSHomeDirectory() + "/"
        func inHome(_ category: Category) -> Int64 {
            cleanup.filter { $0.target.category == category && $0.target.path.hasPrefix(homePath) }
                .reduce(0) { $0 + $1.bytes }
        }
        let homeTotal = overview.home?.total ?? 0
        let caches = min(inHome(.caches), homeTotal)
        let builds = min(inHome(.artifacts), homeTotal - caches)
        let home = homeTotal - caches - builds
        // Same definition as the System Data sheet: everything used that
        // isn't Applications or your home folder.
        let system = max(used - apps - homeTotal, 0)
        return [
            Segment(kind: .applications, bytes: apps),
            Segment(kind: .yourFiles, bytes: home),
            Segment(kind: .caches, bytes: caches),
            Segment(kind: .buildFiles, bytes: builds),
            Segment(kind: .system, bytes: system),
        ].filter { $0.bytes > 0 }
    }

    /// What "Add All Safe Items" would clean: caches and build files whose
    /// list item is ready, outermost first, nested items counted once.
    static func safeSuggestions(_ cleanup: [ScanResult], item: (ScanResult) -> PlanItem?) -> [ScanResult] {
        let candidates = cleanup
            .filter { $0.target.category.isReclaimable }
            .sorted { $0.target.path < $1.target.path }
        var kept: [ScanResult] = []
        for result in candidates where !kept.contains(where: {
            Catalog.covers($0.target.path, action: $0.target.action ?? .remove, result.target.path)
        }) {
            if let item = item(result), item.isReady { kept.append(result) }
        }
        return kept
    }

    /// A snapshot of the index and the volume right now, for command-line
    /// runs. Without an index only the free-space figures are refreshed.
    @MainActor
    static func rebuild() {
        guard let volume = Volume.capacity else { return }
        guard FileManager.default.fileExists(atPath: Paths.index),
              let db = try? IndexDB(path: Paths.index, mode: .read),
              let overview = IndexReader.overview(db) else {
            refreshVolume()
            return
        }
        let preferences = Preferences.load()
        let cleanup = IndexReader.cleanup(db, staleMonths: preferences.staleMonths, artifacts: ArtifactScanner.scan(db))
        let apps = AppInventory.current()
        let safe = safeSuggestions(cleanup) {
            PlanItem.assess($0, apps: apps, protected: preferences.protectedFolders)
        }
        StatusSnapshot(
            date: .now,
            volumeName: Paths.volumeName,
            totalBytes: volume.total,
            freeBytes: volume.free,
            segments: segments(overview: overview, cleanup: cleanup, used: max(volume.total - volume.free, 0)),
            safeToClean: safe.reduce(0) { $0 + $1.bytes },
            freedLastWeek: History.freed(in: History.load()),
            scannedAt: overview.scannedAt
        ).publish()
    }

    /// Cheap refresh: a new free-space reading on top of the last snapshot
    /// (or a bare one if there's none yet). Returns what was saved.
    @discardableResult
    static func refreshVolume() -> StatusSnapshot? {
        guard let volume = Volume.capacity else { return nil }
        let snapshot = load()?.updating(free: volume.free, total: volume.total)
            ?? StatusSnapshot(date: .now, volumeName: Paths.volumeName, totalBytes: volume.total,
                              freeBytes: volume.free, segments: [], safeToClean: 0,
                              freedLastWeek: History.freed(in: History.load()), scannedAt: nil)
        snapshot.publish()
        return snapshot
    }

    /// Saves status.json and has the widget redraw from it. Every write goes
    /// through here, the command-line runs' included, so the widget never
    /// waits for its half-hourly refresh to show new figures.
    func publish() {
        save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// For command-line runs, which exit right after publishing: the reload
    /// request is fire-and-forget, and exiting at once drops it. Waits (two
    /// seconds at most) for a reply on the same WidgetKit connection, which
    /// comes only after the request ahead of it was delivered.
    static func waitForWidgetReload() {
        let replied = DispatchSemaphore(value: 0)
        WidgetCenter.shared.getCurrentConfigurations { _ in replied.signal() }
        let deadline = Date.now.addingTimeInterval(2)
        while replied.wait(timeout: .now()) == .timedOut, Date.now < deadline {
            RunLoop.main.run(until: .now.addingTimeInterval(0.05))
        }
    }
}
