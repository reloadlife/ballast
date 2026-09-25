import AppKit
import Darwin
import Foundation
import Observation

struct Refusal: Identifiable {
    let id = UUID()
    let name: String
    let reason: String
}

/// What a finished cleanup did, shown in the Cleanup List.
struct CleanReport: Sendable {
    let outcomes: [CleanOutcome]
    /// Measured change in free space.
    let freed: Int64
    /// Bytes that went to the Trash and still take space until it's emptied.
    let movedToTrash: Int64

    var failures: [CleanOutcome] { outcomes.filter { !$0.succeeded } }
}

@MainActor
@Observable
final class AppModel {
    private(set) var overview: Overview?
    private(set) var cleanup: [ScanResult] = [] {
        didSet {
            groups = Dictionary(grouping: cleanup, by: \.target.category).mapValues { $0.sorted { $0.bytes > $1.bytes } }
            groupTotals = groups.mapValues { $0.reduce(0) { $0 + $1.bytes } }
            itemCache.removeAll()
        }
    }
    private(set) var hotspots: [Hotspot] = []
    private(set) var history: [HistoryPoint] = History.load()
    private(set) var status: ScanStatus?
    private(set) var errorMessage: String?
    private(set) var freeBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var hasFullDiskAccess = Access.hasFullDiskAccess

    /// Explorer state: breadcrumb from the root to the open folder, and its children.
    private(set) var trail: [DirRow] = []
    private(set) var children: [DirRow] = []


    /// The Cleanup List, in the order items were added.
    private(set) var plan: [PlanItem] = [] {
        didSet { plannedPaths = Set(plan.map(\.path)) }
    }
    private(set) var plannedPaths: Set<String> = []
    var isListShown = false
    private(set) var lastClean: CleanReport?
    /// Items still being measured after a drop.
    private(set) var measuring = 0
    /// Last item that couldn't be added, with why.
    private(set) var refusal: Refusal?

    var isScanning: Bool { status != nil }

    /// Files seen by the last full scan: lets a new full scan show a percentage.
    @ObservationIgnored private var expectedFiles: Int64 = 0

    /// 0...1 during a full scan when the previous scan's size is known.
    var progress: Double? {
        guard let walk = status?.walk, status?.title == "Scanning disk", expectedFiles > 0 else { return nil }
        return min(Double(walk.files) / Double(expectedFiles), 0.99)
    }

    /// One plain sentence about what the app is doing right now.
    var statusLine: String {
        if let status {
            if let progress { return "Scanning disk · \(Int(progress * 100))%" }
            return status.title
        }
        if let date = overview?.scannedAt {
            return "Updated \(date.formatted(.relative(presentation: .named)))"
        }
        return hasIndex ? "" : "Not scanned yet"
    }
    var hasIndex: Bool { overview != nil }
    var usedBytes: Int64 { max(totalBytes - freeBytes, 0) }
    var planBytes: Int64 { plan.reduce(0) { $0 + $1.bytes } }

    var reclaimable: Int64 {
        cleanup.filter { $0.target.category.isReclaimable }.reduce(0) { $0 + $1.bytes }
    }

    /// Suggestions grouped once per load, not on every redraw.
    private(set) var groups: [Category: [ScanResult]] = [:]
    private(set) var groupTotals: [Category: Int64] = [:]

    func cleanup(in category: Category) -> [ScanResult] { groups[category] ?? [] }
    func total(in category: Category) -> Int64 { groupTotals[category] ?? 0 }

    @ObservationIgnored private(set) var apps = AppInventory.current()
    /// Safety verdicts per path. Assessing touches the filesystem and the
    /// running-app list, so rows must never do it on every redraw.
    @ObservationIgnored private var itemCache: [String: PlanItem] = [:]
    @ObservationIgnored private let reader = IndexReader()
    @ObservationIgnored private var cancelFlag = CancelFlag()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var exploreRequest = 0
    @ObservationIgnored private var exploring = 0

