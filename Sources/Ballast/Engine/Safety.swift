import AppKit
import Foundation

struct RunningApp: Sendable, Hashable {
    let name: String
    let bundleID: String
    let pid: pid_t
    let bundlePath: String
}

struct InstalledApp: Sendable, Hashable {
    let name: String
    let bundleID: String
}

/// Snapshot of which apps are installed and running, taken on the main
/// thread and handed to the (thread-agnostic) safety rules.
struct AppInventory: Sendable {
    let running: [RunningApp]
    let installed: [InstalledApp]

    @MainActor
    static func current() -> AppInventory {
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> RunningApp? in
            guard let id = app.bundleIdentifier, app.processIdentifier != getpid() else { return nil }
            return RunningApp(
                name: app.localizedName ?? id, bundleID: id, pid: app.processIdentifier,
                bundlePath: app.bundleURL?.path ?? ""
            )
        }
        return AppInventory(running: running, installed: installedApps())
    }

    @MainActor private static var installedCache: (date: Date, apps: [InstalledApp])?

    /// Apps in the standard folders, one level of subfolders deep
    /// (/Applications/Utilities). Cached briefly: it reads every Info.plist.
    @MainActor
    private static func installedApps() -> [InstalledApp] {
        if let cache = installedCache, Date.now.timeIntervalSince(cache.date) < 30 { return cache.apps }
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        var apps: [InstalledApp] = []
        func add(_ dir: String, depth: Int) {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = dir + "/" + name
                if name.hasSuffix(".app") {
                    let id = Bundle(path: path)?.bundleIdentifier ?? ""
                    apps.append(InstalledApp(name: String(name.dropLast(4)), bundleID: id))
                } else if depth > 0 {
                    add(path, depth: depth - 1)
                }
            }
        }
        for root in roots { add(root, depth: 1) }
        installedCache = (.now, apps)
        return apps
    }

    /// Running app a folder name refers to: a bundle id ("com.google.Chrome",
    /// "6N38VWS5BX.ru.keepcoder.Telegram") or an app/vendor name ("Google",
    /// "Code"). Deliberately generous: a false match only means "quit first".
    func runningOwner(of keys: [String]) -> RunningApp? {
        for key in keys.map(Self.normalized) where key.count >= 3 {
            if let app = running.first(where: { Self.matches(key, name: $0.name, bundleID: $0.bundleID) }) {
                return app
            }
        }
        return nil
    }

    func installedOwner(of keys: [String]) -> InstalledApp? {
        for key in keys.map(Self.normalized) where key.count >= 3 {
            if let app = installed.first(where: { Self.matches(key, name: $0.name, bundleID: $0.bundleID) }) {
                return app
            }
        }
        return nil
    }

    /// Strips team-id and "group." prefixes from container names.
    private static func normalized(_ key: String) -> String {
        var key = key
        if let dot = key.firstIndex(of: "."), key[..<dot].count == 10,
           key[..<dot].allSatisfy({ $0.isUppercase || $0.isNumber }) {
            key = String(key[key.index(after: dot)...])
        }
        if key.hasPrefix("group.") { key = String(key.dropFirst(6)) }
        return key
    }

    private static func matches(_ key: String, name: String, bundleID: String) -> Bool {
        let key = key.lowercased()
        let id = bundleID.lowercased()
        let name = name.lowercased()
        let words = name.split(separator: " ").map { String($0) } + [name.replacingOccurrences(of: " ", with: "")]
        if key.contains(".") {
            // Bundle ids, including helpers (com.google.Chrome.helper) and
            // shared containers (com.google.Chrome.shared).
            if id == key || id.hasPrefix(key + ".") || key.hasPrefix(id + ".") { return true }
            // Containers don't always use the app's bundle id: OrbStack is
            // dev.kdrag0n.MacVirt but keeps its data in "dev.orbstack".
            // Fall back to the reverse-DNS parts naming the app.
            let parts = key.split(separator: ".").dropFirst().map(String.init).filter { $0.count >= 4 }
            let generic: Set<String> = ["group", "shared", "helper", "apps", "macos", "desktop", "apple"]
            return parts.contains { !generic.contains($0) && words.contains($0) }
        }
        return name == key || words.contains(key) || id.hasSuffix("." + key)
    }
}

