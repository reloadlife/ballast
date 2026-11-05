import AppKit
import BallastCore
import Darwin
import Foundation
import Observation
import os

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

// MARK: - Run gate

/// Who asked for a run: Ballast on its own (the update at launch, the
/// five-minute refresh, an exclusion change) or the user (a button, a menu
/// item, a Shortcuts action).
enum RunKind: Sendable, Equatable {
    case background, user
}

/// What happens to a request to start a run.
enum RunDecision: Sendable, Equatable {
    case start
    /// A background run holds the gate: stop it, wait for it, then start.
    case preempt
    /// Busy. The message says why, for user requests; background requests
    /// are dropped quietly (the next tick tries again).
    case refuse(String?)
}

/// The rules for one run at a time. User work is never dropped in silence:
/// it stops background work, or is refused with a message saying what's
/// running.
enum RunGate {
    struct Running: Sendable, Equatable {
        let kind: RunKind
        let title: String
    }

    /// `waiting` is the title of a user run that is already stopping a
    /// background one and will start next.
    static func decide(running: Running?, waiting: String?, incoming: RunKind) -> RunDecision {
        if let waiting { return incoming == .user ? .refuse(busyMessage(waiting)) : .refuse(nil) }
        guard let running else { return .start }
        switch (running.kind, incoming) {
        case (_, .background): return .refuse(nil)
        case (.background, .user): return .preempt
        case (.user, .user): return .refuse(busyMessage(running.title))
        }
    }

    static func busyMessage(_ title: String) -> String {
        "Ballast is busy (\(title)). Try again when it's done."
    }
}

/// Waits between automatic updates after they fail, so a broken index or
/// a missing volume doesn't take the gate every five minutes forever.
struct UpdateBackoff: Sendable, Equatable {
    /// 5, 10, 20, then 60 minutes.
    static let delays: [TimeInterval] = [5, 10, 20, 60].map { $0 * 60 }

    private(set) var failures = 0
    private(set) var retryAt: Date?

    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return delays[min(failures, delays.count) - 1]
    }

    func allowsAttempt(at now: Date) -> Bool {
        retryAt.map { now >= $0 } ?? true
    }

    mutating func failed(at now: Date) {
        failures += 1
        retryAt = now.addingTimeInterval(Self.delay(afterFailures: failures))
    }

    mutating func succeeded() {
        failures = 0
        retryAt = nil
    }
}

/// The newest progress report of a running job, handed to the main actor
/// one hop at a time: a fast walker can't flood it with tasks, and only the
/// latest report is ever shown.
final class ProgressMailbox: Sendable {
    private let state = OSAllocatedUnfairLock<(latest: ScanStatus?, pending: Bool)>(initialState: (nil, false))

    /// Leaves `status`; true when the caller has to schedule a delivery.
    func post(_ status: ScanStatus) -> Bool {
        state.withLock { state in
            state.latest = status
            guard !state.pending else { return false }
            state.pending = true
            return true
        }
    }

    func take() -> ScanStatus? {
        state.withLock { state in
            state.pending = false
            defer { state.latest = nil }
            return state.latest
        }
    }
}

/// The running job's live progress. Only progress bars read it, so the
/// many views that only need to know whether something runs don't redraw
/// on every report.
@MainActor
@Observable
final class ScanProgressModel {
    private(set) var status: ScanStatus?
    /// 0...1 during a full scan when the previous scan's size is known.
    private(set) var fraction: Double?

    func set(_ status: ScanStatus?, fraction: Double?) {
        self.status = status
        if self.fraction != fraction { self.fraction = fraction }
    }
}

/// Apps in the standard folders, read off the main thread and kept for
/// 30 s: it opens every Info.plist.
actor InstalledApps {
    static let shared = InstalledApps()

    private var cache: (date: Date, apps: [InstalledApp])?

    func current() -> [InstalledApp] {
        if let cache, Date.now.timeIntervalSince(cache.date) < 30 { return cache.apps }
        let fm = FileManager.default
        var apps: [InstalledApp] = []
        func add(_ dir: String, depth: Int) {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = dir + "/" + name
                if name.hasSuffix(".app") {
                    apps.append(InstalledApp(name: String(name.dropLast(4)), bundleID: Bundle(path: path)?.bundleIdentifier ?? ""))
                } else if depth > 0 {
                    add(path, depth: depth - 1)
                }
            }
        }
        for root in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] { add(root, depth: 1) }
        cache = (.now, apps)
        return apps
    }
}

/// Like `ScanEngine.remeasure`, but says whether every index took the new
/// sizes: when one didn't, the next update has to catch up.
enum Remeasure {
    static func run(_ displayPaths: [String], volumes: [MountedVolume], report: StatusHandler) -> Bool {
        var startup: [String] = []
        var byVolume: [String: (MountedVolume, [String])] = [:]
        for path in Set(displayPaths) {
            if let volume = volumes.filter({ path == $0.path || path.hasPrefix($0.path + "/") })
                .max(by: { $0.path.count < $1.path.count }) {
                byVolume[volume.uuid, default: (volume, [])].1.append(path)
            } else if !path.hasPrefix("/Volumes/") {
                startup.append(Paths.onVolume(path))
            }
        }
        var measured = true
        if !startup.isEmpty {
            do {
                try ScanEngine.rescan(startup.sorted(), title: "Measuring", report: report, cancel: CancelFlag())
            } catch {
                measured = false
            }
        }
        for (volume, paths) in byVolume.values {
            guard let target = IndexTarget.volume(volume), FileManager.default.fileExists(atPath: target.index) else { continue }
            do {
                try ScanEngine.rescan(paths.sorted(), target: target, title: "Measuring", report: report, cancel: CancelFlag())
            } catch {
                measured = false
            }
        }
        return measured
    }
}

/// Safety verdicts worked out off the main thread, assigned in one go.
struct Verdicts: Sendable {
    struct Input: Sendable {
        var apps: AppInventory
        var protected: [String]
        var settings: AutoCleanSettings
        /// Verdicts still good: reused when the size and action match.
        var cached: [String: PlanItem] = [:]
        /// Items whose verdict may have changed (apps opened or quit).
        var reassess: [PlanItem] = []
        var plan: [PlanItem] = []
        var startup: [ScanResult] = []
        var artifacts: [Artifact] = []
        var hotspots: [Hotspot] = []
        var growth: [GrowthRow] = []
    }

    var items: [String: PlanItem] = [:]
    /// New verdicts for Cleanup List items, by path.
    var plan: [String: Safety] = [:]
    var canRemove: [String: Bool] = [:]
    var safe: [ScanResult] = []
    var due: [(Artifact, AutoCleanRule)] = []

    static func compute(_ input: Input) -> Verdicts {
        var verdicts = Verdicts()
        func item(name: String, path: String, bytes: Int64, action: CleanAction, isDirectory: Bool) -> PlanItem {
            if let known = verdicts.items[path] ?? input.cached[path], known.bytes == bytes, known.action == action {
                verdicts.items[path] = known
                return known
            }
            let fresh = PlanItem.assess(name: name, path: path, bytes: bytes, action: action, isDirectory: isDirectory,
                                        apps: input.apps, protected: input.protected)
            verdicts.items[path] = fresh
            return fresh
        }
        func item(for result: ScanResult) -> PlanItem? {
            result.target.action.map {
                item(name: result.target.name, path: result.target.path, bytes: result.bytes, action: $0, isDirectory: true)
            }
        }
        for stale in input.reassess {
            verdicts.items[stale.path] = PlanItem.assess(
                name: stale.name, path: stale.path, bytes: stale.bytes, action: stale.action,
                isDirectory: stale.isDirectory, apps: input.apps, protected: input.protected)
        }
        for planned in input.plan {
            verdicts.plan[planned.path] = item(name: planned.name, path: planned.path, bytes: planned.bytes,
                                               action: planned.action, isDirectory: planned.isDirectory).safety
        }
        for result in input.startup { _ = item(for: result) }
        verdicts.safe = StatusSnapshot.safeSuggestions(input.startup) { item(for: $0) }
        verdicts.due = AutoClean.due(input.artifacts, settings: input.settings).filter { artifact, _ in
            item(name: artifact.path, path: artifact.path, bytes: artifact.bytes, action: .remove, isDirectory: true)
                .safety.level == .safe
        }
        for spot in input.hotspots {
            verdicts.canRemove[spot.path] = Cleaner.canRemove(spot.path)
            _ = item(name: spot.row.name, path: spot.path, bytes: spot.row.total, action: .remove, isDirectory: true)
        }
        for row in input.growth {
            let removable = Cleaner.canRemove(row.path)
            verdicts.canRemove[row.path] = removable
            if removable, let size = row.size {
                _ = item(name: row.name, path: row.path, bytes: size, action: .remove, isDirectory: true)
            }
        }
        return verdicts
    }
}

@MainActor
@Observable
final class AppModel {
    /// One model for every window, the menu bar item and the app delegate.
    static let shared = AppModel()

    private(set) var overview: Overview?
    /// Suggestions: the startup disk's, plus build folders on other
    /// connected drives that have been scanned.
    private(set) var cleanup: [ScanResult] = [] {
        didSet {
            groups = Dictionary(grouping: cleanup, by: \.target.category).mapValues { $0.sorted { $0.bytes > $1.bytes } }
            groupTotals = groups.mapValues { $0.reduce(0) { $0 + $1.bytes } }
        }
    }
    private(set) var hotspots: [Hotspot] = []
    /// The startup disk's large files, largest first.
    private(set) var largeFiles: LargeFileList = .empty
    /// Loaded in start(), off the main thread.
    private(set) var history: [HistoryPoint] = []
    /// The running job's title and progress, refreshed at most twice a
    /// second; `scanProgress` has every report.
    private(set) var status: ScanStatus?
    private(set) var errorMessage: String?
    private(set) var freeBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var hasFullDiskAccess = Access.hasFullDiskAccess
    /// Full Disk Access was granted before and isn't now, typically because
    /// a rebuilt (re-signed) copy of Ballast lost the grant.
    private(set) var lostFullDiskAccess = false

