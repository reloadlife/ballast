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

    /// Folders in home that hold what you made yourself. What Ballast
    /// doesn't recognize in them needs a tick: it can't tell a stale
    /// download from your thesis.
    static let personalFolders: Set<String> = ["Documents", "Desktop", "Music", "Movies", "Pictures"]

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

    /// Safety of removing `path` (a display path) entirely. `protected` are
    /// the folders the user marked as never-clean in Settings.
    ///
    /// Paths on other drives (under /Volumes) follow `drive(_:rules:)`
    /// instead of the home-folder rules; `drives` looks the drive up and
    /// is replaced in tests.
    static func assess(
        _ path: String, isDirectory: Bool, apps: AppInventory,
        protected: [String] = Preferences.current.protectedFolders,
        drives: (String) -> DriveFacts? = Drives.facts
    ) -> Safety {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            return .blocked("Choose an absolute path without parent-directory traversal.")
        }
        // Evaluate the real destination too: a symlink must not turn a system
        // folder or a user-protected folder into an apparently ordinary path.
        let original = Paths.display(path)
        let path = Paths.canonical(original)
        let protected = protected.flatMap { folder in
            [folder, Paths.canonical(folder)]
        }
        if let verdict = userProtection(original, protected: protected) { return verdict }
        if let verdict = userProtection(path, protected: protected) { return verdict }
        let components = (path + "/" + original).split(separator: "/")
        if let secret = components.first(where: { secretFolders.contains(String($0)) }) {
            return .blocked("\(secret) holds keys or credentials.")
        }
        if let vcs = components.first(where: { [".git", ".svn", ".hg", ".jj"].contains($0) }) {
            return .blocked("\(vcs) holds version history. Use the repository's tools to manage it.")
        }
        let resolvedVerdict = drives(path).map { drive($0, rules: path, isDirectory: isDirectory) }
            ?? rules(path, isDirectory: isDirectory, apps: apps)
        let originalVerdict = drives(original).map { drive($0, rules: original, isDirectory: isDirectory) }
            ?? rules(original, isDirectory: isDirectory, apps: apps)
        let verdict = originalVerdict.level > resolvedVerdict.level ? originalVerdict : resolvedVerdict
        // A running app inside an otherwise removable item (e.g.
        // ~/Applications/Foo.app) must be quit first. This only ever makes
        // things stricter: protected stays protected.
        if verdict.level == .safe || verdict.level == .caution,
           let app = apps.running.first(where: { $0.bundlePath == path || $0.bundlePath.hasPrefix(path + "/") }) {
            return .quit(app, "files in here")
        }
        // A virtual machine's disk while the app that runs VMs is open: the
        // VM may be using it.
        if verdict.level == .safe || verdict.level == .caution, FileKind(path: path) == .virtualMachine,
           let app = apps.running.first(where: { vmApps.contains($0.bundleID) }) {
            return .quit(app, "this virtual machine's disk")
        }
        return verdict
    }

    /// Apps that run virtual machines or containers from disk images.
    static let vmApps: Set<String> = [
        "com.utmapp.UTM", "com.parallels.desktop.console", "com.vmware.fusion", "org.virtualbox.app.VirtualBox",
        "com.docker.docker", "dev.kdrag0n.MacVirt",
    ]

    /// The user's word beats every rule below: a protected folder, anything
    /// inside it, and anything containing it (removing a parent would take
    /// the protected folder with it).
    static func userProtection(_ path: String, protected: [String]) -> Safety? {
        for folder in protected where !folder.isEmpty {
            if path == folder || path.hasPrefix(folder + "/") {
                return .blocked("You protected \(path == folder ? "this folder" : (folder as NSString).lastPathComponent) in Settings.")
            }
            if folder.hasPrefix(path + "/") {
                return .blocked("Contains \((folder as NSString).lastPathComponent), a folder you protected in Settings.")
            }
        }
        return nil
    }

    /// A tool's own cleanup command. Most only drop downloads the tool
    /// fetches again; one that can remove something you made says so.
    static func command(_ command: String) -> Safety {
        if command == Catalog.dockerPrune {
            return .caution("Runs `docker system prune`: removes stopped containers, networks no container uses, dangling images and the build cache. Volumes are kept, but anything saved inside a stopped container is lost.")
        }
        return .safe("Runs `\(command)`, the tool's own cleanup.")
    }

    /// Safety of uninstalling the app at `path`: the app and, with it, its
    /// `data`. The data folders stay protected everywhere else; this is
    /// the only way they can go, and only together with their app.
    static func uninstall(
        _ path: String, bundleID: String, data: [String], apps: AppInventory,
        protected: [String] = Preferences.current.protectedFolders, locations: AppLocations = .standard
    ) -> Safety {
        for item in [path] + data {
            if let verdict = userProtection(item, protected: protected) { return verdict }
        }
        let parent = (path as NSString).deletingLastPathComponent
        let inRoot = locations.roots.contains { parent == $0 || (parent as NSString).deletingLastPathComponent == $0 }
        var st = stat()
        guard path.hasSuffix(".app"), inRoot, !path.contains("/../"),
              lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else {
            return .blocked("Ballast only uninstalls apps in your Applications folders.")
        }
        guard let app = AppBundle.read(path, entitlements: false), app.bundleID == bundleID else {
            return .blocked("This app changed since it was added. Add it again.")
        }
        guard data.allSatisfy({ $0.hasPrefix(locations.library + "/") && !$0.contains("/../") }) else {
            return .blocked("Only data in your Library folder is removed with an app.")
        }
        let store = app.fromAppStore ? " You can reinstall it from the App Store." : ""
        switch app.lock {
        case .admin:
            return .blocked("Only an administrator can remove \(app.name), and Ballast doesn't ask for admin rights to delete. Drag it to the Trash in Finder instead.\(store)")
        case .appManagement:
            return .blocked("macOS only lets apps you allow in Privacy & Security › App Management remove \(app.name). Allow Ballast there, or drag it to the Trash in Finder.\(store)")
        case nil:
            break
        }
        if let running = apps.running.first(where: {
            $0.bundleID == bundleID || $0.bundlePath == path || $0.bundlePath.hasPrefix(path + "/")
        }) {
            return Safety(level: .quitFirst, reason: "\(running.name) is open. Quit it first so nothing breaks.", app: running)
        }
        if app.installsSystemComponents {
            return .caution("\(app.name) installs system components; use its own uninstaller if it has one.\(store)")
        }
        let what = data.isEmpty ? "" : " and its data: settings, logins and anything saved inside the app"
        return .caution("Moves \(app.name)\(what) to the Trash. Put it back from Cleanup History if you need it.\(store)")
    }

    /// What macOS and Windows keep at the top of a drive to manage it.
    private static let driveHousekeeping: Set<String> = [
        ".fseventsd", ".Spotlight-V100", ".DocumentRevisions-V100", ".TemporaryItems", ".MobileBackups",
        "Backups.backupdb", ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware",
        ".journal", ".journal_info_block", "System Volume Information", "$RECYCLE.BIN",
    ]

    /// Rules for a path on a drive other than the startup disk. There's no
    /// app data or Library there to protect, but there is the drive's own
    /// housekeeping, and drives Ballast mustn't write to at all.
    static func drive(_ drive: DriveFacts, rules path: String, isDirectory: Bool) -> Safety {
        guard drive.isConnected else { return .blocked("\(drive.name) isn't connected.") }
        guard drive.isLocal else { return .blocked("Ballast doesn't clean network drives.") }
        guard !drive.isTimeMachine else {
            return .blocked("A Time Machine backup drive. Manage backups in Time Machine so they stay intact.")
        }
        guard !drive.isReadOnly else { return .blocked("This drive is read-only.") }
        guard path.hasPrefix(drive.mountPath + "/"), !path.contains("/../"), !path.hasSuffix("/..") else {
            return .blocked("That's the whole drive. Clean what's on it instead.")
        }
        guard !drive.holdsMacOS else {
            return .blocked("\(drive.name) holds a macOS installation. Ballast only cleans drives that hold your own files.")
        }
        let parts = path.dropFirst(drive.mountPath.count + 1).split(separator: "/")
        guard let first = parts.first else { return .blocked("That's the whole drive. Clean what's on it instead.") }
        if first == ".Trashes" {
            return .blocked("The drive's Trash. Empty the Trash to clear it.")
        }
        if driveHousekeeping.contains(String(first)) {
            return .blocked("\(first) is how the drive keeps track of its files. Removing it can damage its index or backups.")
        }
        if let bundle = libraryBundle(in: path), bundle.isInside {
            return .blocked(bundle.insideReason)
        }
        if let secret = parts.first(where: { secretFolders.contains(String($0)) }) {
            return .blocked("\(secret) holds keys or credentials.")
        }
        if let vcs = parts.first(where: { [".git", ".svn", ".hg", ".jj"].contains($0) }) {
            return .blocked("\(vcs) is the project's version history. Removing it loses every commit and branch.")
        }
        if let verdict = buildOutput(path, apps: nil) { return verdict }
        if isDirectory, FileManager.default.fileExists(atPath: path + "/.git") {
            return .caution("A git repository. Anything not pushed would be lost.")
        }
        if path.hasSuffix(".app") {
            return .caution("An app. Removing it uninstalls it.")
        }
        if let bundle = libraryBundle(in: path) { return .caution(bundle.reason) }
        if Installers.extensions.contains((path as NSString).pathExtension.lowercased()) {
            return .safe("An installer or disk image. You can download it again if you need it.")
        }
        if isDirectory, let held = heldLibraryBundle(path) { return .caution(held.holderReason) }
        return .safe("Your own files on \(drive.name).")
    }

    private static func rules(_ path: String, isDirectory: Bool, apps: AppInventory) -> Safety {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/") else {
            return outsideHome(path, isDirectory: isDirectory, apps: apps)
        }
        let parts = path.dropFirst(home.count + 1).split(separator: "/")
        guard let first = parts.first else { return .blocked("That's your home folder.") }

        if parts.count == 1 {
            if isDirectory { return .blocked("\(first) is one of your account's main folders. Clean what's inside it instead.") }
            if first.hasPrefix(".") { return .blocked("\(first) is a settings file apps and your shell rely on.") }
            return .safe("Your file.")
        }

        // What Ballast knows about this exact location beats every general
        // rule below, except that nothing inside a library bundle may go.
        let known = Knowledge.lookup(path: path, home: home)
        if let bundle = libraryBundle(in: path), bundle.isInside {
            if let known, known.level == .blocked { return .blocked(known.reason) }
            return .blocked(bundle.insideReason)
        }
        if let known { return verdict(known, path: path, apps: apps, absolute: false) }

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
        if let verdict = buildOutput(path, apps: apps) { return verdict }
        if isDirectory, FileManager.default.fileExists(atPath: path + "/.git") {
            return .caution("A git repository. Anything not pushed would be lost.")
        }
        if path.hasSuffix(".app") {
            return .caution("An app. Removing it uninstalls it.")
        }
        if let bundle = libraryBundle(in: path) { return .caution(bundle.reason) }
        if Installers.extensions.contains((path as NSString).pathExtension.lowercased()) {
            return .safe("An installer or disk image. You can download it again if you need it.")
        }
        if isDirectory, let held = heldLibraryBundle(path) { return .caution(held.holderReason) }
        if personalFolders.contains(String(first)) {
            return .caution("In your \(first) folder. Ballast can't tell what these files are, so check you don't need them.")
        }
        return .safe("Your own files.")
    }

    /// Location alone isn't a reason to refuse cleanup. Keep actual system
    /// structure and managed data protected, and require review for other files.
    private static func outsideHome(_ path: String, isDirectory: Bool, apps: AppInventory) -> Safety {
        func inside(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        let roots: Set<String> = ["/", "/Users", "/Users/Shared", "/Volumes", "/private", "/private/var",
                                  "/private/tmp", "/private/var/tmp", "/private/var/folders", "/opt", "/usr/local", NSHomeDirectory()]
        if roots.contains(path) { return .blocked("This is a system, account or shared root folder. Clean individual items inside it instead.") }
        for root in ["/System", "/bin", "/sbin", "/dev", "/private/etc", "/private/var/db", "/private/var/vm",
                     "/private/var/root", "/private/var/run", "/private/var/protected", "/private/var/audit",
                     "/private/var/backups", "/private/var/spool", "/private/var/log", "/private/var/networkd"] {
            if inside(root) { return .blocked("macOS manages these system files. Use the owning system tool to clean them.") }
        }
        if inside("/usr") && !inside("/usr/local") { return .blocked("Part of macOS's installed tools and libraries.") }
        if let bundle = libraryBundle(in: path), bundle.isInside { return .blocked(bundle.insideReason) }
        // Known locations outside home (sound libraries, Bazel output) can
        // be offered, but never as more than caution: they're shared.
        if let known = Knowledge.lookup(path: path) {
            if inside("/private/var/tmp"), !TemporarySuggestions.isOwnedByUser(path) {
                return .blocked("Owned by another account or a system service.")
            }
            return verdict(known, path: path, apps: apps, absolute: true)
        }
        if inside("/opt/homebrew") || ["/usr/local/bin", "/usr/local/sbin", "/usr/local/lib", "/usr/local/include",
            "/usr/local/share", "/usr/local/opt", "/usr/local/etc", "/usr/local/var", "/usr/local/Cellar", "/usr/local/Caskroom", "/usr/local/Homebrew"].contains(where: inside) {
            return .blocked("Installed tools and package-manager data. Use Homebrew or the owning tool to remove them.")
        }
        if inside("/Applications") { return .blocked("Use the app uninstall action so its running state and associated data are checked.") }
        if inside("/Library") {
            // System-wide cache/log entries may be reviewed, but not the roots.
            if path.hasPrefix("/Library/Caches/") || path.hasPrefix("/Library/Logs/") {
                let owner = path.split(separator: "/").dropFirst(2).first.map(String.init) ?? ""
                if isSystemOwned(owner) { return .blocked("This cache belongs to macOS. Use the system's own cleanup.") }
                if let app = apps.runningOwner(of: [owner]) { return .quit(app, "these files") }
                return .caution("A shared cache or log. Review it first; macOS permissions still apply.")
            }
            return .blocked("System-wide app data and configuration. Use the owning app or its uninstaller.")
        }
        if inside("/Users") && !inside("/Users/Shared") { return .blocked("Another account's home folder. Clean files from that account instead.") }
        let components = path.split(separator: "/")
        if components.contains(where: { driveHousekeeping.contains(String($0)) || $0 == ".Trashes" }) {
            return .blocked("Disk bookkeeping or backup data. Use the system's cleanup tools.")
        }
        if let bundle = libraryBundle(in: path) { return .caution(bundle.reason) }
        if components.contains(where: { $0.hasSuffix(".code_sign_clone") }) {
            return .blocked("App runtime clones, which may share disk blocks with the installed app. Quit and relaunch the owning app so it can retire unused clones; restart macOS if they persist. Ballast does not delete running-app infrastructure.")
        }
        // /var/folders contains caches for every user and system service.
        if inside("/private/var/folders") {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == getuid(), components.count > 6 else {
                return .blocked("A temporary-files root or files owned by another account. Choose one of your individual cache or temporary items.")
            }
        }
        // /tmp is shared too: only what this account created there.
        if inside(TemporarySuggestions.sharedRoot) {
            guard TemporarySuggestions.isOwnedByUser(path) else {
                return .blocked("Temporary files owned by another account or a system service.")
            }
            return .caution("Shared temporary files. Stop the scripts, builds and tools using them, then review the contents before cleaning. macOS also removes items here left unused for three days.")
        }
        let userTemporaryRoot = TemporarySuggestions.userRoot
        if path.hasPrefix(userTemporaryRoot + "/T/") || path.hasPrefix(userTemporaryRoot + "/C/") {
            return .caution("Temporary build or app files. Stop the related builds, deployments and apps, then review the contents before cleaning. Temporary working copies may contain work you need.")
        }
        if let verdict = buildOutput(path, apps: apps) { return verdict }
        if isDirectory, FileManager.default.fileExists(atPath: path + "/.git") {
            return .caution("A Git working copy. Use Git Worktrees to remove a linked worktree while keeping its branch.")
        }
        return .caution("Review this item before cleaning. Its location is allowed; macOS permissions still apply.")
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
        case "Caches", "Logs":
            if let app = apps.runningOwner(of: [owner] + inner) { return .quit(app, "this cache") }
            return .safe("\(area == "Logs" ? "Logs" : "App cache"). The app rebuilds it when needed.")

        case "HTTPStorages", "WebKit":
            // Cookie stores and website data: removing them signs you out.
            if let app = apps.runningOwner(of: [owner] + inner) { return .quit(app, "these sign-ins") }
            return .caution("Cookies and website data an app keeps. Removing them signs you out of the app.")

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

    // MARK: Knowledge

    /// The verdict a knowledge entry gives `path`. Outside home it's never
    /// more than caution: those folders are shared by every account.
    static func verdict(_ match: KnowledgeMatch, path: String, apps: AppInventory, absolute: Bool) -> Safety {
        if match.level == .blocked { return .blocked(match.reason) }
        if match.entry.olderVersionsSafe, let newer = VersionedFolder.newerSibling(of: match.matchedPath) {
            let name = (match.matchedPath as NSString).lastPathComponent
            let verdict = Safety.safe("\(match.entry.name): \(name) is for an older version than \(newer) beside it, so nothing uses it now.")
            return absolute ? .caution(verdict.reason) : verdict
        }
        if let app = apps.runningOwner(of: match.ownerKeys(path: path)) {
            return Safety(level: .quitFirst,
                          reason: "\(app.name) is open and uses this (\(match.entry.name)). Quit it first so nothing breaks.",
                          app: app)
        }
        if absolute || match.level == .caution { return .caution(match.reason) }
        return .safe(match.reason)
    }

    // MARK: Build output

    /// The verdict for project build output at `path`, or nil when it isn't
    /// any. Most comes back with the next install or build; a venv with
    /// no lockfile, committed Pods or hand-patched dependencies may not.
    static func buildOutput(_ path: String, apps: AppInventory?) -> Safety? {
        let url = URL(fileURLWithPath: path)
        if let kind = ArtifactKind.detect(url) {
            if let caveat = kind.caveat(at: url) { return .caution(caveat) }
            return .safe("Build output (\(kind.title)). Recreated by \(kind.rebuild).")
        }
        if Catalog.isProjectDerivedData(url) {
            if let app = apps?.runningOwner(of: ["com.apple.dt.Xcode"]) { return .quit(app, "this build data") }
            return .safe("Xcode build data kept inside the project. Rebuilt on the next build.")
        }
        return nil
    }

    // MARK: Library bundles

    /// Packages apps keep a whole library in, by extension: the app to
    /// manage each one with.
    static let libraryBundleApps: [String: String] = [
        "photoslibrary": "Photos", "photolibrary": "iPhoto", "aplibrary": "Aperture", "musiclibrary": "Music",
        "tvlibrary": "TV", "fcpbundle": "Final Cut Pro", "imovielibrary": "iMovie", "logicx": "Logic Pro",
        "band": "GarageBand", "lrcat": "Lightroom Classic", "photoboothlibrary": "Photo Booth",
    ]

    struct LibraryBundle: Sendable, Hashable {
        /// The bundle itself.
        let path: String
        /// The app that manages it.
        let app: String
        /// The path is inside the bundle rather than the bundle.
        let isInside: Bool

        var name: String { (path as NSString).lastPathComponent }
        var reason: String {
            "\(name) is a whole \(app) library. Removing it deletes everything in it; manage it in \(app) instead if you can."
        }
        var insideReason: String {
            "Part of \(name), a \(app) library. Removing pieces of it can damage the whole library; manage it in \(app)."
        }
        var holderReason: String {
            "Holds \(name), a \(app) library. Removing this folder deletes the library with it."
        }
    }

    /// The outermost library bundle `path` is or is inside, if any.
    static func libraryBundle(in path: String) -> LibraryBundle? {
        let parts = path.split(separator: "/")
        var prefix = ""
        for (index, part) in parts.enumerated() {
            prefix += "/" + part
            if let app = libraryBundleApps[(String(part) as NSString).pathExtension.lowercased()] {
                return LibraryBundle(path: prefix, app: app, isInside: index < parts.count - 1)
            }
        }
        return nil
    }

    /// Whether `path` is a library bundle or inside one: what suggestions
    /// such as untouched folders must never offer.
    static func isPartOfLibraryBundle(_ path: String) -> Bool {
        libraryBundle(in: path) != nil
    }

    /// A library bundle directly inside the folder at `path`.
    static func heldLibraryBundle(_ path: String) -> LibraryBundle? {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            if let app = libraryBundleApps[(name as NSString).pathExtension.lowercased()] {
                return LibraryBundle(path: path + "/" + name, app: app, isInside: false)
            }
        }
        return nil
    }
}

