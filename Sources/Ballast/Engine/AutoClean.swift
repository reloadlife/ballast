import Foundation
import UserNotifications

struct AutoCleanRule: Codable, Hashable, Identifiable, Sendable {
    var kind: ArtifactKind
    var enabled = false
    /// Clean once the project hasn't changed for this many days.
    var days = 7
    /// Delete outright instead of moving to the Trash.
    var permanent = true
    var id: ArtifactKind { kind }
}

/// Auto-clean configuration, shared by the app and the background run.
struct AutoCleanSettings: Codable, Equatable, Sendable {
    var background = false
    var rules: [AutoCleanRule] = ArtifactKind.allCases.map { AutoCleanRule(kind: $0) }

    var anyEnabled: Bool { rules.contains(where: \.enabled) }

    func rule(for kind: ArtifactKind) -> AutoCleanRule {
        rules.first { $0.kind == kind } ?? AutoCleanRule(kind: kind)
    }

    private static var url: URL { URL(fileURLWithPath: Paths.supportDir + "/autoclean.json") }

    static func load() -> AutoCleanSettings {
        guard let data = try? Data(contentsOf: url),
              var settings = try? JSONDecoder().decode(AutoCleanSettings.self, from: data) else { return AutoCleanSettings() }
        // Kinds added in later versions get a default (off) rule.
        for kind in ArtifactKind.allCases where !settings.rules.contains(where: { $0.kind == kind }) {
            settings.rules.append(AutoCleanRule(kind: kind))
        }
        return settings
    }

    func save() {
        try? FileManager.default.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.url, options: .atomic)
    }
}

/// What one run did (or, for a dry run, would do).
struct AutoCleanRun: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let path: String
        let kind: ArtifactKind
        let bytes: Int64
        let error: String?
    }

    var date = Date.now
    var dryRun = false
    var entries: [Entry] = []
    /// Due by age but not eligible: protected, inside a tool's own folder,
    /// or belonging to an app that's open. Counted, not listed.
    var skipped = 0
    /// Measured change in free space.
    var freed: Int64 = 0

    var cleaned: [Entry] { entries.filter { $0.error == nil } }
    var cleanedBytes: Int64 { cleaned.reduce(0) { $0 + $1.bytes } }

    private static var url: URL { URL(fileURLWithPath: Paths.supportDir + "/autoclean-last.json") }

    static func last() -> AutoCleanRun? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AutoCleanRun.self, from: data)
    }

    func save() {
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}

enum AutoClean {
    /// Build folders the enabled rules would remove right now.
    static func due(_ artifacts: [Artifact], settings: AutoCleanSettings, now: Date = .now) -> [(Artifact, AutoCleanRule)] {
        artifacts.compactMap { artifact in
            let rule = settings.rule(for: artifact.kind)
            guard rule.enabled, isStale(artifact, rule: rule, now: now) else { return nil }
            return (artifact, rule)
        }
    }

    /// "Unused" means the project hasn't changed: a node_modules folder is
    /// rarely written to, but the project around it is while you work on it.
    static func isStale(_ artifact: Artifact, rule: AutoCleanRule, now: Date = .now) -> Bool {
        guard artifact.projectNewest > 0 else { return false }
        let idle = now.timeIntervalSince1970 - Double(artifact.projectNewest)
        return idle >= Double(rule.days) * 86_400
    }

    /// Refreshes the index, then cleans what's due. Every folder is checked
    /// again right before removal: marker file present, verdict Safe.
    static func run(dryRun: Bool, apps: AppInventory, report: StatusHandler = { _ in }) throws -> AutoCleanRun {
        let settings = AutoCleanSettings.load()
        var run = AutoCleanRun(dryRun: dryRun)
        guard settings.anyEnabled else { return run }

        do {
            try ScanEngine.update(report: report, cancel: CancelFlag())
        } catch ScanEngine.Failure.needsFullScan {
            try ScanEngine.fullScan(report: report, cancel: CancelFlag())
        }

        let db = try IndexDB(path: Paths.index, mode: .read)
        let due = self.due(ArtifactScanner.scan(db), settings: settings)
        let freeBefore = Volume.freeBytes

        var touched: [String] = []
        for (artifact, rule) in due {
            let url = URL(fileURLWithPath: artifact.path)
            let safety = SafetyCheck.assess(artifact.path, isDirectory: true, apps: apps)
            guard safety.level == .safe else {
                run.skipped += 1
                continue
            }
            guard ArtifactKind.detect(url) == artifact.kind else {
                run.entries.append(.init(path: artifact.path, kind: artifact.kind, bytes: artifact.bytes,
                                         error: "No longer looks like build output"))
                continue
            }
            if dryRun {
                run.entries.append(.init(path: artifact.path, kind: artifact.kind, bytes: artifact.bytes, error: nil))
                continue
            }
            let item = PlanItem(name: url.lastPathComponent, path: artifact.path, bytes: artifact.bytes,
                                action: .remove, isDirectory: true, safety: safety, included: true)
            let outcome = Cleaner.clean([item], permanently: rule.permanent, apps: apps, cancel: CancelFlag()) { _, _ in }.first
            run.entries.append(.init(path: artifact.path, kind: artifact.kind, bytes: artifact.bytes, error: outcome?.error))
            touched.append(Paths.onVolume(artifact.path))
            if !rule.permanent { touched.append(Paths.onVolume(NSHomeDirectory() + "/.Trash")) }
        }

        if !touched.isEmpty {
            try? ScanEngine.rescan(Array(Set(touched)), title: "Measuring", report: report, cancel: CancelFlag())
            run.freed = max(Volume.freeBytes - freeBefore, 0)
            _ = History.record(free: Volume.freeBytes, freed: run.freed)
        }
        if !dryRun { run.save() }
        return run
    }
}

extension Volume {
    static var freeBytes: Int64 {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

/// The daily background run: a per-user LaunchAgent calling
/// `Ballast --auto-clean`.
enum BackgroundAgent {
    static let label = "dev.mamad.Ballast.autoclean"
    private static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    private static var logPath: String { NSHomeDirectory() + "/Library/Logs/Ballast/autoclean.log" }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    /// Installs or refreshes the agent (the app may have moved since).
    static func install() throws {
        guard let executable = Bundle.main.executablePath else { return }
        let fm = FileManager.default
        try fm.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--auto-clean"],
            "StartCalendarInterval": ["Hour": 12, "Minute": 30],
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        if (try? Data(contentsOf: URL(fileURLWithPath: plistPath))) == data { return }
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        launchctl(["bootstrap", "gui/\(getuid())", plistPath])
    }

    static func uninstall() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    private static func launchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

enum Notify {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts a notification and waits briefly so a CLI run can deliver it
    /// before exiting.
    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let done = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(request) { _ in done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }
}
