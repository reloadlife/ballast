import AppIntents
import Foundation
import Testing
@testable import Ballast

/// What the Shortcuts actions say and return.
@Suite struct IntentTextTests {
    private let gb: Int64 = 1_000_000_000
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func run(dryRun: Bool, cleaned: [(ArtifactKind, Int64)], failed: Int = 0, skipped: Int = 0) -> AutoCleanRun {
        var run = AutoCleanRun(dryRun: dryRun)
        run.entries = cleaned.enumerated().map { .init(path: "/p/\($0.offset)", kind: $0.element.0, bytes: $0.element.1, error: nil) }
            + (0..<failed).map { .init(path: "/f/\($0)", kind: .nodeModules, bytes: gb, error: "No longer looks like build output") }
        run.skipped = skipped
        return run
    }

    @Test func freeSpaceMatchesTheMenuBar() {
        #expect(IntentText.freeSpace(free: 86 * gb, total: 494 * gb) == "86 GB free of 494 GB")
        #expect(IntentText.freeSpace(free: 8_440_000_000, total: 1_000 * gb) == "8.4 GB free of 1.0 TB")
    }

    @Test func statusBeforeAnyScan() {
        let text = IntentText.status(free: 86 * gb, total: 494 * gb, safeToClean: 0, scannedAt: nil, now: now)
        #expect(text == "86 GB free of 494 GB. Ballast hasn't scanned this disk yet.")
    }

    @Test func statusAfterAScan() {
        let text = IntentText.status(free: 86 * gb, total: 494 * gb, safeToClean: 12 * gb,
                                     scannedAt: now.addingTimeInterval(-2 * 3600), now: now)
        #expect(text.hasPrefix("86 GB free of 494 GB. 12 GB is safe to clean. Last scanned "))
        #expect(text.contains("2 hours ago"))
        // Nothing safe to clean: no "0 MB is safe to clean".
        let clean = IntentText.status(free: 86 * gb, total: 494 * gb, safeToClean: 0, scannedAt: now, now: now)
        #expect(!clean.contains("safe to clean"))
    }

    @Test func updated() {
        #expect(IntentText.updated(free: 86 * gb, total: 494 * gb, safeToClean: 12 * gb)
            == "Index updated. 86 GB free of 494 GB. 12 GB is safe to clean.")
        #expect(IntentText.updated(free: 86 * gb, total: 494 * gb, safeToClean: 0)
            == "Index updated. 86 GB free of 494 GB.")
    }

    @Test func autoCleanPreview() {
        let preview = run(dryRun: true, cleaned: [(.nodeModules, 2 * gb), (.next, 500_000_000)], failed: 1, skipped: 2)
        #expect(IntentText.autoClean(preview) == "Auto-clean would clean 2 build folders, 2.5 GB. 1 build folder no longer looks like build output. 2 more are due but not safe to remove right now.")
        #expect(IntentText.autoClean(run(dryRun: true, cleaned: []))
            == "Nothing is due: no build folder's project has gone unchanged long enough.")
    }

    @Test func autoCleanRun() {
        var done = run(dryRun: false, cleaned: [(.nodeModules, 2 * gb)], failed: 2)
        done.freed = 2 * gb
        #expect(IntentText.autoClean(done) == "Auto-clean cleaned 1 build folder, 2.0 GB. 2.0 GB freed. 2 build folders couldn't be cleaned.")
    }

    /// Confirmation says when Put Back can't undo it.
    @Test func autoCleanConfirmationNamesPermanentDeletes() {
        var settings = AutoCleanSettings()
        for index in settings.rules.indices where settings.rules[index].kind == .next {
            settings.rules[index].permanent = false
        }
        let preview = run(dryRun: true, cleaned: [(.nodeModules, 2 * gb), (.next, gb)])
        #expect(IntentText.autoCleanConfirmation(preview, settings: settings)
            == "Clean 2 build folders, 3.0 GB? 1 will be deleted permanently and can't be put back; the rest go to the Trash.")

        let permanent = run(dryRun: true, cleaned: [(.nodeModules, 2 * gb)])
        #expect(IntentText.autoCleanConfirmation(permanent, settings: settings)
            == "Clean 1 build folder, 2.0 GB? Your rules delete them permanently; they can't be put back.")

        let trashed = run(dryRun: true, cleaned: [(.next, gb)])
        #expect(IntentText.autoCleanConfirmation(trashed, settings: settings) == "Clean 1 build folder, 1.0 GB? They go to the Trash.")
    }

    @Test func putBack() {
        #expect(IntentText.putBack(PutBackReport(recordID: UUID(), restored: 3, problems: [])) == "Put back 3 items.")
        let conflict = "A new node_modules exists there now, so it was left in the Trash."
        #expect(IntentText.putBack(PutBackReport(recordID: UUID(), restored: 1, problems: [conflict]))
            == "Put back 1 item. " + conflict)
        #expect(IntentText.putBack(PutBackReport(recordID: UUID(), restored: 0, problems: [conflict])) == conflict)
        #expect(IntentText.putBack(PutBackReport(recordID: UUID(), restored: 0, problems: [])) == "Nothing was put back.")
    }

    /// The result Shortcuts gets from Run Auto-Clean counts what went (or
    /// would go), not the folders that failed.
    @Test func autoCleanSummary() {
        let summary = AutoCleanSummaryEntity(run(dryRun: true, cleaned: [(.nodeModules, 2 * gb), (.next, gb)], failed: 1))
        #expect(summary.folders == 2)
        #expect(summary.size.value == Double(3 * gb))
        #expect(summary.previewOnly)
    }

    /// Every screen can be picked in Open Ballast.
    @Test func everyPaneHasATitle() {
        #expect(Set(Pane.caseDisplayRepresentations.keys) == Set(Pane.allCases))
    }
}

