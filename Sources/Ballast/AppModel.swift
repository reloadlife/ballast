import AppKit
import BallastCore
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
    /// This cleanup in the log, for Put Back.
    let record: CleanupRecord?

    var failures: [CleanOutcome] { outcomes.filter { !$0.succeeded } }
}

/// What Put Back did for one cleanup.
struct PutBackReport: Sendable {
    let recordID: UUID
    let restored: Int
    let problems: [String]
}

@MainActor
@Observable
final class AppModel {
    /// One model for every window, the menu bar item and the app delegate.
    static let shared = AppModel()

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
    /// A screen the main window should switch to, e.g. from the menu bar
    /// item; RootView clears it once shown.
    var requestedPane: Pane?
    private(set) var lastClean: CleanReport?
    /// Items still being measured after a drop.
    private(set) var measuring = 0
    /// Last item that couldn't be added, with why.
    private(set) var refusal: Refusal?
    /// The file or folder shown in Quick Look, from any screen.
    var quickLookURL: URL?
    /// Set by ⌘F; Explorer focuses its search field and clears it.
    var searchRequested = false

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

    /// What "Add All Safe Items" would actually clean right now: caches and
    /// build files that pass the safety check, nested items counted once.
    /// Kept in sync with the Clean Up button, so every screen shows one number.
    private(set) var reclaimable: Int64 = 0

    /// The suggestions behind `reclaimable`, outermost first.
    var safeSuggestions: [ScanResult] {
        StatusSnapshot.safeSuggestions(cleanup) { listItem(for: $0) }
    }

    private func recomputeReclaimable() {
        reclaimable = safeSuggestions.reduce(0) { $0 + $1.bytes }
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
    /// Set when the exclusion list changed during a scan: update once it ends.
    @ObservationIgnored private var needsUpdate = false

    // MARK: Preferences

    /// Settings shared with the command-line modes; saved as they change.
    var preferences = Preferences.load() {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save()
            if preferences.protectedFolders != oldValue.protectedFolders { refreshSafety() }
            if preferences.staleMonths != oldValue.staleMonths {
                Task {
                    cleanup = await reader.cleanup(staleMonths: preferences.staleMonths)
                    recomputeReclaimable()
                }
                Task { await loadUnusedApps() }
            }
            if preferences.excludedFolders != oldValue.excludedFolders { applyExclusions() }
            if preferences.lowSpaceAlert != oldValue.lowSpaceAlert {
                if preferences.lowSpaceAlert { Notify.requestPermission() }
                LowSpace.syncAgent(preferences)
            }
        }
    }

    /// Brings the index in line with the exclusion list: update() re-lists
    /// the parents of folders that were added or removed.
    private func applyExclusions() {
        guard FileManager.default.fileExists(atPath: Paths.index) else { return }
        if isScanning {
            needsUpdate = true
        } else {
            Task { await update() }
        }
    }

    /// Re-reads the Full Disk Access grant, e.g. after a trip to System Settings.
    func refreshAccess() {
        hasFullDiskAccess = Access.hasFullDiskAccess
    }

    func clearHistory() {
        History.clear()
        history = []
        GrowthStore.clear()
        growth = .empty
    }

    // MARK: Scanning

