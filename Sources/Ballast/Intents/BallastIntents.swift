import AppIntents
import BallastCore
import Foundation

// Shortcuts, Siri and Spotlight actions. They run in the app's process: the
// system launches Ballast if it isn't running. Each is a thin layer over
// what the app already does, with the same safety checks; nothing here
// cleans more than the Cleanup List or your auto-clean rules would.
//
// scripts/bundle.sh extracts their metadata (Metadata.appintents) from the
// compiler's const values, the way Xcode does; without it the system never
// sees them. Keep titles, phrases and display representations literals.

/// A plain sentence for Shortcuts when an action can't do its job.
struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

private func storage(_ bytes: Int64) -> Measurement<UnitInformationStorage> {
    Measurement(value: Double(bytes), unit: .bytes)
}

// MARK: Reading

struct GetFreeSpaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Free Space"
    static let description = IntentDescription(
        "Free space on the startup disk, counted the way Finder and Ballast's Overview count it.",
        categoryName: "Disk")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ReturnsValue<Measurement<UnitInformationStorage>> & ProvidesDialog {
        guard let volume = DiskCapacity.current else {
            throw IntentFailure(message: "Ballast couldn't read the startup disk's free space.")
        }
        return .result(value: storage(volume.free),
                       dialog: "\(IntentText.freeSpace(free: volume.free, total: volume.total))")
    }
}

/// The Overview's figures, for Shortcuts to use one by one.
struct DiskStatusEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Disk Status"

    @Property(title: "Disk") var volumeName: String
    @Property(title: "Free") var free: Measurement<UnitInformationStorage>
    @Property(title: "Capacity") var total: Measurement<UnitInformationStorage>
    @Property(title: "Safe to Clean") var safeToClean: Measurement<UnitInformationStorage>
    @Property(title: "Last Scan") var lastScan: Date?

    init() {
        volumeName = ""
        free = storage(0)
        total = storage(0)
        safeToClean = storage(0)
        lastScan = nil
    }

    var displayRepresentation: DisplayRepresentation {
        let free = Int64(free.value).compactBytes
        let total = Int64(total.value).compactBytes
        return DisplayRepresentation(title: "\(free) free of \(total)", subtitle: "\(volumeName)")
    }
}

struct GetDiskStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Disk Status"
    static let description = IntentDescription(
        "Free space, capacity, what's safe to clean and when Ballast last scanned the disk.",
        categoryName: "Disk")
    static let supportedModes: IntentModes = .background

    func perform() async throws -> some IntentResult & ReturnsValue<DiskStatusEntity> & ProvidesDialog {
        guard let volume = DiskCapacity.current else {
            throw IntentFailure(message: "Ballast couldn't read the startup disk's free space.")
        }
        // Free space is read now; the rest is what the last scan found,
        // as saved for the menu bar item and the widget.
        let saved = StatusSnapshot.load()
        let scannedAt = saved?.scannedAt
        let safe = scannedAt == nil ? 0 : saved?.safeToClean ?? 0
        let status = DiskStatusEntity()
        status.volumeName = DiskCapacity.volumeName
        status.free = storage(volume.free)
        status.total = storage(volume.total)
        status.safeToClean = storage(safe)
        status.lastScan = scannedAt
        let text = IntentText.status(free: volume.free, total: volume.total, safeToClean: safe, scannedAt: scannedAt)
        return .result(value: status, dialog: "\(text)")
    }
}

// MARK: Index

struct UpdateDiskIndexIntent: AppIntent, ProgressReportingIntent {
    static let title: LocalizedStringResource = "Update Disk Index"
    static let description = IntentDescription(
        "Brings Ballast's map of the disk up to date from the changes macOS logged, or rescans the whole disk when it has to.",
        categoryName: "Disk")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        await model.start()
        await model.awaitIdle()

        // A full scan has a percentage; an update is short and has none.
        progress.totalUnitCount = 100
        let progress = self.progress
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if let fraction = model.progress { progress.completedUnitCount = Int64(fraction * 100) }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        let updated = await model.update()
        watcher.cancel()
        progress.completedUnitCount = 100

        guard updated else {
            throw IntentFailure(message: model.errorMessage ?? "The disk index couldn't be updated.")
        }
        let text = IntentText.updated(free: model.freeBytes, total: model.totalBytes, safeToClean: model.reclaimable)
        return .result(dialog: "\(text)")
    }
}

// MARK: Cleaning

/// What Run Auto-Clean did or would do.
struct AutoCleanSummaryEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Auto-Clean Result"

    @Property(title: "Build Folders") var folders: Int
    @Property(title: "Size") var size: Measurement<UnitInformationStorage>
    @Property(title: "Preview Only") var previewOnly: Bool

    init() {
        folders = 0
        size = storage(0)
        previewOnly = true
    }

    init(_ run: AutoCleanRun) {
        self.init()
        folders = run.cleaned.count
        size = storage(run.cleanedBytes)
        previewOnly = run.dryRun
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(IntentText.folders(folders)), \(Int64(size.value).compactBytes)",
                              subtitle: previewOnly ? "Preview" : "Cleaned")
    }
}