/// How risky it is to remove something, and why.
struct Safety: Sendable, Hashable {
    enum Level: Int, Sendable, Comparable {
        case safe, quitFirst, caution, blocked
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    let level: Level
    let reason: String
    /// The running app to quit, for `.quitFirst`.
    var app: RunningApp?

    static func safe(_ reason: String) -> Safety { Safety(level: .safe, reason: reason) }
    static func caution(_ reason: String) -> Safety { Safety(level: .caution, reason: reason) }
    static func blocked(_ reason: String) -> Safety { Safety(level: .blocked, reason: reason) }
    static func quit(_ app: RunningApp, _ what: String) -> Safety {
        Safety(level: .quitFirst, reason: "\(app.name) is open and uses \(what). Quit it first so nothing breaks.", app: app)
    }
}

/// Rules deciding what Ballast lets you remove. The goal is that cleaning
/// never breaks an app or loses data you didn't mean to lose.
enum SafetyCheck {
    /// Library areas that hold settings, credentials or data apps can't rebuild.
    private static let protectedLibraryAreas: Set<String> = [
        "Keychains", "Preferences", "Mail", "Messages", "Accounts", "Mobile Documents", "CloudStorage",
        "Calendars", "Application Scripts", "LaunchAgents", "Safari", "Cookies", "Autosave Information",
        "Sharing", "IdentityServices", "Passes", "Photos", "Metadata", "Suggestions", "Assistant",
        "Fonts", "Keyboard Layouts", "Input Methods", "Services", "PreferencePanes", "Frameworks",
    ]

    /// Dot-folders holding keys or credentials.
    private static let secretFolders: Set<String> = [".ssh", ".gnupg", ".aws", ".kube", ".gcloud", ".azure", ".password-store"]

    /// Containers and support folders that belong to macOS rather than an app.
    static func isSystemOwned(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.hasPrefix("com.apple.") || name.hasPrefix("group.com.apple.") || name.contains(".com.apple.")
            || ["apple", "addressbook", "callhistorydb", "clouddocs", "knowledge", "icdd", "syncservices",
                "dock", "mobilesync", "crashreporter", "com.apple"].contains(name)
    }

    static func isCacheName(_ component: Substring) -> Bool {
        let name = component.lowercased()
        return name.contains("cache") || ["tmp", "temp", "logs", "log", "crashpad", "crash reports"].contains(name)
    }

    /// Safety of removing `path` (a display path) entirely.
    static func assess(_ path: String, isDirectory: Bool, apps: AppInventory) -> Safety {
        let verdict = rules(path, isDirectory: isDirectory, apps: apps)
        // A running app inside an otherwise removable item (e.g.
        // ~/Applications/Foo.app) must be quit first. This only ever makes
        // things stricter: protected stays protected.
        if verdict.level == .safe || verdict.level == .caution,
           let app = apps.running.first(where: { $0.bundlePath == path || $0.bundlePath.hasPrefix(path + "/") }) {
            return .quit(app, "files in here")
        }
        return verdict
    }

    private static func rules(_ path: String, isDirectory: Bool, apps: AppInventory) -> Safety {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/"), !path.contains("/../"), !path.hasSuffix("/..") else {
            return .blocked("Only items inside your home folder can be cleaned.")
        }
        let parts = path.dropFirst(home.count + 1).split(separator: "/")
        guard let first = parts.first else { return .blocked("That's your home folder.") }

        if parts.count == 1 {
            if isDirectory { return .blocked("\(first) is one of your account's main folders. Clean what's inside it instead.") }
            if first.hasPrefix(".") { return .blocked("\(first) is a settings file apps and your shell rely on.") }
            return .safe("Your file.")
        }

        if path.contains(".photoslibrary") {
            return .blocked("Part of your Photos library. Delete photos in the Photos app so the library stays intact.")
        }

