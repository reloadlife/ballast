import BallastCore
import Foundation
import WidgetKit
import os

struct StatusEntry: TimelineEntry {
    let date: Date
    /// Nil until Ballast has run once and written status.json.
    let snapshot: StatusSnapshot?
    /// Free space read just now, for when there's no snapshot yet.
    let volume: (free: Int64, total: Int64)?
    /// Whether the free-space figure was read just now, not taken from the
    /// snapshot. Almost always; if the read fails the snapshot's figure
    /// stands, and the widget says how old it is.
    let isLive: Bool

    /// The generic disk shown in the widget gallery and while loading: a
    /// round 500 GB, no one's real data.
    static let sample = StatusEntry(
        date: .now,
        snapshot: StatusSnapshot(
            date: .now,
            volumeName: "Macintosh HD",
            totalBytes: 500_000_000_000,
            freeBytes: 120_000_000_000,
            segments: [
                .init(kind: .applications, bytes: 45_000_000_000),
                .init(kind: .yourFiles, bytes: 160_000_000_000),
                .init(kind: .caches, bytes: 22_000_000_000),
                .init(kind: .buildFiles, bytes: 18_000_000_000),
                .init(kind: .system, bytes: 135_000_000_000),
            ],
            safeToClean: 32_000_000_000,
            freedLastWeek: 6_000_000_000,
            scannedAt: .now.addingTimeInterval(-3_600)
        ),
        volume: nil,
        isLive: true
    )
}

/// Reads status.json (the app and its background runs keep it current) and
/// puts a fresh free-space reading on top, so the headline figure is right
/// even when Ballast hasn't run for a while.
struct StatusProvider: TimelineProvider {
    private static let log = Logger(subsystem: "dev.mamad.Ballast.widget", category: "status")

    func placeholder(in context: Context) -> StatusEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(context.isPreview ? .sample : Self.current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        // The app reloads the widget whenever it writes status.json; this is
        // for free space changing while Ballast isn't running.
        let refresh = Date.now.addingTimeInterval(30 * 60)
        completion(Timeline(entries: [Self.current()], policy: .after(refresh)))
    }

    static func current() -> StatusEntry {
        let volume = DiskCapacity.current
        var snapshot: StatusSnapshot?
        do {
            snapshot = try StatusSnapshot.read()
        } catch CocoaError.fileReadNoSuchFile {
            // Ballast hasn't run yet: the empty state explains.
        } catch {
            log.error("Couldn't read \(StatusSnapshot.url.path, privacy: .public): \(error, privacy: .public)")
        }
        if let volume, let saved = snapshot {
            snapshot = saved.updating(free: volume.free, total: volume.total)
        }
        return StatusEntry(date: .now, snapshot: snapshot, volume: volume, isLive: volume != nil)
    }
}