    /// Explorer state: breadcrumb from the root to the open folder, and its children.
    private(set) var trail: [DirRow] = []
    private(set) var children: [DirRow] = []
    /// The open folder's large files; nil until a full scan has listed them.
    private(set) var folderFiles: [LargeFile]?


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
    var quickLookURL: URL? {
        didSet { if quickLookURL != nil { telemetry.recordOncePerRun(.featureUsed(.quickLook)) } }
    }
    /// Set by ⌘F; Explorer focuses its search field and clears it.
    var searchRequested = false

    /// Whether a scan, cleanup or Put Back is running. Changes only when
    /// one starts or ends, never with its progress.
    private(set) var isScanning = false
    /// Every progress report of the running job, for progress bars.
    let scanProgress = ScanProgressModel()

    /// Files seen by the startup disk's last full scan: lets a new full
    /// scan show a percentage.
    @ObservationIgnored private var expectedFiles: Int64 = 0
    /// The running scan's full-walk title and the file count it's heading
    /// for, when known.
    @ObservationIgnored private var expected: (title: String, files: Int64)?
    /// Free space when the index was last brought up to date.
    @ObservationIgnored private var freeAtUpdate: Int64?
    /// When `status` was last refreshed from a progress report.
    @ObservationIgnored private var statusShownAt = Date.distantPast

    /// 0...1 during a full scan when the previous scan's size is known.
    var progress: Double? { scanProgress.fraction }

    private func fraction(of status: ScanStatus?) -> Double? {
        guard let walk = status?.walk, let expected, status?.title == expected.title, expected.files > 0 else { return nil }
        return min(Double(walk.files) / Double(expected.files), 0.99)
    }

    /// One plain sentence about what the app is doing right now. For a
    /// relative time that keeps ticking, show `lastUpdated` with
    /// `Text(_:style: .relative)` instead of the "Updated …" sentence.
    var statusLine: String {
        if let status {
            if let progress = fraction(of: status) { return "\(status.title) · \(Int(progress * 100))%" }
            return status.title
        }
        if let date = overview?.scannedAt {
            return "Updated \(date.formatted(.relative(presentation: .named)))"
        }
        return hasIndex ? "" : "Not scanned yet"
    }

    /// When the startup disk's index was last brought up to date, while
    /// nothing is running.
    var lastUpdated: Date? {
        status == nil ? overview?.scannedAt : nil
    }

    var hasIndex: Bool { overview != nil }

    /// The status line for a disk: the running scan's, or how current its
    /// index is ("Not connected · scanned 3 days ago").
    func statusLine(for disk: DiskID) -> String {
        guard let uuid = disk.uuid, !isScanning else { return statusLine }
        guard let info = disks.first(where: { $0.uuid == uuid }) else { return "" }
        let scanned = info.scannedAt.map { $0.formatted(.relative(presentation: .named)) }
        if !info.isConnected { return scanned.map { "Not connected · scanned \($0)" } ?? "Not connected" }
        return scanned.map { "Updated \($0)" } ?? "Not scanned yet"
    }
    var usedBytes: Int64 { max(totalBytes - freeBytes, 0) }
    var planBytes: Int64 { plan.reduce(0) { $0 + $1.bytes } }

    /// What "Add All Safe Items" would actually clean right now: caches and
    /// build files that pass the safety check, nested items counted once.
    /// Kept in sync with the Clean Up button, so every screen shows one number.
    private(set) var reclaimable: Int64 = 0

    /// The suggestions behind `reclaimable`, outermost first. Startup
    /// disk only: this is the figure the menu bar and widget show.
    /// Worked out off the main thread whenever suggestions load.
    private(set) var safeSuggestions: [ScanResult] = []

    /// The startup disk's suggestions.
    private(set) var startupCleanup: [ScanResult] = []
    /// Build folders on other drives, as suggestions.
    private(set) var driveCleanup: [ScanResult] = []

    private func setCleanup(startup: [ScanResult]? = nil, drives: [ScanResult]? = nil) {
        if let startup { startupCleanup = startup }
        if let drives { driveCleanup = drives }
        cleanup = startupCleanup + driveCleanup
    }

    /// Suggestions grouped once per load, not on every redraw.
    private(set) var groups: [Category: [ScanResult]] = [:]
    private(set) var groupTotals: [Category: Int64] = [:]

    func cleanup(in category: Category) -> [ScanResult] { groups[category] ?? [] }
    func total(in category: Category) -> Int64 { groupTotals[category] ?? 0 }

    /// Running and installed apps; read in start() and whenever an app
    /// opens or quits, never on the main thread's critical path.
    @ObservationIgnored private(set) var apps = AppInventory(running: [], installed: [])
    /// Safety verdicts per path. Assessing touches the filesystem and the
    /// running-app list, so rows must never do it on every redraw. Entries
    /// are replaced when their size changes, never thrown away wholesale.
    @ObservationIgnored private var itemCache: [String: PlanItem] = [:]
    /// `Cleaner.canRemove` per path, for Overview rows.
    @ObservationIgnored private var canRemoveCache: [String: Bool] = [:]
    /// The startup disk's index for reloads after a run: suggestions,
    /// hotspots, growth. Slow queries queue here.
    @ObservationIgnored private let reader = IndexReader()
    /// The same index on its own connection, for what someone is waiting
    /// on: Explorer folders, search, sizes of dropped items.
    @ObservationIgnored private let interactiveReader = IndexReader()
    @ObservationIgnored private var cancelFlag = CancelFlag()
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var exploreRequest = 0
    @ObservationIgnored private var exploring = 0
    /// Set when the index needs an update once the running job ends: the
    /// exclusion list changed, a background update was stopped, or a
    /// cleanup couldn't remeasure.
    @ObservationIgnored private var needsUpdate = false

    // MARK: Run state

    enum RunPurpose: Sendable {
        case update, scan, clean, putBack, autoClean, other
    }

    private struct ActiveRun {
        let id: Int
        var kind: RunKind
        let title: String
        let purpose: RunPurpose
        let cancel: CancelFlag
    }

    /// A run's hold on the gate.
    private struct RunTicket {
        let id: Int
    }

    /// How a run ended.
    private enum RunOutcome<T> {
        case finished(T)
        case failed(String)
        case cancelled

        var value: T? {
            if case .finished(let value) = self { value } else { nil }
        }
    }

    @ObservationIgnored private var activeRun: ActiveRun?
    @ObservationIgnored private var runCounter = 0
    /// A user run stopping a background one, which starts next.
    @ObservationIgnored private var preempting: String?
    @ObservationIgnored private var idleWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var waiterCounter = 0
    @ObservationIgnored private var updateTask: Task<Bool, Never>?
    @ObservationIgnored private var updateBackoff = UpdateBackoff()

    /// A cleanup, Put Back or auto-clean is moving files right now.
    var isCleaning: Bool {
        guard let purpose = activeRun?.purpose else { return false }
        return purpose == .clean || purpose == .putBack || purpose == .autoClean
    }

    // MARK: Usage data

    @ObservationIgnored let telemetry = Telemetry.shared
    /// The user's answer about sharing usage data; nil until they give one.
    private(set) var telemetryDecision = Telemetry.shared.decision
    /// Whether the startup disk had an index when Ballast opened: the
    /// question about usage data waits for a launch after the first scan.
    private(set) var hadIndexAtLaunch = false

    /// The one-time question on the Overview: only in a build that can send,
    /// only before the user has answered, never on the launch that ran the
    /// first scan.
    var asksAboutUsageData: Bool {
        telemetry.isAvailable && telemetryDecision == nil && hadIndexAtLaunch && hasIndex
    }

    var sharesUsageData: Bool { telemetryDecision == .shared && telemetry.isSharing }

    func setSharesUsageData(_ share: Bool) {
        if share { telemetry.optIn() } else { telemetry.optOut() }
        telemetryDecision = telemetry.decision
    }

    /// A Suggestions section came into view.
    func noteSectionViewed(_ section: SuggestionSectionID) {
        telemetry.recordOncePerRun(.suggestionSectionViewed(section))
    }

    func noteFeature(_ feature: TelemetryFeature) {
        telemetry.recordOncePerRun(.featureUsed(feature))
    }

    func noteSetting(_ setting: TelemetrySetting, _ value: SettingValue?) {
        telemetry.record(.settingChanged(setting, value))
    }

    /// Settings changes worth counting, with their new value only when it's
    /// a switch or a fixed choice. Folder lists send only that they changed.
    private func noteChanges(from old: Preferences) {
        let new = preferences
        if new.deletePermanentlyByDefault != old.deletePermanentlyByDefault {
            noteSetting(.deletePermanentlyByDefault, .on(new.deletePermanentlyByDefault))
        }
        if new.showMenuBarItem != old.showMenuBarItem { noteSetting(.menuBarItem, .on(new.showMenuBarItem)) }
        if new.menuBarShowsFreeSpace != old.menuBarShowsFreeSpace { noteSetting(.menuBarFreeSpace, .on(new.menuBarShowsFreeSpace)) }
        if new.lowSpaceAlert != old.lowSpaceAlert { noteSetting(.lowSpaceAlert, .on(new.lowSpaceAlert)) }
        if new.lowSpaceThresholdGB != old.lowSpaceThresholdGB {
            noteSetting(.lowSpaceThreshold, .choice(.lowSpace(gigabytes: new.lowSpaceThresholdGB)))
        }
        if new.staleMonths != old.staleMonths { noteSetting(.staleMonths, .choice(.stale(months: new.staleMonths))) }
        if new.showRemovableDrives != old.showRemovableDrives { noteSetting(.removableDrives, .on(new.showRemovableDrives)) }
        if new.excludedFolders != old.excludedFolders { noteSetting(.excludedFolders, nil) }
        if new.protectedFolders != old.protectedFolders { noteSetting(.protectedFolders, nil) }
    }