    // MARK: Scanning

    func start() async {
        guard !started else { return }
        started = true
        watchApps()
        refreshVolume()
        await reload()
        // An index from an older version doesn't load; update() rebuilds it.
        if hasIndex || FileManager.default.fileExists(atPath: Paths.index) { await update() }
    }

    /// Replays the change log; falls back to a full scan when there is none.
    func update() async {
        await run("Checking what changed") { report, cancel in
            do {
                try ScanEngine.update(report: report, cancel: cancel)
            } catch ScanEngine.Failure.needsFullScan {
                try ScanEngine.fullScan(report: report, cancel: cancel)
            }
        }
    }

    func fullScan() async {
        await run("Scanning disk") { try ScanEngine.fullScan(report: $0, cancel: $1) }
    }

    /// Rewalks every locked folder as the current user; worth doing after
    /// Full Disk Access was granted.
    func rescanLocked() async {
        let paths = await reader.lockedPaths(permissionsOnly: false)
        guard !paths.isEmpty else { return }
        await run("Rescanning locked folders") {
            try ScanEngine.rescan(paths, title: "Rescanning locked folder", report: $0, cancel: $1)
        }
    }

    func rescanLockedAsAdmin() async {
        let paths = await reader.lockedPaths(permissionsOnly: true)
        guard !paths.isEmpty else { return }
        await run("Waiting for administrator password") { report, _ in
            let results = try AdminScan.run(paths: paths)
            report(ScanStatus(title: "Merging \(results.count) folders"))
            try ScanEngine.graft(results)
        }
    }

    func cancelScan() {
        cancelFlag.set()
    }

    @discardableResult
    private func run<T: Sendable>(
        _ title: String,
        _ work: @escaping @Sendable (StatusHandler, CancelFlag) throws -> T
    ) async -> T? {
        guard status == nil else { return nil }
        let flag = CancelFlag()
        cancelFlag = flag
        errorMessage = nil
        status = ScanStatus(title: title)

        let report: StatusHandler = { update in
            Task { @MainActor in
                if self.status != nil { self.status = update }
            }
        }
        var result: T?
        do {
            result = try await Task.detached(priority: .userInitiated) { try work(report, flag) }.value
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }

        status = nil
        refreshVolume()
        hasFullDiskAccess = Access.hasFullDiskAccess
        await reload()
        return result
    }

    // MARK: Cleanup list

    func isPlanned(_ path: String) -> Bool {
        plannedPaths.contains(path)
    }

    /// Safety of removing a path, using the current app snapshot.
    func safety(of path: String, isDirectory: Bool = true) -> Safety {
        SafetyCheck.assess(path, isDirectory: isDirectory, apps: apps)
    }

    /// Adds an item, or removes it if it's already on the list. Blocked
    /// items are refused and the reason is shown instead.
    func toggle(_ item: PlanItem) {
        if let index = plan.firstIndex(where: { $0.path == item.path }) {
            plan.remove(at: index)
            return
        }
        guard item.safety.level != .blocked else {
            refusal = Refusal(name: item.name, reason: item.safety.reason)
            return
        }
        // Adding a parent replaces queued items inside it; adding something
        // inside a queued folder is redundant.
        if plan.contains(where: { item.path.hasPrefix($0.path + "/") }) { return }
        plan.removeAll { $0.path.hasPrefix(item.path + "/") }
        plan.append(item)
        isListShown = true
    }

    func toggle(_ result: ScanResult) {
        if let item = listItem(for: result) { toggle(item) }
    }

    func listItem(for result: ScanResult) -> PlanItem? {
        guard let action = result.target.action else { return nil }
        return makeItem(name: result.target.name, path: result.target.path, bytes: result.bytes,
                        action: action, isDirectory: true)
    }

    /// List item for a folder shown in the Explorer (possibly blocked).
    func listItem(for row: DirRow) -> PlanItem? {
        guard let path = displayPath(of: row) else { return nil }
        return makeItem(name: row.name, path: path, bytes: row.total, action: .remove, isDirectory: true)
    }

