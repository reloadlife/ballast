import Foundation

/// When a running Ballast replays the change log on its own. The index only
/// changes when `ScanEngine.update` runs, so without this a Ballast left open
/// shows the disk as it was at launch: a 16 GB deploy copy written into the
/// temporary folder an hour later stays invisible.
enum IndexRefresh {
    /// Free space moving this much means something big was written or removed.
    static let bigChange: Int64 = 1 << 30

    /// Whether to update now, given how long ago the index was brought up to
    /// date and how far free space has moved since. A replay is cheap (only
    /// changed folders are re-listed), but it shows progress in the window and
    /// wakes the disk, so a quiet disk is left alone for longer.
    static func isDue(age: TimeInterval, freeChange: Int64) -> Bool {
        guard age >= 5 * 60 else { return false }
        if abs(freeChange) >= bigChange { return true }
        return age >= 30 * 60
    }
}