    // MARK: Preferences

    /// Settings shared with the command-line modes. Read before the first
    /// frame (the menu bar item depends on it; the file is a few hundred
    /// bytes), saved a moment after they stop changing.
    var preferences = Preferences.load() {
        didSet {
            guard preferences != oldValue else { return }
            preferences.remember()
            schedulePreferencesSave()
            noteChanges(from: oldValue)
            if preferences.protectedFolders != oldValue.protectedFolders { scheduleSafetyRefresh(after: .zero) }
            if preferences.staleMonths != oldValue.staleMonths {
                Task { await reloadSuggestions() }
                Task { await loadUnusedApps() }
            }
            if preferences.excludedFolders != oldValue.excludedFolders { applyExclusions() }
            if preferences.lowSpaceAlert != oldValue.lowSpaceAlert {
                if preferences.lowSpaceAlert { Notify.requestPermission() }
                scheduleAgentSync()
            }
        }
    }

    @ObservationIgnored private var preferencesSave: Task<Void, Never>?
    @ObservationIgnored private var preferencesDirty = false

    private func schedulePreferencesSave() {
        preferencesDirty = true
        let previous = preferencesSave
        previous?.cancel()
        preferencesSave = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await previous?.value
            preferencesDirty = false
            let preferences = self.preferences
            await Task.detached(priority: .utility) { preferences.save() }.value
        }
    }

    /// Brings the index in line with the exclusion list: update() re-lists
    /// the parents of folders that were added or removed.
    private func applyExclusions() {
        guard FileManager.default.fileExists(atPath: Paths.index) else { return }
        needsUpdate = true
        kickPendingUpdate()
    }

    /// Re-reads the Full Disk Access grant, e.g. after a trip to System Settings.
    func refreshAccess() {
        let granted = Access.hasFullDiskAccess
        if hasFullDiskAccess != granted { hasFullDiskAccess = granted }
        let defaults = UserDefaults.standard
        let had = defaults.bool(forKey: Self.hadAccessKey)
        if granted && !had { defaults.set(true, forKey: Self.hadAccessKey) }
        let lost = Self.accessWasLost(granted: granted, hadAccess: had)
        if lostFullDiskAccess != lost { lostFullDiskAccess = lost }
    }

    /// The user doesn't want Full Disk Access back: stop pointing it out.
    func dismissLostFullDiskAccess() {
        UserDefaults.standard.removeObject(forKey: Self.hadAccessKey)
        lostFullDiskAccess = false
    }

    private static let hadAccessKey = "HadFullDiskAccess"

    /// Granted once, not now: macOS dropped the grant (a re-signed build)
    /// or it was turned off.
    nonisolated static func accessWasLost(granted: Bool, hadAccess: Bool) -> Bool {
        !granted && hadAccess
    }

    func clearHistory() {
        Task {
            await Self.onFileQueue { History.clear() }
            history = []
        }
        GrowthStore.clear()
        growth = .empty
    }

    // MARK: Scanning

    /// Loads everything once; later calls wait for that first load.
    func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { await load() }
        startTask = task
        await task.value
        // update() brings an older index up to date: schema 2 in place (it
        // gains the large-files table), anything older with a full scan.
        if hasIndex || FileManager.default.fileExists(atPath: Paths.index) { await update(.background) }
    }

    private func load() async {
        hadIndexAtLaunch = FileManager.default.fileExists(atPath: Paths.index)
        refreshAccess()
        watchApps()
        // Re-point the background agents at this copy of the app.
        scheduleAgentSync()
        if preferences.lowSpaceAlert { Notify.requestPermission() }
        // Files the first frame doesn't need, read off the main thread.
        async let history = Task.detached(priority: .utility) { History.load() }.value
        async let log = Task.detached(priority: .utility) { TrashLog.standard.load() }.value
        async let lastRun = Task.detached(priority: .utility) { AutoCleanRun.last() }.value
        apps = await loadApps()
        self.history = await history
        cleanupLog = await log
        lastAutoClean = await lastRun
        await refreshVolume()
        await reload()
        refreshFreeSpace()
        watchFreeSpace()
        // Other drives are listed, never scanned until someone asks.
        watchVolumes()
        await refreshDisks()
    }

    static let updateTitle = "Checking what changed"

    /// Replays the change log; falls back to a full scan when there is none.
    /// False when it didn't run (busy, see `errorMessage`) or failed. A
    /// second call while one runs waits for it instead of starting another.
    @discardableResult
    func update(_ kind: RunKind = .user) async -> Bool {
        if let running = updateTask {
            // Someone is waiting on it now: don't let other work stop it.
            if kind == .user, activeRun?.purpose == .update { activeRun?.kind = .user }
            return await running.value
        }
        guard let ticket = await acquire(kind, Self.updateTitle, purpose: .update) else { return false }
        let task = Task { await performUpdate(ticket) }
        updateTask = task
        let updated = await task.value
        if updateTask == task { updateTask = nil }
        return updated
    }

    private func performUpdate(_ ticket: RunTicket) async -> Bool {
        let start = Date.now
        let hadIndex = FileManager.default.fileExists(atPath: Paths.index)
        let outcome = await execute(ticket, reloadsWhen: { [hasIndex] scan in
            // An update that found nothing leaves every figure as it was.
            guard let scan else { return false }
            return scan.full || scan.folders > 0 || !hasIndex
        }) { report, cancel -> (folders: Int, full: Bool) in
            do {
                return (try ScanEngine.update(report: report, cancel: cancel), false)
            } catch ScanEngine.Failure.needsFullScan {
                return (try ScanEngine.fullScan(report: report, cancel: cancel), true)
            }
        }
        switch outcome {
        case .finished(let scan):
            if !(scan.full || scan.folders > 0) { await refreshOverview() }
            freeAtUpdate = freeBytes
            updateBackoff.succeeded()
            noteScan(scan.full ? .full : .incremental, folders: scan.folders, since: start, fellBack: scan.full && hadIndex)
            return true
        case .failed:
            updateBackoff.failed(at: .now)
            return false
        case .cancelled:
            return false
        }
    }

    private func noteScan(_ kind: ScanKind, folders: Int, since start: Date, fellBack: Bool) {
        telemetry.record(.scanCompleted(kind, duration: DurationBucket(seconds: Date.now.timeIntervalSince(start)),
                                        folders: CountBucket(folders), fellBackToFull: fellBack))
    }

    /// Waits for the scan or cleanup in progress to end. Returns early if
    /// the caller is cancelled (a Shortcuts action stopped by the user).
    func awaitIdle() async {
        while activeRun != nil || preempting != nil {
            if Task.isCancelled { return }
            if activeRun == nil {
                // A user run is about to start after stopping a background one.
                await Task.yield()
                continue
            }
            await waitForGate()
        }
    }

    func fullScan() async {
        let start = Date.now
        if let folders = await run("Scanning disk", purpose: .scan, { try ScanEngine.fullScan(report: $0, cancel: $1) })?.value {
            noteScan(.full, folders: folders, since: start, fellBack: false)
        }
    }

    /// Rewalks every locked folder as the current user; worth doing after
    /// Full Disk Access was granted.
    func rescanLocked() async {
        let paths = await reader.lockedPaths(permissionsOnly: false)
        guard !paths.isEmpty else { return }
        await run("Rescanning locked folders", purpose: .scan) {
            try ScanEngine.rescan(paths, title: "Rescanning locked folder", report: $0, cancel: $1)
        }
    }

    func rescanLockedAsAdmin() async {
        let paths = await reader.lockedPaths(permissionsOnly: true)
        guard !paths.isEmpty else { return }
        await run("Waiting for administrator password", purpose: .scan) { report, cancel in
            // AdminScan.run can't be interrupted while the password prompt
            // or the root walk runs; a Cancel then discards the results.
            let results = try AdminScan.run(paths: paths)
            if cancel.isSet { throw CancellationError() }
            report(ScanStatus(title: "Merging \(results.count) folders"))
            try ScanEngine.graft(results)
        }
    }

    func cancelScan() {
        cancelFlag.set()
    }

    /// What a finished run reloads: the startup disk's index (and every
    /// figure built on it), one other drive's, both, or nothing.
    private enum ReloadScope {
        case startup, disk(String), all, none
    }

    /// Takes the gate, or says why not. A user request stops a background
    /// run first; one that finds another user run going is refused with a
    /// message rather than dropped.
    private func acquire(_ kind: RunKind, _ title: String, purpose: RunPurpose) async -> RunTicket? {
        let running = activeRun.map { RunGate.Running(kind: $0.kind, title: $0.title) }
        switch RunGate.decide(running: running, waiting: preempting, incoming: kind) {
        case .start:
            return begin(kind, title, purpose: purpose)
        case .preempt:
            preempting = title
            // The index still has to catch up once this run is done.
            if activeRun?.purpose == .update { needsUpdate = true }
            activeRun?.cancel.set()
            while activeRun != nil, !Task.isCancelled { await waitForGate() }
            preempting = nil
            guard !Task.isCancelled else {
                kickPendingUpdate()
                return nil
            }
            return begin(kind, title, purpose: purpose)
        case .refuse(let message):
            if let message { errorMessage = message }
            return nil
        }
    }

    private func begin(_ kind: RunKind, _ title: String, purpose: RunPurpose) -> RunTicket {
        runCounter += 1
        let flag = CancelFlag()
        cancelFlag = flag
        activeRun = ActiveRun(id: runCounter, kind: kind, title: title, purpose: purpose, cancel: flag)
        errorMessage = nil
        let first = ScanStatus(title: title)
        status = first
        statusShownAt = .now
        scanProgress.set(first, fraction: nil)
        isScanning = true
        return RunTicket(id: runCounter)
    }

    /// Gives the gate back and wakes whoever waits for it.
    private func end(_ ticket: RunTicket) {
        guard activeRun?.id == ticket.id else { return }
        activeRun = nil
        isScanning = false
        status = nil
        scanProgress.set(nil, fraction: nil)
        let waiters = idleWaiters
        idleWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
        kickPendingUpdate()
    }

    /// Suspends until the run holding the gate ends (or the caller is cancelled).
    private func waitForGate() async {
        guard activeRun != nil else { return }
        waiterCounter += 1
        let key = waiterCounter
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || activeRun == nil {
                    continuation.resume()
                } else {
                    idleWaiters[key] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.idleWaiters.removeValue(forKey: key)?.resume() }
        }
    }

    /// Runs the update a job asked for, once nothing else holds the gate.
    private func kickPendingUpdate() {
        guard needsUpdate, activeRun == nil, preempting == nil else { return }
        needsUpdate = false
        Task {
            // Checked again when it gets to run: if something started
            // meanwhile, the flag waits for that to end.
            if activeRun != nil || preempting != nil {
                needsUpdate = true
            } else {
                await update(.background)
            }
        }
    }

    /// Progress from a job, if it's still the one running.
    private func applyProgress(_ update: ScanStatus, run id: Int) {
        guard activeRun?.id == id else { return }
        scanProgress.set(update, fraction: fraction(of: update))
        let now = Date.now
        if update.title != status?.title || now.timeIntervalSince(statusShownAt) >= 0.5 {
            status = update
            statusShownAt = now
        }
    }

    @discardableResult
    private func run<T: Sendable>(
        _ title: String,
        kind: RunKind = .user,
        purpose: RunPurpose = .other,
        reloading scope: ReloadScope = .startup,
        expecting expected: (title: String, files: Int64)? = nil,
        _ work: @escaping @Sendable (StatusHandler, CancelFlag) throws -> T
    ) async -> RunOutcome<T>? {
        guard let ticket = await acquire(kind, title, purpose: purpose) else { return nil }
        return await execute(ticket, reloading: scope, expecting: expected, work)
    }

    /// Runs `work` off the main thread holding `ticket`, then reloads what
    /// it changed. `reloadsWhen` sees the result (nil when it failed or was
    /// cancelled) and can skip the reload.
    private func execute<T: Sendable>(
        _ ticket: RunTicket,
        reloading scope: ReloadScope = .startup,
        expecting expected: (title: String, files: Int64)? = nil,
        reloadsWhen shouldReload: (T?) -> Bool = { _ in true },
        _ work: @escaping @Sendable (StatusHandler, CancelFlag) throws -> T
    ) async -> RunOutcome<T> {
        guard let flag = activeRun?.cancel, activeRun?.id == ticket.id else { return .cancelled }
        self.expected = expected ?? ("Scanning disk", expectedFiles)
        let id = ticket.id
        let mailbox = ProgressMailbox()
        let report: StatusHandler = { [weak self] update in
            guard mailbox.post(update) else { return }
            Task { @MainActor in
                if let latest = mailbox.take() { self?.applyProgress(latest, run: id) }
            }
        }
        let outcome: RunOutcome<T>
        do {
            outcome = .finished(try await Task.detached(priority: .userInitiated) { try work(report, flag) }.value)
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            errorMessage = error.localizedDescription
            outcome = .failed(error.localizedDescription)
        }

        end(ticket)
        await refreshVolume()
        refreshAccess()
        if shouldReload(outcome.value) {
            switch scope {
            case .startup:
                await reload()
            case .disk(let uuid):
                await reloadDisks([uuid])
            case .all:
                await reload()
                await reloadDisks(Array(diskReaders.keys))
            case .none:
                break
            }
        }
        return outcome
    }

    // MARK: Cleanup list

    func isPlanned(_ path: String) -> Bool {
        plannedPaths.contains(path)
    }

    /// Safety of removing a path, using the current app snapshot.
    func safety(of path: String, isDirectory: Bool = true) -> Safety {
        SafetyCheck.assess(path, isDirectory: isDirectory, apps: apps)
    }

    /// Whether a folder could ever be removed (not a system or protected
    /// place), remembered per path so rows can ask on every redraw.
    func canRemove(_ path: String) -> Bool {
        if let known = canRemoveCache[path] { return known }
        let removable = Cleaner.canRemove(path)
        canRemoveCache[path] = removable
        return removable
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
        var next = plan
        next.removeAll { Catalog.covers(item.path, action: item.action, $0.path) }
        next.append(item)
        plan = next
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

    /// List item for a large file, anywhere it's shown.
    func listItem(for file: LargeFile) -> PlanItem {
        makeItem(name: file.name, path: file.path, bytes: file.bytes, action: .remove, isDirectory: false)
    }

    func listItem(for installer: Installer) -> PlanItem {
        makeItem(name: installer.name, path: installer.path, bytes: installer.bytes,
                 action: .remove, isDirectory: installer.isDirectory)
    }

    private func makeItem(name: String, path: String, bytes: Int64, action: CleanAction, isDirectory: Bool) -> PlanItem {
        if let cached = itemCache[path], cached.bytes == bytes, cached.action == action { return cached }
        let item = PlanItem.assess(name: name, path: path, bytes: bytes, action: action, isDirectory: isDirectory,
                                   apps: apps, protected: preferences.protectedFolders)
        itemCache[path] = item
        return item
    }

    /// Files and folders dropped in from Finder or picked in an open panel.
    func add(urls: [URL]) async {
        measuring += urls.count
        for url in urls {
            let path = url.standardizedFileURL.path
            // Folders the index already knows cost nothing to size; anything
            // else (files, unindexed places) is measured.
            let known = await reader(for: path, interactive: true)?.size(ofPath: path)
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

    /// Re-evaluates every item, e.g. after an app opened or quit. Works off
    /// the main thread; the list changes once, when it's done.
    func refreshSafety() {
        scheduleSafetyRefresh(after: .zero)
    }

    /// The same, for callers that need the new verdicts before going on.
    func refreshSafetyNow() async {
        safetyRefresh?.cancel()
        safetyRefresh = nil
        await recomputeVerdicts(reassess: true)
    }

    @ObservationIgnored private var safetyRefresh: Task<Void, Never>?
    @ObservationIgnored private var verdictRequest = 0

    /// Apps launch and quit in bursts (a login, Xcode starting its
    /// helpers): one refresh after things settle.
    private func scheduleSafetyRefresh(after delay: Duration = .milliseconds(500)) {
        safetyRefresh?.cancel()
        safetyRefresh = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await recomputeVerdicts(reassess: true)
        }
    }

    /// The running and installed apps, the installed ones read off the main thread.
    private func loadApps() async -> AppInventory {
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> RunningApp? in
            guard let id = app.bundleIdentifier, app.processIdentifier != getpid() else { return nil }
            return RunningApp(name: app.localizedName ?? id, bundleID: id, pid: app.processIdentifier,
                              bundlePath: app.bundleURL?.path ?? "")
        }
        return AppInventory(running: running, installed: await InstalledApps.shared.current())
    }

    private func verdictInput() -> Verdicts.Input {
        Verdicts.Input(apps: apps, protected: preferences.protectedFolders, settings: autoClean,
                       cached: itemCache, plan: plan, startup: startupCleanup, artifacts: artifacts,
                       hotspots: hotspots, growth: growth.report?.grew ?? [])
    }

    /// Verdicts for the list, the suggestions and the due build folders.
    /// `reassess` re-checks every remembered verdict too (apps changed).
    private func recomputeVerdicts(reassess: Bool) async {
        verdictRequest += 1
        let request = verdictRequest
        if reassess { apps = await loadApps() }
        var input = verdictInput()
        if reassess {
            // Plenty for every row on screen; the rest are assessed when shown.
            input.reassess = Array(itemCache.values.prefix(2_000))
            input.cached = [:]
        }
        let verdicts = await Task.detached(priority: .userInitiated) { Verdicts.compute(input) }.value
        guard request == verdictRequest else { return }
        apply(verdicts, replacingCache: reassess)
    }

    private func apply(_ verdicts: Verdicts, replacingCache: Bool) {
        if replacingCache {
            itemCache = verdicts.items
        } else {
            itemCache.merge(verdicts.items) { $1 }
        }
        canRemoveCache.merge(verdicts.canRemove) { $1 }
        var next = plan
        for index in next.indices {
            guard let safety = verdicts.plan[next[index].path] else { continue }
            let was = next[index].safety.level
            next[index].safety = safety
            if was != .safe && safety.level == .safe { next[index].included = true }
        }
        if next != plan { plan = next }
        safeSuggestions = verdicts.safe
        let total = verdicts.safe.reduce(0) { $0 + $1.bytes }
        if reclaimable != total { reclaimable = total }
        autoCleanDue = verdicts.due
        pruneItemCache()
    }

    /// Keeps the verdict cache from growing without bound as folders are
    /// browsed: past a limit, only what's listed somewhere stays.
    private func pruneItemCache() {
        guard itemCache.count > 5_000 else { return }
        let keep = plannedPaths.union(cleanup.map(\.target.path)).union(hotspots.map(\.path))
        itemCache = itemCache.filter { keep.contains($0.key) }
    }

    private func watchApps() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Menu bar extras and background helpers come and go all the
                // time and own nothing a cleanup would touch.
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let regular = app.map { $0.activationPolicy == .regular } ?? true
                guard regular else { return }
                MainActor.assumeIsolated { self?.scheduleSafetyRefresh() }
            }
        }
    }

    var readyItems: [PlanItem] { plan.filter(\.isReady) }
    var readyBytes: Int64 { readyItems.reduce(0) { $0 + $1.bytes } }

    /// Cleans every ready item, then remeasures just the affected folders.
    /// Stops a background update first; refused (with a message) while
    /// another cleanup or scan the user started is running.
    func cleanPlan(permanently: Bool) async {
        guard let ticket = await acquire(.user, "Cleaning", purpose: .clean) else { return }
        await refreshSafetyNow()
        await clean(readyItems, permanently: permanently, ticket: ticket)
    }

    /// Follow-up for a Trash cleanup: empties the Trash for real. The
    /// Cleanup List isn't touched, so items added meanwhile stay.
    func emptyTrash() async {
        guard let ticket = await acquire(.user, "Emptying the Trash", purpose: .clean) else { return }
        let trash = makeItem(name: "Trash", path: NSHomeDirectory() + "/.Trash",
                             bytes: lastClean?.movedToTrash ?? 0, action: .emptyTrash, isDirectory: true)
        await clean([trash], permanently: true, ticket: ticket)
    }

    private struct Cleaned: Sendable {
        let outcomes: [CleanOutcome]
        let record: CleanupRecord?
        let log: [CleanupRecord]
        /// Every index took the new sizes.
        let measured: Bool
    }

    private func clean(_ items: [PlanItem], permanently: Bool, ticket: RunTicket) async {
        guard !items.isEmpty else {
            end(ticket)
            return
        }
        let freeBefore = freeBytes
        let drivesBefore = driveFree(items.map(\.path))
        let volumes = disks.compactMap(\.mounted)
        let apps = self.apps
        lastClean = nil

        let outcome = await execute(ticket, reloading: .all) { report, cancel -> Cleaned in
            let log = TrashLog.standard
            var outcomes: [CleanOutcome] = []
            var record: CleanupRecord?
            for (index, item) in items.enumerated() {
                if cancel.isSet { break }
                report(ScanStatus(title: "Cleaning \(index + 1) of \(items.count)", walk: WalkProgress(path: item.path)))
                outcomes += Cleaner.clean([item], permanently: permanently, apps: apps, cancel: cancel) { _, _ in }
                // Logged after every item, before anything else can fail, so
                // whatever reached the Trash can always be put back, even if
                // Ballast quits halfway through.
                if var next = CleanupRecord(outcomes: outcomes, permanent: permanently) {
                    if let record {
                        next.id = record.id
                        next.date = record.date
                    }
                    log.update(next)
                    record = next
                }
            }
            // Display paths, each remeasured in its own volume's index.
            var touched = outcomes.map(\.item.path)
            for outcome in outcomes {
                if case .uninstall(_, let data) = outcome.item.action { touched += data }
            }
            let emptiesTrash = items.contains { $0.action == .emptyTrash }
            if outcomes.contains(where: { !$0.moves.isEmpty }) || emptiesTrash {
                touched.append(NSHomeDirectory() + "/.Trash")
            }
            if emptiesTrash { touched += Drives.trashes() }
            let measured = Remeasure.run(touched, volumes: volumes, report: report)
            return Cleaned(outcomes: outcomes, record: record, log: log.load(), measured: measured)
        }
        guard let cleaned = outcome.value else { return }
        let outcomes = cleaned.outcomes

        let done = Set(outcomes.filter(\.succeeded).map(\.item.id))
        if !done.isEmpty { plan.removeAll { done.contains($0.id) } }
        let trashed = outcomes
            .filter { $0.succeeded && !$0.moves.isEmpty }
            .reduce(0) { $0 + $1.item.bytes }
        // The startup disk as the Overview counts it, plus drives cleaned on.
        let drivesAfter = driveFree(Array(drivesBefore.keys))
        let driveFreed = drivesBefore.reduce(0) { $0 + max((drivesAfter[$1.key] ?? $1.value) - $1.value, 0) }
        let freed = max(freeBytes - freeBefore, 0) + driveFreed
        cleanupLog = cleaned.log
        putBackReport = nil
        lastClean = CleanReport(outcomes: outcomes, freed: freed, movedToTrash: trashed, record: cleaned.record)
        let succeeded = outcomes.filter(\.succeeded)
        if !succeeded.isEmpty {
            telemetry.record(.cleanupCompleted(items: CountBucket(succeeded.count),
                                               freed: SizeBucket(bytes: succeeded.reduce(0) { $0 + $1.item.bytes }),
                                               method: permanently ? .delete : .trash, source: .manual))
        }
        if !cleaned.measured {
            // The index still lists what's gone: the next update fixes it.
            needsUpdate = true
            kickPendingUpdate()
        }
        let free = freeBytes
        history = await Self.onFileQueue { History.record(free: free, freed: freed) }
        saveSnapshot()
    }

    func dismissCleanReport() {
        lastClean = nil
    }

    /// Stops a cleanup in progress after the item it's on and waits for it
    /// (at most `timeout`), e.g. at quit: every moved item is already in
    /// the Trash log by then.
    func finishCleaning(timeout: Duration) async {
        guard isCleaning else { return }
        cancelScan()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.awaitIdle() }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Writes what's waiting to be saved, at quit.
    func flushPendingWrites() {
        preferencesSave?.cancel()
        if preferencesDirty {
            preferencesDirty = false
            preferences.save()
        }
        autoCleanSave?.cancel()
        if autoCleanDirty {
            autoCleanDirty = false
            autoClean.save()
        }
        telemetry.store.synchronize()
    }

    // MARK: Auto-clean

    /// Rules and the background toggle; saved a moment after they change.
    /// Read before the first frame like `preferences` (Settings shows it).
    var autoClean = AutoCleanSettings.load() {
        didSet {
            guard autoClean != oldValue else { return }
            scheduleAutoCleanSave()
            if autoClean.background != oldValue.background { noteSetting(.autoCleanBackground, .on(autoClean.background)) }
            if autoClean.rules != oldValue.rules { noteSetting(.autoCleanRules, nil) }
            if autoClean.background && !oldValue.background { Notify.requestPermission() }
            scheduleAgentSync()
            Task { await recomputeVerdicts(reassess: false) }
        }
    }
    /// Every confirmed build folder, for rule previews and grouping.
    private(set) var artifacts: [Artifact] = []
    private(set) var lastAutoClean: AutoCleanRun?

    /// What the current rules would clean right now: due by age and safe
    /// to remove, exactly what a run would pick. Recomputed only when the
    /// rules, the index or the running apps change, never per redraw.
    private(set) var autoCleanDue: [(Artifact, AutoCleanRule)] = []

    @ObservationIgnored private var autoCleanSave: Task<Void, Never>?
    @ObservationIgnored private var autoCleanDirty = false

    private func scheduleAutoCleanSave() {
        autoCleanDirty = true
        let previous = autoCleanSave
        previous?.cancel()
        autoCleanSave = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await previous?.value
            await saveAutoCleanNow()
        }
    }

    /// Saves the rules now if a save is waiting: a run reads them from the file.
    private func saveAutoCleanNow() async {
        guard autoCleanDirty else { return }
        autoCleanDirty = false
        let settings = autoClean
        await Task.detached(priority: .utility) { settings.save() }.value
    }

    /// Runs the enabled rules now. A dry run only reports what they would
    /// clean (it still brings the index up to date first).
    /// `source` says who asked: Settings' Clean Now, or a Shortcuts action.
    @discardableResult
    func runAutoCleanNow(dryRun: Bool = false, source: CleanSource = .autoClean) async -> AutoCleanRun? {
        autoCleanSave?.cancel()
        await saveAutoCleanNow()
        let apps = self.apps
        let outcome = await run(dryRun ? "Checking auto-clean rules" : "Auto-cleaning",
                                purpose: dryRun ? .other : .autoClean) { report, cancel in
            let run = try AutoClean.run(dryRun: dryRun, apps: apps, report: report, cancel: cancel)
            return (run: run, log: dryRun ? nil : TrashLog.standard.load(), history: dryRun ? nil : History.load())
        }
        guard let result = outcome?.value else { return nil }
        if !dryRun {
            lastAutoClean = result.run
            if let history = result.history { self.history = history }
            if let log = result.log { cleanupLog = log }
            saveSnapshot()
            if let event = TelemetryEvent.autoClean(result.run, settings: autoClean, source: source) { telemetry.record(event) }
        }
        return result.run
    }

    // MARK: Put Back

    /// Recent cleanups, oldest first (trash-log.json); loaded in start().
    private(set) var cleanupLog: [CleanupRecord] = []
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
    /// they went. Nil when it couldn't run (`errorMessage` says why).
    @discardableResult
    func putBack(_ id: UUID) async -> PutBackReport? {
        putBackReport = nil
        let volumes = disks.compactMap(\.mounted)
        let outcome = await run("Putting back", purpose: .putBack, reloading: .all) { report, _ -> (PutBackReport?, [CleanupRecord]) in
            let log = TrashLog.standard
            guard var record = log.load().first(where: { $0.id == id }) else { return (nil, log.load()) }
            let result = PutBack.run(&record)
            log.update(record)
            var touched = Set(result.restored.map { ($0.from as NSString).deletingLastPathComponent })
            if !result.restored.isEmpty { touched.insert(NSHomeDirectory() + "/.Trash") }
            _ = Remeasure.run(Array(touched), volumes: volumes, report: report)
            return (PutBackReport(recordID: id, restored: result.restored.count, problems: result.problems), log.load())
        }
        guard let (report, log) = outcome?.value else { return nil }
        cleanupLog = log
        putBackReport = report
        if let report, report.restored > 0 { telemetry.record(.putBackUsed) }
        return report
    }

    @discardableResult
    func putBackLast() async -> PutBackReport? {
        guard let record = lastRestorable else { return nil }
        return await putBack(record.id)
    }

    // MARK: Unused apps & installers

    /// Apps not opened in `staleMonths`, biggest first.
    private(set) var unusedApps: [UnusedApp] = []
    /// Installers and disk images in Downloads, Desktop and Documents.
    private(set) var installers: [Installer] = []
    @ObservationIgnored private var appsRequest = 0
    @ObservationIgnored private var installersRequest = 0

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
        if let known = await reader(for: path, interactive: false)?.size(ofPath: path) { return known.bytes }
        return await Task.detached(priority: .utility) { Cleaner.measure(path).bytes }.value
    }

    private func loadInstallers() async {
        installersRequest += 1
        let request = installersRequest
        let names = apps.installed.map(\.name)
        let found = await Task.detached(priority: .utility) { Installers.scan(apps: names) }.value
        guard request == installersRequest else { return }
        installers = found
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

    @ObservationIgnored private var agentSync: Task<Void, Never>?

    /// Installs or removes the LaunchAgents to match the settings, a second
    /// after the last change and off the main thread: `launchctl` is two
    /// process launches, and a rule stepper changes settings on every click.
    /// Nothing is rebootstrapped unless the plist itself changes.
    private func scheduleAgentSync() {
        let previous = agentSync
        previous?.cancel()
        agentSync = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await previous?.value
            let autoClean = autoClean.background && autoClean.anyEnabled
            let preferences = preferences
            await Task.detached(priority: .utility) {
                if autoClean {
                    try? BackgroundAgent.autoClean.install()
                } else {
                    BackgroundAgent.autoClean.uninstall()
                }
                LowSpace.syncAgent(preferences)
            }.value
        }
    }

    // MARK: Duplicates

    enum DuplicateSearch {
        case idle
        case running(DuplicateProgress)
        case done(DuplicateReport)
        case failed(String)
    }

    /// Duplicate large files on the startup disk; searched only when asked.
    private(set) var duplicateSearch: DuplicateSearch = .idle
    /// The copy to keep in each group, where someone picked one.
    private(set) var duplicateKeep: [DuplicateGroup.ID: String] = [:]
    @ObservationIgnored private var duplicateCancel = CancelFlag()

    var isFindingDuplicates: Bool {
        if case .running = duplicateSearch { true } else { false }
    }

    /// Compares the startup disk's large files off the main thread. Files
    /// in protected places are left out: nothing there could be cleaned.
    func findDuplicates() async {
        guard !isFindingDuplicates, largeFiles.isComplete else { return }
        noteFeature(.duplicatesRun)
        let flag = CancelFlag()
        duplicateCancel = flag
        duplicateKeep = [:]
        duplicateSearch = .running(DuplicateProgress())
        let files = largeFiles.files
        let apps = self.apps
        let protected = preferences.protectedFolders
        // At most a few updates a second reach the main thread.
        let throttle = Throttle()
        let report: @Sendable (DuplicateProgress) -> Void = { progress in
            guard throttle.ready() else { return }
            Task { @MainActor in
                if case .running = self.duplicateSearch { self.duplicateSearch = .running(progress) }
            }
        }
        do {
            let found = try await Task.detached(priority: .userInitiated) {
                try Duplicates.find(files, isProtected: { path in
                    SafetyCheck.assess(path, isDirectory: false, apps: apps, protected: protected).level == .blocked
                }, cancel: flag, progress: report)
            }.value
            duplicateSearch = .done(found)
        } catch is CancellationError {
            duplicateSearch = .idle
        } catch {
            duplicateSearch = .failed(error.localizedDescription)
        }
    }

    func cancelDuplicates() {
        duplicateCancel.set()
    }

    func keptCopy(in group: DuplicateGroup) -> String {
        duplicateKeep[group.id] ?? group.suggestedKeep
    }

    /// Picks the copy to keep. It comes off the Cleanup List if it was on
    /// it, so the list never holds every copy.
    func keep(_ path: String, in group: DuplicateGroup) {
        duplicateKeep[group.id] = path
        plan.removeAll { $0.path == path }
    }

    /// Every copy but the kept one, each with what removing it frees.
    func duplicateItems(in group: DuplicateGroup) -> [PlanItem] {
        let kept = keptCopy(in: group)
        let freed = group.freed(keeping: kept)
        return group.copies.filter { $0.path != kept }.map { copy in
            makeItem(name: copy.name, path: copy.path, bytes: freed[copy.path] ?? 0, action: .remove, isDirectory: false)
        }
    }

    /// Adds every copy but the kept one; protected ones are skipped
    /// quietly, with the reason on their row.
    func addDuplicates(in group: DuplicateGroup) {
        for item in duplicateItems(in: group) where item.safety.level != .blocked && !isPlanned(item.path) {
            toggle(item)
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
            guard let size = await interactiveReader.size(ofPath: area.path), size.bytes > 100 << 20 else { continue }
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
        await refreshVolume()
        if outcome.freed > 0 {
            let free = freeBytes
            history = await Self.onFileQueue { History.record(free: free, freed: outcome.freed) }
        }
        refreshFreeSpace()
        await loadSystemData()
    }

    // MARK: What grew

    /// Folder sizes compared with an earlier day, for the Overview.
    private(set) var growth: GrowthSummary = .empty
    /// The period picked on the Overview; nil picks the first with data.
    var growthPeriod: GrowthPeriod? {
        didSet {
            guard growthPeriod != oldValue else { return }
            Task { await loadGrowth() }
            noteFeature(.whatGrewViewed)
        }
    }
    /// The first reading of a session keeps the previous one as "last open".
    @ObservationIgnored private var growthSessionStarted = false
    @ObservationIgnored private var growthRequest = 0

    /// Saves today's folder sizes, then compares. Runs after every change
    /// to the index, so a cleanup shows up as freed space right away.
    private func recordGrowth() async {
        guard hasIndex else { return }
        growthRequest += 1
        let request = growthRequest
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
        // A newer reading, or another period picked meanwhile, wins.
        guard let summary, request == growthRequest, period == growthPeriod else { return }
        await show(summary)
    }

    private func loadGrowth() async {
        growthRequest += 1
        let request = growthRequest
        let period = growthPeriod
        let summary = await Task.detached(priority: .userInitiated) { () -> GrowthSummary? in
            guard FileManager.default.fileExists(atPath: Paths.growth), let store = try? GrowthStore() else { return nil }
            return try? Growth.summary(store, period: period)
        }.value
        guard request == growthRequest, period == growthPeriod else { return }
        await show(summary ?? .empty)
    }

    /// Shows a growth summary with its rows' verdicts ready.
    private func show(_ summary: GrowthSummary) async {
        let request = growthRequest
        var input = verdictInput()
        input.plan = []
        input.startup = []
        input.artifacts = []
        input.hotspots = []
        input.growth = summary.report?.grew ?? []
        let verdicts = await Task.detached(priority: .utility) { Verdicts.compute(input) }.value
        guard request == growthRequest else { return }
        itemCache.merge(verdicts.items) { $1 }
        canRemoveCache.merge(verdicts.canRemove) { $1 }
        growth = summary
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
            guard let reader = explorerReader else { return }
            let (trail, children, files) = await reader.explore(id)
            guard request == exploreRequest, !trail.isEmpty else { return }
            self.trail = trail
            self.children = children
            folderFiles = files
        }
    }

    /// Opens a folder by display path, e.g. from a Cleanup row, switching
    /// to the drive it's on.
    func open(path: String) async {
        let disk = disk(holding: path)
        if disk != selectedDisk { await selectDisk(disk) }
        let volumePath = disk == .startup ? Paths.onVolume(path) : path
        if let id = await explorerReader?.deepest(volumePath) { open(id) }
    }

    /// Opens a folder in the Explorer from another screen, e.g. the Cleanup List.
    func showInExplorer(_ path: String) {
        Task { await open(path: path) }
        requestedPane = .explorer
    }

    /// Folders anywhere on the disk whose name contains `text`.
    func search(_ text: String) async -> [SearchHit] {
        noteFeature(.explorerSearch)
        return await explorerReader?.search(text) ?? []
    }

    /// The open folder's children, for File › Export….
    var explorerExport: [ExportRow] {
        let whole = trail.last?.total ?? 0
        return children.compactMap { row in displayPath(of: row).map { ExportRow(path: $0, row: row, of: whole) } }
    }

    /// Largest folders on the disk on screen, for File › Export… on the Overview.
    var hotspotExport: [ExportRow] {
        let whole = activeOverview?.root.total ?? 0
        return activeHotspots.map { ExportRow(path: $0.path, row: $0.row, of: whole) }
    }

    var activeHotspots: [Hotspot] {
        selectedDisk == .startup ? hotspots : diskHotspots
    }

    /// Large files on the disk on screen.
    var activeLargeFiles: LargeFileList {
        selectedDisk == .startup ? largeFiles : diskLargeFiles
    }

    /// Explorer is on screen; set while it is, so a reload can fill it.
    @ObservationIgnored var isExplorerShown = false

    private func openRootIfShown() {
        if isExplorerShown { openRootIfIdle() }
    }

    /// Shows the disk root unless a folder is already open or on its way.
    func openRootIfIdle() {
        guard trail.isEmpty, exploring == 0, let root = activeOverview?.root else { return }
        open(root.id)
    }

    func path(of id: Int64) async -> String? {
        await explorerReader?.path(of: id).map(Paths.display)
    }

    /// Where a folder is, for row details: "~/Library", "Macintosh HD",
    /// or "Drive/projects" on another drive.
    func location(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if parent == "/" { return Paths.volumeName }
        if let disk = disks.filter({ parent == $0.path || parent.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }) {
            return disk.name + parent.dropFirst(disk.path.count)
        }
        return parent.replacingOccurrences(of: Catalog.home, with: "~")
    }

    /// Display path of the open folder or one of its children.
    func displayPath(of row: DirRow) -> String? {
        guard let index = trail.firstIndex(where: { $0.id == row.id || $0.id == row.parent }) else { return nil }
        var names = trail[...index].map(\.name)
        if trail[index].id != row.id { names.append(row.name) }
        return Paths.display(names.joined(separator: "/"))
    }

    // MARK: Other disks

    /// Volumes other than the startup disk: connected ones and ones with an
    /// index, which stay listed while unplugged.
    private(set) var disks: [Disk] = []
    /// Connected volumes Ballast can't index (network drives), with why.
    private(set) var unsupportedDisks: [UnsupportedVolume] = []
    /// The disk Overview and Explorer show.
    private(set) var selectedDisk: DiskID = .startup
    /// The selected other disk's index, when it has one.
    private(set) var diskOverview: Overview?
    private(set) var diskHotspots: [Hotspot] = []
    private(set) var diskLargeFiles: LargeFileList = .empty
    /// Readers for every other disk with an index, by UUID.
    @ObservationIgnored private var diskReaders: [String: IndexReader] = [:]
    /// Mount point of the drive a running scan reads: ejecting it stops the
    /// scan, so the eject isn't refused as "in use".
    @ObservationIgnored private var scanningDrive: String?
    /// The other disk being scanned, for its Overview.
    private(set) var scanningDisk: String?
    /// The volume refresh in flight, and whether another was asked for
    /// while it ran: mount events come in bursts.
    @ObservationIgnored private var disksRefresh: Task<Void, Never>?
    @ObservationIgnored private var disksDirty = false

    var selectedDiskInfo: Disk? {
        selectedDisk.uuid.flatMap { uuid in disks.first { $0.uuid == uuid } }
    }

    /// Disks listed in the sidebar: removable ones only if Settings says so,
    /// but always the one on screen.
    var sidebarDisks: [Disk] {
        disks.filter { preferences.showRemovableDrives || !$0.isRemovable || selectedDisk == .volume($0.uuid) }
    }

    /// The selected disk's index as Overview and Explorer read it.
    var activeOverview: Overview? {
        selectedDisk == .startup ? overview : diskOverview
    }

    /// Build folders found on a drive, as Suggestions lists them.
    func buildBytes(on disk: Disk) -> Int64 {
        driveCleanup.filter { $0.target.path.hasPrefix(disk.path + "/") }.reduce(0) { $0 + $1.bytes }
    }

    var activeDiskName: String {
        selectedDiskInfo?.name ?? Paths.volumeName
    }

    private var explorerReader: IndexReader? {
        switch selectedDisk {
        case .startup: interactiveReader
        case .volume(let uuid): diskReaders[uuid]
        }
    }

    /// The index a display path is in. `interactive` picks the startup
    /// disk's connection for queries someone is waiting on.
    private func reader(for path: String, interactive: Bool) -> IndexReader? {
        switch disk(holding: path) {
        case .startup: interactive ? interactiveReader : reader
        case .volume(let uuid): diskReaders[uuid]
        }
    }

    /// The disk a display path is on: a connected disk whose mount point
    /// holds it, or the startup disk.
    func disk(holding path: String) -> DiskID {
        let holder = disks.filter { $0.isConnected && (path == $0.path || path.hasPrefix($0.path + "/")) }
            .max { $0.path.count < $1.path.count }
        return holder.map { .volume($0.uuid) } ?? .startup
    }

    /// Switches Overview and Explorer to another disk.
    func selectDisk(_ disk: DiskID) async {
        guard disk != selectedDisk else { return }
        selectedDisk = disk
        exploreRequest += 1
        trail = []
        children = []
        folderFiles = nil
        await loadSelectedDisk()
        openRootIfShown()
    }

    /// Re-reads which volumes are mounted and which have an index. Runs at
    /// launch and whenever a volume is mounted, unmounted or renamed. Calls
    /// that arrive while one runs are folded into one more pass.
    func refreshDisks() async {
        disksDirty = true
        if let running = disksRefresh {
            await running.value
            return
        }
        let task = Task {
            while disksDirty {
                disksDirty = false
                await refreshDisksOnce()
            }
            disksRefresh = nil
        }
        disksRefresh = task
        await task.value
    }

    private func refreshDisksOnce() async {
        let (mounted, unsupported) = await Task.detached(priority: .utility) { () -> ([MountedVolume], [UnsupportedVolume]) in
            let found = Volumes.mounted()
            // A drive back under another name ("Drive 1") keeps its index.
            for volume in found.indexable { if let target = IndexTarget.volume(volume) { ScanEngine.adopt(target) } }
            return (found.indexable, found.unsupported)
        }.value
        let known = await Task.detached(priority: .utility) { Volumes.known() }.value
        disks = Disk.list(mounted: mounted, known: known)
        unsupportedDisks = unsupported

        // Unplugged disks keep a reader, so their last scan can be browsed.
        let indexed = Set(known.map(\.uuid))
        for uuid in diskReaders.keys where !indexed.contains(uuid) { diskReaders[uuid] = nil }
        for uuid in indexed where diskReaders[uuid] == nil {
            if let index = Paths.volumeIndex(uuid) {
                let reader = IndexReader(index: index, isStartup: false)
                await reader.reopen()
                diskReaders[uuid] = reader
            }
        }
        if let uuid = selectedDisk.uuid, !disks.contains(where: { $0.uuid == uuid }) {
            selectedDisk = .startup
            trail = []
            children = []
            folderFiles = nil
            openRootIfShown()
        }
        await loadDriveArtifacts()
        await loadSelectedDisk()
    }

    /// Build folders on connected, writable drives that have an index.
    private func loadDriveArtifacts() async {
        var found: [ScanResult] = []
        for disk in disks where disk.isConnected && disk.isScanned && !disk.isReadOnly {
            if let reader = diskReaders[disk.uuid] { found += await reader.artifactSuggestions() }
        }
        // Verdicts first, so Suggestions rows don't work them out on screen.
        var input = verdictInput()
        input.plan = []
        input.startup = found
        input.artifacts = []
        input.hotspots = []
        input.growth = []
        let verdicts = await Task.detached(priority: .utility) { Verdicts.compute(input) }.value
        itemCache.merge(verdicts.items) { $1 }
        setCleanup(drives: found)
    }

    private func loadSelectedDisk() async {
        guard let uuid = selectedDisk.uuid, let reader = diskReaders[uuid] else {
            diskOverview = nil
            diskHotspots = []
            diskLargeFiles = .empty
            return
        }
        let overview = await reader.overview()
        // Drives are often small: a folder counts as large from a twentieth
        // of what's on it, up to the startup disk's 1 GB.
        let floor = min(Int64(1) << 30, max((overview?.root.total ?? 0) / 20, 1 << 20))
        let hotspots = await reader.hotspots(atLeast: floor)
        let files = await reader.largeFiles()
        guard selectedDisk == .volume(uuid) else { return }
        diskOverview = overview
        diskHotspots = hotspots
        diskLargeFiles = files
    }

    /// After disks' scans: their index files may be new, and the Explorer
    /// keeps its place by path. One volume refresh for all of them.
    private func reloadDisks(_ uuids: [String]) async {
        let selected = selectedDisk.uuid.flatMap { uuids.contains($0) ? $0 : nil }
        var openPath: String?
        if let selected, let open = trail.last { openPath = await diskReaders[selected]?.path(of: open.id) }
        for uuid in uuids { await diskReaders[uuid]?.reopen() }
        await refreshDisks()
        guard let selected, selectedDisk == .volume(selected) else { return }
        if let openPath, let id = await diskReaders[selected]?.deepest(openPath) {
            open(id)
        } else if openPath != nil {
            trail = []
            children = []
            folderFiles = nil
        }
        openRootIfShown()
    }

    /// Scans a connected drive, only ever because someone asked: brings its
    /// index up to date from the drive's change log where it keeps one
    /// (APFS, Mac OS Extended), or walks the whole drive.
    func scanDisk(_ uuid: String, full: Bool = false) async {
        guard let disk = disks.first(where: { $0.uuid == uuid }), let volume = disk.mounted,
              let target = IndexTarget.volume(volume) else { return }
        let incremental = !full && disk.isScanned && volume.isJournaled
        let files = selectedDisk == .volume(uuid) ? diskOverview?.root.files ?? 0 : 0
        let title = incremental ? "Checking what changed on \(volume.name)" : target.scanTitle
        guard let ticket = await acquire(.user, title, purpose: .scan) else { return }
        scanningDrive = volume.path
        scanningDisk = uuid
        defer {
            scanningDrive = nil
            scanningDisk = nil
        }
        let scanned = await execute(ticket, reloading: .disk(uuid), expecting: (target.scanTitle, files)) { report, cancel in
            if incremental {
                do {
                    try ScanEngine.update(target, report: report, cancel: cancel)
                    return
                } catch ScanEngine.Failure.needsFullScan {}
            }
            try ScanEngine.fullScan(target, report: report, cancel: cancel)
        }
        if scanned.value != nil { noteFeature(.diskScanned) }
    }

    /// Update or rescan whatever disk is on screen (⌘R, the toolbar).
    func updateSelectedDisk() async {
        switch selectedDisk {
        case .startup: await update()
        case .volume(let uuid): await scanDisk(uuid)
        }
    }

    func rescanSelectedDisk() async {
        switch selectedDisk {
        case .startup: await fullScan()
        case .volume(let uuid): await scanDisk(uuid, full: true)
        }
    }

    /// Deletes a drive's index; nothing on the drive is touched. Waits its
    /// turn like a scan, so it can't pull an index out from under one.
    func forgetDisk(_ uuid: String) async {
        guard let ticket = await acquire(.user, "Forgetting a drive", purpose: .other) else { return }
        if selectedDisk == .volume(uuid) { await selectDisk(.startup) }
        diskReaders[uuid] = nil
        _ = await execute(ticket, reloading: .none) { _, _ in try Volumes.forget(uuid) }
        await refreshDisks()
    }

    private func watchVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willUnmountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didMountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
                let unmounting = note.name == NSWorkspace.willUnmountNotification
                MainActor.assumeIsolated { self?.volumeChanged(path: path, unmounting: unmounting) }
            }
        }
    }

    private func volumeChanged(path: String?, unmounting: Bool) {
        // Stop reading a drive that's about to go, so the eject goes
        // through; a forced one ends the walk with an error instead.
        if let path, let scanningDrive, path == scanningDrive || path.hasPrefix(scanningDrive + "/") {
            cancelFlag.set()
        }
        if !unmounting { Task { await refreshDisks() } }
    }

    /// Free space on the connected drives holding these display paths,
    /// by mount point.
    private func driveFree(_ paths: [String]) -> [String: Int64] {
        var free: [String: Int64] = [:]
        for disk in disks where disk.isConnected && paths.contains(where: { $0 == disk.path || $0.hasPrefix(disk.path + "/") }) {
            free[disk.path] = Volumes.freeBytes(at: disk.path)
        }
        return free
    }

    // MARK: Loading

    @ObservationIgnored private var reloadRequest = 0
    @ObservationIgnored private var cleanupRequest = 0

    /// Re-reads the startup disk's index. Everything is worked out first
    /// (safety verdicts included, off the main thread) and assigned in one
    /// go, so screens redraw once; a newer reload makes an older one stop.
    private func reload() async {
        reloadRequest += 1
        let request = reloadRequest
        cleanupRequest += 1
        let cleanupToken = cleanupRequest
        // Remember the open folder by path: a full scan renumbers every row.
        var openPath: String?
        if selectedDisk == .startup, let open = trail.last { openPath = await interactiveReader.path(of: open.id) }

        await reader.reopen()
        await interactiveReader.reopen()
        let overview = await reader.overview()
        let hotspots = await reader.hotspots()
        let largeFiles = await reader.largeFiles()
        let startup = await reader.cleanup(staleMonths: preferences.staleMonths)
        let artifacts = await reader.allArtifacts()
        var input = verdictInput()
        input.startup = startup
        input.artifacts = artifacts
        input.hotspots = hotspots
        input.growth = []
        let verdicts = await Task.detached(priority: .userInitiated) { Verdicts.compute(input) }.value
        guard request == reloadRequest else { return }

        self.overview = overview
        if let files = overview?.root.files, files > 0 { expectedFiles = files }
        self.hotspots = hotspots
        self.largeFiles = largeFiles
        self.artifacts = artifacts
        if cleanupToken == cleanupRequest {
            apply(verdicts, replacingCache: false)
            setCleanup(startup: startup)
        } else {
            itemCache.merge(verdicts.items) { $1 }
            canRemoveCache.merge(verdicts.canRemove) { $1 }
        }
        // Slower than the index; the lists fill in when ready.
        if hasIndex {
            Task { await loadUnusedApps() }
            Task { await loadInstallers() }
        }

        if let openPath, let id = await interactiveReader.deepest(openPath) {
            open(id)
        } else if openPath != nil {
            trail = []
            children = []
            folderFiles = nil
        }
        // Explorer may have asked for the root while this was loading:
        // clearing here would leave it empty.
        openRootIfShown()
        if hasIndex {
            let free = freeBytes
            history = await Self.onFileQueue { History.record(free: free) }
        }
        saveSnapshot()
        await recordGrowth()
    }

    /// Suggestions again, e.g. after the "untouched for" setting changed.
    /// The last one asked for wins.
    private func reloadSuggestions() async {
        cleanupRequest += 1
        let request = cleanupRequest
        let startup = await reader.cleanup(staleMonths: preferences.staleMonths)
        var input = verdictInput()
        input.startup = startup
        let verdicts = await Task.detached(priority: .userInitiated) { Verdicts.compute(input) }.value
        guard request == cleanupRequest else { return }
        apply(verdicts, replacingCache: false)
        setCleanup(startup: startup)
        saveSnapshot()
    }

    /// After an update that changed nothing: only "updated … ago" moves.
    private func refreshOverview() async {
        guard let fresh = await reader.overview() else { return }
        overview = fresh
        saveSnapshot()
    }

    @ObservationIgnored private var volumeRequest = 0
    @ObservationIgnored private var volumeShown = 0

    /// Reads free space off the main thread: the figure the Overview and
    /// Finder show asks the CacheDelete daemon, which can take a while. The
    /// very first reading uses statfs so the window never opens at zero.
    private func refreshVolume() async {
        if totalBytes == 0, let quick = Self.quickCapacity() {
            freeBytes = quick.free
            totalBytes = quick.total
        }
        volumeRequest += 1
        let request = volumeRequest
        guard let reading = await Task.detached(priority: .userInitiated, operation: { Volume.capacity }).value,
              request > volumeShown else { return }
        volumeShown = request
        if freeBytes != reading.free { freeBytes = reading.free }
        if totalBytes != reading.total { totalBytes = reading.total }
    }

    /// statfs on the data volume: instant, without purgeable space.
    private nonisolated static func quickCapacity() -> (free: Int64, total: Int64)? {
        var info = statfs()
        guard statfs(Paths.volumeRoot, &info) == 0 else { return nil }
        let block = Int64(info.f_bsize)
        return (Int64(info.f_bavail) * block, Int64(info.f_blocks) * block)
    }

    // MARK: Files

    /// History and other small files the app and the agents share, read
    /// and written in order, off the main thread.
    private static let fileQueue = DispatchQueue(label: "dev.mamad.Ballast.files", qos: .utility)

    private static func onFileQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            fileQueue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: Status

    /// What the Overview shows, in the form other surfaces read.
    var snapshot: StatusSnapshot {
        StatusSnapshot(
            date: .now,
            volumeName: Paths.volumeName,
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            segments: overview.map { StatusSnapshot.segments(overview: $0, cleanup: startupCleanup, used: usedBytes) } ?? [],
            safeToClean: reclaimable,
            freedLastWeek: History.freed(in: history),
            scannedAt: overview?.scannedAt
        )
    }

    /// status.json and the widget reload, in order, off the main thread.
    private static let snapshotQueue = DispatchQueue(label: "dev.mamad.Ballast.snapshot", qos: .utility)

    /// Saves status.json after anything that changes the figures.
    private func saveSnapshot() {
        guard totalBytes > 0 else { return }
        let snapshot = self.snapshot
        Self.snapshotQueue.async { snapshot.publish() }
    }

    @ObservationIgnored private var freeSpaceRefresh: Task<Void, Never>?

    /// A fresh free-space reading (no scan), then the low-space check. Runs
    /// every few minutes and whenever the menu bar item opens; a call while
    /// one is in flight is covered by it.
    func refreshFreeSpace() {
        guard freeSpaceRefresh == nil else { return }
        freeSpaceRefresh = Task {
            await refreshVolume()
            freeSpaceRefresh = nil
            guard totalBytes > 0 else { return }
            let snapshot = self.snapshot
            let preferences = self.preferences
            // Posting waits for the notification center: keep it off the main thread.
            Self.snapshotQueue.async {
                snapshot.publish()
                LowSpace.check(snapshot, preferences: preferences)
            }
        }
    }

    /// Keeps free space current while Ballast runs with no window open, and
    /// the index with it (see `IndexRefresh`).
    private func watchFreeSpace() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                self?.refreshFreeSpace()
                await self?.updateIfDue()
            }
        }
    }

    /// A background update when the index is old or free space moved a
    /// lot, unless anything runs or the last ones failed (see `UpdateBackoff`).
    private func updateIfDue() async {
        guard activeRun == nil, updateBackoff.allowsAttempt(at: .now), let scannedAt = overview?.scannedAt else { return }
        let freeChange = freeBytes - (freeAtUpdate ?? freeBytes)
        guard IndexRefresh.isDue(age: Date.now.timeIntervalSince(scannedAt), freeChange: freeChange) else { return }
        await update(.background)
    }
}