        if first == "Library" { return library(parts, apps: apps) }

        if first.hasPrefix(".") {
            if secretFolders.contains(String(first)) { return .blocked("\(first) holds keys or credentials.") }
            if first == ".Trash" { return .safe("Already in the Trash.") }
            if first == ".cache" || first == ".npm" || parts.dropFirst().contains(where: isCacheName) {
                return .safe("Tool cache, downloaded again when needed.")
            }
            let tool = first.dropFirst()
            if let app = apps.runningOwner(of: [String(tool)]) { return .quit(app, "\(first)") }
            return .caution("Belongs to \(tool). Removing it may break that tool until you reinstall it.")
        }

        if let vcs = parts.first(where: { [".git", ".svn", ".hg", ".jj"].contains($0) }) {
            return .blocked("\(vcs) is the project's version history. Removing it loses every commit and branch.")
        }
        if Catalog.isProjectArtifact(URL(fileURLWithPath: path)) {
            return .safe("Build output. Your next install or build recreates it.")
        }
        if isDirectory, FileManager.default.fileExists(atPath: path + "/.git") {
            return .caution("A git repository. Anything not pushed would be lost.")
        }
        if path.hasSuffix(".app") {
            return .caution("An app. Removing it uninstalls it.")
        }
        return .safe("Your own files.")
    }

    private static func library(_ parts: [Substring], apps: AppInventory) -> Safety {
        guard parts.count >= 3 else { return .blocked("Part of your Library's structure that macOS relies on.") }
        let area = String(parts[1])
        let owner = String(parts[2])
        let inner = parts.count > 3 ? [String(parts[3])] : []

        if protectedLibraryAreas.contains(area) {
            return .blocked("\(area) holds settings or personal data that macOS and apps rely on.")
        }

        switch area {
        case "Caches", "Logs", "HTTPStorages", "WebKit":
            if let app = apps.runningOwner(of: [owner] + inner) { return .quit(app, "this cache") }
            return .safe("\(area == "Logs" ? "Logs" : "App cache"). The app rebuilds it when needed.")

        case "Application Support", "Containers", "Group Containers", "Saved Application State":
            let cacheLike = parts.dropFirst(3).contains(where: isCacheName)
            let running = apps.runningOwner(of: [owner] + inner)
            if cacheLike {
                if let running { return .quit(running, "this cache") }
                return .safe("Cache inside \(owner)'s data. Rebuilt when needed.")
            }
            if area == "Saved Application State" {
                if let running { return .quit(running, "its saved windows") }
                return .safe("Saved window positions. Harmless to remove.")
            }
            if let running {
                return .blocked("\(running.name)'s data: settings, logins, profiles. Removing it can break \(running.name) or lose data. Clear it from inside the app instead.")
            }
            if isSystemOwned(owner) {
                return .blocked("Used by macOS itself. Removing it can break system features.")
            }
            if let app = apps.installedOwner(of: [owner] + inner) {
                return .blocked("\(app.name)'s data: settings, logins, profiles. Removing it can break \(app.name) or lose data. Clear it from inside the app instead.")
            }
            // Not provably orphaned: many background services and helpers
            // have no app bundle to match against.
            return .blocked("Ballast can't tell which app uses \(owner), so it stays protected. If you're sure the app is gone, delete it in Finder.")

        case "Developer":
            if parts.contains("DerivedData") || parts.dropFirst(2).contains(where: isCacheName) {
                if let app = apps.runningOwner(of: ["com.apple.dt.Xcode"]) { return .quit(app, "this build data") }
                return .safe("Xcode build data, rebuilt on the next build.")
            }
            return .blocked("Developer tool data. Use Xcode's own cleanup or `xcrun simctl` so the tools stay consistent.")

        default:
            if parts.dropFirst(2).contains(where: isCacheName) {
                if let app = apps.runningOwner(of: [owner] + inner) { return .quit(app, "this cache") }
                return .safe("Cache, rebuilt when needed.")
            }
            return .blocked("Inside ~/Library/\(area), which apps rely on. Only caches in here can be cleaned.")
        }
    }
}