/// Folders named for an app version ("PyCharm2024.2", "AndroidStudio2023.1"),
/// as JetBrains IDEs and Android Studio keep one per version.
enum VersionedFolder {
    /// "PyCharm2024.2" → ("pycharm", [2024, 2]).
    static func parse(_ name: String) -> (product: String, version: [Int])? {
        guard let digit = name.firstIndex(where: \.isNumber) else { return nil }
        let product = name[..<digit]
        let numbers = name[digit...].split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard !product.isEmpty, product.allSatisfy(\.isLetter), numbers.count >= 2,
              numbers.count == name[digit...].split(separator: ".", omittingEmptySubsequences: false).count else { return nil }
        return (product.lowercased(), numbers)
    }

    /// Whether `version` is older than `other`.
    static func isOlder(_ version: [Int], than other: [Int]) -> Bool {
        for (a, b) in zip(version, other) where a != b { return a < b }
        return version.count < other.count
    }

    /// The newest folder among `siblings` for the same product as `name`
    /// and a newer version, if there is one.
    static func newer(than name: String, among siblings: [String]) -> String? {
        guard let mine = parse(name) else { return nil }
        let newer = siblings.compactMap { sibling -> (name: String, version: [Int])? in
            guard let other = parse(sibling), other.product == mine.product,
                  isOlder(mine.version, than: other.version) else { return nil }
            return (sibling, other.version)
        }
        return newer.max { isOlder($0.version, than: $1.version) }?.name
    }

    /// A newer version's folder beside the folder at `path`, read from disk.
    static func newerSibling(of path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
        return newer(than: (path as NSString).lastPathComponent, among: siblings)
    }
}
