import BallastCore
import Foundation

/// The low-free-space alert. Checked hourly by the `--check-space`
/// LaunchAgent and every few minutes while Ballast is open; both share the
/// last-notified state, so one drop means one notification.
enum LowSpace {
    /// The last notification, kept so the alert doesn't repeat every hour.
    struct Notified: Codable, Equatable, Sendable {
        let date: Date
        let free: Int64
    }

    /// At most once a day, unless free space has since fallen another half
    /// threshold below the last notified reading.
    static func shouldNotify(free: Int64, threshold: Int64, last: Notified?, now: Date = .now) -> Bool {
        guard free < threshold else { return false }
        guard let last else { return true }
        if now.timeIntervalSince(last.date) >= 86_400 { return true }
        return free <= last.free - threshold / 2
    }

    static func message(free: Int64, volume: String, safeToClean: Int64) -> (title: String, body: String) {
        var body = "Only \(free.formatted(.byteCount(style: .file))) left on \(volume)."
        if safeToClean > 0 {
            body += " \(safeToClean.formatted(.byteCount(style: .file))) is safe to clean."
        }
        return ("Running out of space", body)
    }

    /// Compares a fresh reading with the setting and notifies if needed.
    /// Blocks while the notification is handed over: keep it off the main
    /// thread in the app.
    @discardableResult
    static func check(_ snapshot: StatusSnapshot, preferences: Preferences = .load()) -> Bool {
        guard preferences.lowSpaceAlert else { return false }
        let threshold = preferences.lowSpaceThreshold
        guard shouldNotify(free: snapshot.freeBytes, threshold: threshold, last: lastNotified()) else { return false }
        let message = message(free: snapshot.freeBytes, volume: snapshot.volumeName, safeToClean: snapshot.safeToClean)
        // Unposted (no app bundle) doesn't count, or it would hush the real one.
        guard Notify.post(title: message.title, body: message.body) else { return false }
        save(Notified(date: .now, free: snapshot.freeBytes))
        return true
    }

    // MARK: State

    private static var url: URL { URL(fileURLWithPath: Paths.supportDir + "/lowspace-notified.json") }

    static func lastNotified() -> Notified? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Notified.self, from: data)
    }

    private static func save(_ notified: Notified) {
        try? FileManager.default.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(notified).write(to: url, options: .atomic)
    }

    /// Keeps the hourly agent in line with the setting. It needs a real app
    /// bundle: a bare binary can't post notifications, so it's removed then.
    static func syncAgent(_ preferences: Preferences) {
        if preferences.lowSpaceAlert && Bundle.main.bundleURL.pathExtension == "app" {
            try? BackgroundAgent.spaceCheck.install()
        } else {
            BackgroundAgent.spaceCheck.uninstall()
        }
    }
}