    func listItem(for spot: Hotspot) -> PlanItem {
        makeItem(name: spot.row.name, path: spot.path, bytes: spot.row.total, action: .remove, isDirectory: true)
    }

    /// List item for a folder picked on the radar map.
    func makeListItem(name: String, path: String, bytes: Int64) -> PlanItem {
        makeItem(name: name, path: path, bytes: bytes, action: .remove, isDirectory: true)
    }

    private func makeItem(name: String, path: String, bytes: Int64, action: CleanAction, isDirectory: Bool) -> PlanItem {
        if let cached = itemCache[path], cached.bytes == bytes, cached.action == action { return cached }
        let item = assessItem(name: name, path: path, bytes: bytes, action: action, isDirectory: isDirectory)
        itemCache[path] = item
        return item
    }

    private func assessItem(name: String, path: String, bytes: Int64, action: CleanAction, isDirectory: Bool) -> PlanItem {
        let safety: Safety
        switch action {
        case .remove:
            safety = SafetyCheck.assess(path, isDirectory: isDirectory, apps: apps)
        case .contents:
            safety = .safe("Empties the folder. Anything belonging to an open app is kept.")
        case .emptyTrash:
            safety = .safe("Permanently deletes what's in the Trash.")
        case .command(let command):
            safety = .safe("Runs `\(command)`, the tool's own cleanup.")
        }
        return PlanItem(name: name, path: path, bytes: bytes, action: action, isDirectory: isDirectory,
                        safety: safety, included: safety.level == .safe)
    }

    /// Files and folders dropped in from Finder or picked in an open panel.
    func add(urls: [URL]) async {
        measuring += urls.count
        for url in urls {
            let path = url.standardizedFileURL.path
            // Folders the index already knows cost nothing to size; anything
            // else (files, unindexed places) is measured.
            let known = await reader.size(ofPath: path)
            let (bytes, isDirectory) = if let known { (known.bytes, true) }
                else { await Task.detached { Cleaner.measure(path) }.value }
            measuring -= 1
            guard !isPlanned(path) else { continue }
            toggle(makeItem(name: url.lastPathComponent, path: path, bytes: bytes, action: .remove, isDirectory: isDirectory))
        }
    }

    func setIncluded(_ item: PlanItem, _ included: Bool) {
        guard let index = plan.firstIndex(where: { $0.id == item.id }) else { return }
        plan[index].included = included
    }

    func removeFromPlan(_ item: PlanItem) {
        plan.removeAll { $0.id == item.id }
    }

    func clearPlan() {
        plan.removeAll()
        lastClean = nil
    }

    func dismissRefusal() {
        refusal = nil
    }

    /// Asks an app to quit normally (it can still ask to save documents).
    func quit(_ app: RunningApp) {
        NSRunningApplication(processIdentifier: app.pid)?.terminate()
    }

    /// Re-evaluates every item, e.g. after an app opened or quit.
    func refreshSafety() {
        apps = AppInventory.current()
        itemCache.removeAll()
        for index in plan.indices where plan[index].action == .remove {
            let old = plan[index].safety.level
            plan[index].safety = SafetyCheck.assess(plan[index].path, isDirectory: plan[index].isDirectory, apps: apps)
            if old != .safe && plan[index].safety.level == .safe { plan[index].included = true }
        }
    }