struct RunAutoCleanIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Auto-Clean"
    static let description = IntentDescription(
        "Runs your auto-clean rules now, or with Preview Only on, lists what they would clean. Only the build folders your rules cover are touched, each checked again before it's removed.",
        categoryName: "Cleanup")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Preview Only", description: "List what the rules would clean without removing anything.", default: true)
    var dryRun: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Run auto-clean rules") {
            \.$dryRun
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AutoCleanSummaryEntity> & ProvidesDialog {
        let settings = AutoCleanSettings.load()
        guard settings.anyEnabled else {
            return .result(value: AutoCleanSummaryEntity(), dialog: "\(IntentText.noRules)")
        }
        let model = AppModel.shared
        await model.start()
        await model.awaitIdle()

        // Always look first: the preview is the answer, or what to confirm.
        guard let preview = await model.runAutoCleanNow(dryRun: true) else {
            throw IntentFailure(message: model.errorMessage ?? "Ballast couldn't check the auto-clean rules.")
        }
        if dryRun || preview.cleaned.isEmpty {
            return .result(value: AutoCleanSummaryEntity(preview), dialog: "\(IntentText.autoClean(preview))")
        }

        try await requestConfirmation(
            actionName: .run,
            dialog: "\(IntentText.autoCleanConfirmation(preview, settings: settings))")
        await model.awaitIdle()
        guard let run = await model.runAutoCleanNow(dryRun: false, source: .shortcut) else {
            throw IntentFailure(message: model.errorMessage ?? "Auto-clean couldn't run.")
        }
        return .result(value: AutoCleanSummaryEntity(run), dialog: "\(IntentText.autoClean(run))")
    }
}

struct PutBackLastCleanupIntent: AppIntent {
    static let title: LocalizedStringResource = "Put Back Last Cleanup"
    static let description = IntentDescription(
        "Moves the items of the most recent cleanup that still has any in the Trash back where they were. Nothing is ever overwritten.",
        categoryName: "Cleanup")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let model = AppModel.shared
        await model.awaitIdle()
        // A background auto-clean may have logged a newer cleanup.
        model.reloadCleanupLog()
        guard let record = model.lastRestorable else {
            return .result(value: 0, dialog: "\(IntentText.nothingToPutBack)")
        }
        try await requestConfirmation(actionName: .continue, dialog: "\(IntentText.putBackConfirmation(record))")
        await model.awaitIdle()
        guard let report = await model.putBack(record.id) else {
            throw IntentFailure(message: model.errorMessage ?? "Ballast couldn't put the cleanup back.")
        }
        return .result(value: report.restored, dialog: "\(IntentText.putBack(report))")
    }
}

// MARK: Opening

extension Pane: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Screen"
    static let caseDisplayRepresentations: [Pane: DisplayRepresentation] = [
        .overview: DisplayRepresentation(title: "Overview", image: .init(systemName: "internaldrive")),
        .explorer: DisplayRepresentation(title: "Explorer", image: .init(systemName: "square.grid.3x3.topleft.filled")),
        .cleanup: DisplayRepresentation(title: "Suggestions", image: .init(systemName: "lightbulb")),
    ]
}

struct OpenBallastIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Ballast"
    static let description = IntentDescription("Opens Ballast's window on the screen you pick.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Screen", default: .overview)
    var screen: Pane

    static var parameterSummary: some ParameterSummary {
        Summary("Open Ballast to \(\.$screen)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Set first: a window that's still opening picks it up on appear.
        AppModel.shared.requestedPane = screen
        MainWindow.show()
        return .result()
    }
}

// MARK: Siri and Spotlight

struct BallastShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetFreeSpaceIntent(),
            phrases: [
                "How much space is free in \(.applicationName)",
                "Get free space in \(.applicationName)",
                "\(.applicationName) free space",
            ],
            shortTitle: "Free Space",
            systemImageName: "internaldrive"
        )
        AppShortcut(
            intent: GetDiskStatusIntent(),
            phrases: [
                "Get disk status from \(.applicationName)",
                "\(.applicationName) disk status",
            ],
            shortTitle: "Disk Status",
            systemImageName: "chart.bar.horizontal.page"
        )
        AppShortcut(
            intent: UpdateDiskIndexIntent(),
            phrases: [
                "Update \(.applicationName) index",
                "Refresh \(.applicationName)",
            ],
            shortTitle: "Update Index",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: RunAutoCleanIntent(),
            phrases: [
                "Run \(.applicationName) auto-clean",
                "Preview \(.applicationName) auto-clean",
            ],
            shortTitle: "Auto-Clean",
            systemImageName: "wand.and.sparkles"
        )
        AppShortcut(
            intent: PutBackLastCleanupIntent(),
            phrases: [
                "Put back the last \(.applicationName) cleanup",
                "Undo the last \(.applicationName) cleanup",
            ],
            shortTitle: "Put Back",
            systemImageName: "arrow.uturn.backward"
        )
        AppShortcut(
            intent: OpenBallastIntent(),
            phrases: [
                "Open \(\.$screen) in \(.applicationName)",
                "Show \(.applicationName) \(\.$screen)",
            ],
            shortTitle: "Open Ballast",
            systemImageName: "internaldrive"
        )
    }
}