    func start() async {
        guard !started else { return }
        started = true
        watchApps()
        // Re-point the background agents at this copy of the app.
        if autoClean.background { syncBackgroundAgent() }
        LowSpace.syncAgent(preferences)
        if preferences.lowSpaceAlert { Notify.requestPermission() }
        refreshVolume()
        await reload()
        refreshFreeSpace()
        watchFreeSpace()
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
        if needsUpdate {
            needsUpdate = false
            Task { await update() }
        }
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
        // Adding a parent replaces queued items it cleans too; adding
        // something a queued item already cleans is redundant.
        if plan.contains(where: { Catalog.covers($0.path, action: $0.action, item.path) }) { return }
        plan.removeAll { Catalog.covers(item.path, action: item.action, $0.path) }
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

    /// "Uninstall Foo": the app and its data, always to the Trash.
    func listItem(for unused: UnusedApp) -> PlanItem {
        makeItem(name: "Uninstall \(unused.app.name)", path: unused.app.path, bytes: unused.bytes,
                 action: unused.action, isDirectory: true)
    }

    func listItem(for installer: Installer) -> PlanItem {
        makeItem(name: installer.name, path: installer.path, bytes: installer.bytes,
                 action: .remove, isDirectory: installer.isDirectory)
    }

    private func makeItem(name: String, path: String, bytes: Int64, action: CleanAction, isDirectory: Bool) -> PlanItem {
        if let cached = itemCache[path], cached.bytes == bytes, cached.action == action { return cached }
        let item = assessItem(name: name, path: path, bytes: bytes, action: action, isDirectory: isDirectory)
        itemCache[path] = item
        return item
    }

    private func assessItem(name: String, path: String, bytes: Int64, action: CleanAction, isDirectory: Bool) -> PlanItem {
        PlanItem.assess(name: name, path: path, bytes: bytes, action: action, isDirectory: isDirectory,
                        apps: apps, protected: preferences.protectedFolders)
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
        for index in plan.indices {
            let item = plan[index]
            let old = item.safety.level
            plan[index].safety = assessItem(name: item.name, path: item.path, bytes: item.bytes,
                                            action: item.action, isDirectory: item.isDirectory).safety
            if old != .safe && plan[index].safety.level == .safe { plan[index].included = true }
        }
        recomputeReclaimable()
        recomputeAutoCleanDue()
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

        let cleaned = await run("Cleaning") { report, cancel -> (outcomes: [CleanOutcome], record: CleanupRecord?) in
            let outcomes = Cleaner.clean(items, permanently: permanently, apps: apps, cancel: cancel) { index, item in
                report(ScanStatus(title: "Cleaning \(index + 1) of \(items.count)",
                                  walk: WalkProgress(path: item.path)))
            }
            // Logged before anything else can fail, so whatever reached the
            // Trash can always be put back.
            let record = CleanupRecord(outcomes: outcomes, permanent: permanently)
            if let record { TrashLog.standard.append(record) }
            var touched = outcomes.map { Paths.onVolume($0.item.path) }
            for outcome in outcomes {
                if case .uninstall(_, let data) = outcome.item.action { touched += data.map(Paths.onVolume) }
            }
            if outcomes.contains(where: { !$0.moves.isEmpty }) || items.contains(where: { $0.action == .emptyTrash }) {
                touched.append(Paths.onVolume(NSHomeDirectory() + "/.Trash"))
            }
            try? ScanEngine.rescan(touched, title: "Measuring", report: report, cancel: CancelFlag())
            return (outcomes, record)
        }
        let outcomes = cleaned?.outcomes ?? []

        let done = Set(outcomes.filter(\.succeeded).map(\.item.id))
        plan.removeAll { done.contains($0.id) }
        let trashed = outcomes
            .filter { $0.succeeded && !$0.moves.isEmpty }
            .reduce(0) { $0 + $1.item.bytes }
        let freed = max(freeBytes - freeBefore, 0)
        cleanupLog = TrashLog.standard.load()
        putBackReport = nil
        lastClean = CleanReport(outcomes: outcomes, freed: freed, movedToTrash: trashed, record: cleaned?.record)
        history = History.record(free: freeBytes, freed: freed)
        saveSnapshot()
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

    // MARK: Auto-clean

    /// Rules and the background toggle; saved as they change.
    var autoClean = AutoCleanSettings.load() {
        didSet {
            guard autoClean != oldValue else { return }
            autoClean.save()
            if autoClean.background && !oldValue.background { Notify.requestPermission() }
            syncBackgroundAgent()
            recomputeAutoCleanDue()
        }
    }
    /// Every confirmed build folder, for rule previews and grouping.
    private(set) var artifacts: [Artifact] = []
    private(set) var lastAutoClean: AutoCleanRun? = AutoCleanRun.last()

    /// What the current rules would clean right now: due by age and safe
    /// to remove, exactly what a run would pick. Recomputed only when the
    /// rules, the index or the running apps change, never per redraw.
    private(set) var autoCleanDue: [(Artifact, AutoCleanRule)] = []

    private func recomputeAutoCleanDue() {
        autoCleanDue = AutoClean.due(artifacts, settings: autoClean).filter { artifact, _ in
            makeItem(name: artifact.path, path: artifact.path, bytes: artifact.bytes,
                     action: .remove, isDirectory: true).safety.level == .safe
        }
    }

    func runAutoCleanNow() async {
        let apps = self.apps
        let run = await run("Auto-cleaning") { report, _ in
            try AutoClean.run(dryRun: false, apps: apps, report: report)
        }
        if let run {
            lastAutoClean = run
            history = History.load()
            cleanupLog = TrashLog.standard.load()
            saveSnapshot()
        }
    }

    // MARK: Put Back

    /// Recent cleanups, oldest first (trash-log.json).
    private(set) var cleanupLog: [CleanupRecord] = TrashLog.standard.load()
    /// The last Put Back's result, shown where it was asked for.
    private(set) var putBackReport: PutBackReport?
    var isHistoryShown = false

    /// The newest cleanup that still has something in the Trash to put back.
    var lastRestorable: CleanupRecord? {
        cleanupLog.last(where: \.canPutBack)
    }

    /// Re-reads the log, e.g. when the history opens: a background
    /// auto-clean may have added to it.
    func reloadCleanupLog() {
        cleanupLog = TrashLog.standard.load()
    }

    /// Moves a cleanup's items back from the Trash, then remeasures where
    /// they went.
    func putBack(_ id: UUID) async {
        putBackReport = nil
        let outcome = await run("Putting back") { report, cancel -> PutBackReport? in
            let log = TrashLog.standard
            guard var record = log.load().first(where: { $0.id == id }) else { return nil }
            let result = PutBack.run(&record)
            log.update(record)
            var touched = Set(result.restored.map { Paths.onVolume(($0.from as NSString).deletingLastPathComponent) })
            if !result.restored.isEmpty { touched.insert(Paths.onVolume(NSHomeDirectory() + "/.Trash")) }
            try ScanEngine.rescan(Array(touched), title: "Measuring", report: report, cancel: CancelFlag())
            return PutBackReport(recordID: id, restored: result.restored.count, problems: result.problems)
        }
        cleanupLog = TrashLog.standard.load()
        putBackReport = outcome ?? nil
    }

    func putBackLast() async {
        guard let record = lastRestorable else { return }
        await putBack(record.id)
    }

    // MARK: Unused apps & installers

    /// Apps not opened in `staleMonths`, biggest first.
    private(set) var unusedApps: [UnusedApp] = []
    /// Installers and disk images in Downloads, Desktop and Documents.
    private(set) var installers: [Installer] = []
    @ObservationIgnored private var appsRequest = 0

    /// Spotlight dates and signatures are read off the main thread; sizes
    /// come from the index, and whatever it doesn't hold (loose files like
    /// preferences) is measured.
    private func loadUnusedApps() async {
        appsRequest += 1
        let request = appsRequest
        let months = preferences.staleMonths
        let metadata = hasFullDiskAccess
        var found = await Task.detached(priority: .utility) {
            AppScanner.unused(months: months, readContainerMetadata: metadata)
        }.value
        for index in found.indices {
            found[index].appBytes = await size(of: found[index].app.path)
            var data: Int64 = 0
            for path in found[index].data { data += await size(of: path) }
            found[index].dataBytes = data
        }
        guard request == appsRequest else { return }
        unusedApps = found.sorted { $0.bytes > $1.bytes }
    }

    private func size(of path: String) async -> Int64 {
        if let known = await reader.size(ofPath: path) { return known.bytes }
        return await Task.detached(priority: .utility) { Cleaner.measure(path).bytes }.value
    }

    private func loadInstallers() async {
        let names = apps.installed.map(\.name)
        installers = await Task.detached(priority: .utility) { Installers.scan(apps: names) }.value
    }

    /// Ejects a mounted disk image so it can be cleaned.
    func eject(_ installer: Installer) async {
        guard let device = installer.mountedAs else { return }
        do {
            try await Task.detached { try Installers.eject(device) }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadInstallers()
    }

    private func syncBackgroundAgent() {
        if autoClean.background && autoClean.anyEnabled {
            try? BackgroundAgent.autoClean.install()
        } else {
            BackgroundAgent.autoClean.uninstall()
        }
    }

    // MARK: System Data

    /// What "System Data" is made of; loaded when someone asks.
    private(set) var systemData: SystemDataReport?

    func loadSystemData() async {
        let volumes = await Task.detached { SystemVolumes.read() }.value
        guard let overview else { return }

        var onDisk: [SystemDataItem] = []
        var areas: Int64 = 0
        for area in SystemDataCatalog.areas {
            guard let size = await reader.size(ofPath: area.path), size.bytes > 100 << 20 else { continue }
            onDisk.append(SystemDataItem(name: area.name, detail: area.detail, bytes: size.bytes, action: .explore(area.path)))
            areas += size.bytes
        }

        let users = overview.top.first { $0.name == "Users" }?.total ?? 0
        let apps = overview.top.first { $0.name == "Applications" }?.total ?? 0
        let others = users - (overview.home?.total ?? users)
        if others > 100 << 20 {
            onDisk.append(SystemDataItem(
                name: "Other users & Shared", detail: "Other accounts on this Mac and /Users/Shared.",
                bytes: others, action: .explore("/Users")))
        }
        let rest = overview.root.total - users - apps - areas
        if rest > 500 << 20 {
            onDisk.append(SystemDataItem(
                name: "Other system files", detail: "Everything else outside your home folder and Applications.",
                bytes: rest, action: .explore("/")))
        }
        // Whatever the walk and APFS volumes don't explain is space Ballast
        // couldn't look inside: locked folders and file-system overhead.
        // As the balancing row, it keeps the breakdown equal to the Overview.
        let target = max(usedBytes - apps - (overview.home?.total ?? 0), 0)
        let hidden = volumes.volumes.map(SystemDataCatalog.volume)
        let measured = (onDisk + hidden).reduce(0) { $0 + $1.bytes }
        if target - measured > 500 << 20 {
            let locked = overview.lockedByPermissions + overview.lockedByPrivacy
            onDisk.append(SystemDataItem(
                name: "Not measured",
                detail: locked > 0
                    ? "Space Ballast couldn't look inside: \(locked) locked folders, plus file-system overhead."
                    : "File-system overhead and space APFS doesn't attribute to any folder.",
                bytes: target - measured,
                action: overview.lockedByPermissions > 0 ? .adminScan : .none))
        }

        systemData = SystemDataReport(
            onDisk: onDisk.sorted { $0.bytes > $1.bytes },
            hidden: hidden.sorted { $0.bytes > $1.bytes },
            snapshots: volumes.snapshots,
            purgeable: volumes.purgeable,
            total: target
        )
    }

    /// What the last "Delete Local Snapshots" did, for the System Data sheet.
    private(set) var snapshotResult: String?
    private(set) var isThinningSnapshots = false

    /// Asks Time Machine to drop its local snapshots, then re-reads the
    /// layout and free space so the sheet shows what came back.
    func thinLocalSnapshots() async {
        guard !isThinningSnapshots else { return }
        isThinningSnapshots = true
        snapshotResult = nil
        let outcome = await Task.detached { LocalSnapshots.thin() }.value
        isThinningSnapshots = false
        snapshotResult = outcome.message
        if outcome.freed > 0 { history = History.record(free: Volume.freeBytes, freed: outcome.freed) }
        refreshFreeSpace()
        await loadSystemData()
    }

    // MARK: What grew

    /// Folder sizes compared with an earlier day, for the Overview.
    private(set) var growth: GrowthSummary = .empty
    /// The period picked on the Overview; nil picks the first with data.
    var growthPeriod: GrowthPeriod? {
        didSet { if growthPeriod != oldValue { Task { await loadGrowth() } } }
    }
    /// The first reading of a session keeps the previous one as "last open".
    @ObservationIgnored private var growthSessionStarted = false

    /// Saves today's folder sizes, then compares. Runs after every change
    /// to the index, so a cleanup shows up as freed space right away.
    private func recordGrowth() async {
        guard hasIndex else { return }
        let sizes = await reader.growthSizes()
        guard !sizes.isEmpty else { return }
        let newSession = !growthSessionStarted
        growthSessionStarted = true
        let period = growthPeriod
        let summary = await Task.detached(priority: .utility) { () -> GrowthSummary? in
            guard let store = try? GrowthStore() else { return nil }
            try? store.record(sizes, newSession: newSession)
            return try? Growth.summary(store, period: period)
        }.value
        if let summary { growth = summary }
    }

    private func loadGrowth() async {
        let period = growthPeriod
        let summary = await Task.detached(priority: .userInitiated) { () -> GrowthSummary? in
            guard FileManager.default.fileExists(atPath: Paths.growth), let store = try? GrowthStore() else { return nil }
            return try? Growth.summary(store, period: period)
        }.value
        guard period == growthPeriod else { return }
        growth = summary ?? .empty
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

    /// Opens a folder in the Explorer from another screen, e.g. the Cleanup List.
    func showInExplorer(_ path: String) {
        Task { await open(path: path) }
        requestedPane = .explorer
    }

    /// Folders anywhere on the disk whose name contains `text`.
    func search(_ text: String) async -> [SearchHit] {
        await reader.search(text)
    }

    /// The open folder's children, for File › Export….
    var explorerExport: [ExportRow] {
        let whole = trail.last?.total ?? 0
        return children.compactMap { row in displayPath(of: row).map { ExportRow(path: $0, row: row, of: whole) } }
    }

    /// Largest folders, for File › Export… on the Overview.
    var hotspotExport: [ExportRow] {
        let whole = overview?.root.total ?? 0
        return hotspots.map { ExportRow(path: $0.path, row: $0.row, of: whole) }
    }

    /// Explorer is on screen; set while it is, so a reload can fill it.
    @ObservationIgnored var isExplorerShown = false

    private func openRootIfShown() {
        if isExplorerShown { openRootIfIdle() }
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
        cleanup = await reader.cleanup(staleMonths: preferences.staleMonths)
        artifacts = await reader.allArtifacts()
        // Slower than the index; the lists fill in when ready.
        if hasIndex {
            Task { await loadUnusedApps() }
            Task { await loadInstallers() }
        }
        recomputeAutoCleanDue()
        recomputeReclaimable()
        if hasIndex { history = History.record(free: freeBytes) }
        saveSnapshot()

        if let openPath, let id = await reader.deepest(openPath) {
            open(id)
        } else if openPath != nil {
            trail = []
            children = []
        }
        // Explorer may have asked for the root while this was loading:
        // clearing here would leave it empty.
        openRootIfShown()
        await recordGrowth()
    }

    private func refreshVolume() {
        guard let volume = Volume.capacity else { return }
        freeBytes = volume.free
        totalBytes = volume.total
    }

    // MARK: Status

    /// What the Overview shows, in the form other surfaces read.
    var snapshot: StatusSnapshot {
        StatusSnapshot(
            date: .now,
            volumeName: Paths.volumeName,
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            segments: overview.map { StatusSnapshot.segments(overview: $0, cleanup: cleanup, used: usedBytes) } ?? [],
            safeToClean: reclaimable,
            freedLastWeek: History.freed(in: history),
            scannedAt: overview?.scannedAt
        )
    }

    /// Saves status.json after anything that changes the figures.
    private func saveSnapshot() {
        guard totalBytes > 0 else { return }
        snapshot.publish()
    }

    /// A fresh free-space reading (statfs only, no scan), then the low-space
    /// check. Runs every few minutes and whenever the menu bar item opens.
    func refreshFreeSpace() {
        refreshVolume()
        guard totalBytes > 0 else { return }
        let snapshot = self.snapshot
        snapshot.publish()
        let preferences = self.preferences
        // Posting waits for the notification center: keep it off the main thread.
        Task.detached(priority: .utility) { LowSpace.check(snapshot, preferences: preferences) }
    }

    /// Keeps free space current while Ballast runs with no window open.
    private func watchFreeSpace() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                self?.refreshFreeSpace()
            }
        }
    }
}