    private func watchApps() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSafety() }
            }
        }
    }

    var readyItems: [PlanItem] { plan.filter(\.isReady) }
    var readyBytes: Int64 { readyItems.reduce(0) { $0 + $1.bytes } }

    /// Cleans every ready item, then remeasures just the affected folders.
    func cleanPlan(permanently: Bool) async {
        refreshSafety()
        let items = readyItems
        guard !items.isEmpty else { return }
        let freeBefore = freeBytes
        let apps = self.apps
        lastClean = nil

        let outcomes = await run("Cleaning") { report, cancel -> [CleanOutcome] in
            let outcomes = Cleaner.clean(items, permanently: permanently, apps: apps, cancel: cancel) { index, item in
                report(ScanStatus(title: "Cleaning \(index + 1) of \(items.count)",
                                  walk: WalkProgress(path: item.path)))
            }
            var touched = outcomes.map { Paths.onVolume($0.item.path) }
            if !permanently || items.contains(where: { $0.action == .emptyTrash }) {
                touched.append(Paths.onVolume(NSHomeDirectory() + "/.Trash"))
            }
            try ScanEngine.rescan(touched, title: "Measuring", report: report, cancel: CancelFlag())
            return outcomes
        } ?? []

        let done = Set(outcomes.filter(\.succeeded).map(\.item.id))
        plan.removeAll { done.contains($0.id) }
        let trashed = permanently ? 0 : outcomes
            .filter { $0.succeeded && !$0.item.action.isAlwaysPermanent }
            .reduce(0) { $0 + $1.item.bytes }
        let freed = max(freeBytes - freeBefore, 0)
        lastClean = CleanReport(outcomes: outcomes, freed: freed, movedToTrash: trashed)
        history = History.record(free: freeBytes, freed: freed)
    }

    /// Follow-up for a Trash cleanup: empties the Trash for real.
    func emptyTrash() async {
        let trash = makeItem(name: "Trash", path: NSHomeDirectory() + "/.Trash",
                             bytes: lastClean?.movedToTrash ?? 0, action: .emptyTrash, isDirectory: true)
        let pending = plan.filter { $0.id != trash.id }
        plan = [trash]
        await cleanPlan(permanently: true)
        plan = pending + plan  // `plan` still holds the Trash item only if emptying failed
    }

    func dismissCleanReport() {
        lastClean = nil
    }

    // MARK: Explorer

    /// Opens a folder in the Explorer. The latest request wins, so a slow
    /// load can't overwrite a newer one.
    func open(_ id: Int64) {
        exploreRequest += 1
        let request = exploreRequest
        exploring += 1
        Task {
            defer { exploring -= 1 }
            let (trail, children) = await reader.explore(id)
            guard request == exploreRequest, !trail.isEmpty else { return }
            self.trail = trail
            self.children = children
        }
    }

    /// Opens a folder by display path, e.g. from a Cleanup row.
    func open(path: String) async {
        if let id = await reader.deepest(Paths.onVolume(path)) { open(id) }
    }

    /// Shows the disk root unless a folder is already open or on its way.
    func openRootIfIdle() {
        guard trail.isEmpty, exploring == 0, let root = overview?.root else { return }
        open(root.id)
    }

    func path(of id: Int64) async -> String? {
        await reader.path(of: id).map(Paths.display)
    }

    /// Display path of the open folder or one of its children.
    func displayPath(of row: DirRow) -> String? {
        guard let index = trail.firstIndex(where: { $0.id == row.id || $0.id == row.parent }) else { return nil }
        var names = trail[...index].map(\.name)
        if trail[index].id != row.id { names.append(row.name) }
        return Paths.display(names.joined(separator: "/"))
    }

    // MARK: Loading

    private func reload() async {
        // Remember the open folder by path: a full scan renumbers every row.
        var openPath: String?
        if let open = trail.last { openPath = await reader.path(of: open.id) }

        await reader.reopen()
        overview = await reader.overview()
        if let files = overview?.root.files, files > 0 { expectedFiles = files }

        hotspots = await reader.hotspots()
        cleanup = await reader.cleanup()
        if hasIndex { history = History.record(free: freeBytes) }

        if let openPath, let id = await reader.deepest(openPath) {
            open(id)
        } else {
            trail = []
            children = []
        }
    }

    private func refreshVolume() {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        freeBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
        totalBytes = Int64(values.volumeTotalCapacity ?? 0)
    }
}
