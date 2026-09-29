import BallastCore
import Foundation

/// What the Shortcuts actions say, apart from App Intents so it can be
/// tested. Sizes use the menu bar's compact form: "86 GB free of 494 GB".
enum IntentText {
    static func freeSpace(free: Int64, total: Int64) -> String {
        "\(free.compactBytes) free of \(total.compactBytes)"
    }

    /// "86 GB free of 494 GB. 12 GB is safe to clean. Last scanned 2 hours ago."
    static func status(free: Int64, total: Int64, safeToClean: Int64, scannedAt: Date?, now: Date = .now) -> String {
        var text = freeSpace(free: free, total: total) + "."
        guard let scannedAt else { return text + " Ballast hasn't scanned this disk yet." }
        if safeToClean > 0 { text += " \(safeToClean.compactBytes) is safe to clean." }
        return text + " Last scanned \(relative(scannedAt, now: now))."
    }

    /// After Update Disk Index.
    static func updated(free: Int64, total: Int64, safeToClean: Int64) -> String {
        var text = "Index updated. " + freeSpace(free: free, total: total) + "."
        if safeToClean > 0 { text += " \(safeToClean.compactBytes) is safe to clean." }
        return text
    }

    // MARK: Auto-clean

    static let noRules = "No auto-clean rules are on. Turn one on in Ballast › Settings › Auto-Clean."

    /// What a run did, or for a preview, what it would do.
    static func autoClean(_ run: AutoCleanRun) -> String {
        let cleaned = run.cleaned
        let failed = run.entries.count - cleaned.count
        var text: String
        if cleaned.isEmpty {
            text = "Nothing is due: no build folder's project has gone unchanged long enough."
        } else if run.dryRun {
            text = "Auto-clean would clean \(folders(cleaned.count)), \(run.cleanedBytes.compactBytes)."
        } else {
            text = "Auto-clean cleaned \(folders(cleaned.count)), \(run.cleanedBytes.compactBytes)."
            if run.freed > 0 { text += " \(run.freed.compactBytes) freed." }
        }
        if failed > 0 {
            text += run.dryRun
                ? " \(folders(failed)) no longer \(failed == 1 ? "looks" : "look") like build output."
                : " \(folders(failed)) couldn't be cleaned."
        }
        if run.skipped > 0 {
            text += " \(run.skipped) more \(run.skipped == 1 ? "is" : "are") due but not safe to remove right now."
        }
        return text
    }

    /// Asked before a real run, with what a preview found. Says so when
    /// the rules delete outright, since Put Back can't undo that.
    static func autoCleanConfirmation(_ preview: AutoCleanRun, settings: AutoCleanSettings) -> String {
        let cleaned = preview.cleaned
        let permanent = cleaned.filter { settings.rule(for: $0.kind).permanent }.count
        var text = "Clean \(folders(cleaned.count)), \(preview.cleanedBytes.compactBytes)?"
        if permanent == cleaned.count {
            text += " Your rules delete them permanently; they can't be put back."
        } else if permanent > 0 {
            text += " \(permanent) will be deleted permanently and can't be put back; the rest go to the Trash."
        } else {
            text += " They go to the Trash."
        }
        return text
    }

    // MARK: Put Back

    static let nothingToPutBack = "There's nothing to put back: no recent cleanup has items left in the Trash."

    static func putBackConfirmation(_ record: CleanupRecord) -> String {
        let count = record.pending.count
        let date = record.date.formatted(date: .abbreviated, time: .shortened)
        return "Put back \(items(count)) from the \(record.auto ? "auto-clean" : "cleanup") on \(date)?"
    }

    static func putBack(_ report: PutBackReport) -> String {
        var lines: [String] = []
        if report.restored > 0 {
            lines.append("Put back \(items(report.restored)).")
        } else if report.problems.isEmpty {
            lines.append("Nothing was put back.")
        }
        lines += report.problems
        return lines.joined(separator: " ")
    }

    // MARK: Helpers

    static func folders(_ count: Int) -> String {
        "\(count) build folder\(count == 1 ? "" : "s")"
    }

    static func items(_ count: Int) -> String {
        "\(count) item\(count == 1 ? "" : "s")"
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
