import Foundation
import SwiftUI

enum Category: String, CaseIterable, Identifiable, Sendable {
    case caches = "Caches"
    case artifacts = "Project Build Artifacts"
    case stale = "Untouched"
    case developer = "Developer Tools"
    case appData = "App Data"
    case personal = "Personal Files"

    var id: String { rawValue }

    /// Section title; the stale threshold is a setting.
    func title(staleMonths: Int) -> String {
        guard self == .stale else { return rawValue }
        return staleMonths % 12 == 0
            ? "Untouched for \(staleMonths / 12)+ Year\(staleMonths == 12 ? "" : "s")"
            : "Untouched for \(staleMonths)+ Months"
    }

    var symbol: String {
        switch self {
        case .caches: "archivebox"
        case .developer: "hammer"
        case .appData: "app.badge"
        case .artifacts: "shippingbox"
        case .stale: "clock.badge.exclamationmark"
        case .personal: "person.crop.circle"
        }
    }

    /// Safe to delete without losing anything: it all comes back on its own.
    var isReclaimable: Bool { self == .caches || self == .artifacts }

    var advice: String {
        switch self {
        case .caches: "Rebuilt automatically when needed."
        case .artifacts: "Rebuilt by the next install or build."
        case .stale: "Big folders where nothing has changed in that time."
        case .developer: "Reinstallable, but check you don't need it."
        case .appData: "Clear from inside each app."
        case .personal: "Review by hand."
        }
    }
}

/// How Ballast frees a location's space.
enum CleanAction: Hashable, Sendable {
    /// Remove the file or folder itself.
    case remove
    /// Remove everything inside, keep the folder (~/Library/Caches).
    case contents
    /// Permanently delete what's in ~/.Trash.
    case emptyTrash
    /// Let the owning tool clean up after itself (npm, go, brew…).
    case command(String)
    /// Move an app and its data (see `AppData`) to the Trash.
    case uninstall(bundleID: String, data: [String])

    var symbol: String {
        switch self {
        case .remove: "trash"
        case .contents: "tray.full"
        case .emptyTrash: "trash.slash"
        case .command: "terminal"
        case .uninstall: "xmark.app"
        }
    }

    /// Commands and Empty Trash can't go through the Trash.
    var isAlwaysPermanent: Bool {
        switch self {
        case .remove, .contents, .uninstall: false
        case .emptyTrash, .command: true
        }
    }

    /// Uninstalls go to the Trash even when Delete Now is chosen: an app's
    /// data is worth a way back.
    var isAlwaysTrashed: Bool {
        if case .uninstall = self { return true }
        return false
    }

    func summary(for path: String) -> String {
        switch self {
        case .remove: "Remove"
        case .contents: "Remove everything inside"
        case .emptyTrash: "Empty the Trash"
        case .command(let command): command
        case .uninstall(_, let data): data.isEmpty ? "Move the app to the Trash" : "Move the app and its data to the Trash"
        }
    }

    /// Equivalent shell command, for copying.
    func shell(for path: String) -> String {
        switch self {
        case .remove: "rm -rf '\(path)'"
        case .contents: "rm -rf '\(path)'/*"
        case .emptyTrash: "rm -rf ~/.Trash/*"
        case .command(let command): command
        case .uninstall(_, let data): "mv \(([path] + data).map { "'\($0)'" }.joined(separator: " ")) ~/.Trash/"
        }
    }
}

struct Target: Identifiable, Sendable {
    let id = UUID()
    let name: String
    /// Display path, e.g. "/Users/me/.npm".
    let path: String
    let category: Category
    /// How to free it from inside Ballast; nil means review by hand.
    let action: CleanAction?

    var hint: String? { action?.shell(for: path) }
}

struct ScanResult: Identifiable, Sendable {
    let target: Target
    let bytes: Int64
    /// Unix seconds of the newest modification inside; 0 when unknown.
    var newest: Int64 = 0
    /// For build folders: what kind, and when its project last changed.
    var kind: ArtifactKind?
    var projectNewest: Int64 = 0
    var id: UUID { target.id }
}

enum Catalog {
    static let home = NSHomeDirectory()

    /// Known space hogs, looked up in the index on every reload. An entry
    /// may sit inside a folder another entry empties (pip's cache inside
    /// ~/Library/Caches): the outer one's size leaves it out and emptying
    /// the outer one keeps it, so nothing is counted or cleaned twice.
    static let targets: [Target] = [
        Target(name: "User caches", path: "\(home)/Library/Caches", category: .caches, action: .contents),
        Target(name: "npm cache", path: "\(home)/.npm", category: .caches, action: .command("npm cache clean --force")),
        Target(name: "Bun install cache", path: "\(home)/.bun/install/cache", category: .caches, action: .command("bun pm cache rm")),
        Target(name: "pnpm store", path: "\(home)/Library/pnpm/store", category: .caches, action: .command("pnpm store prune")),
        Target(name: "Yarn cache", path: "\(home)/Library/Caches/Yarn", category: .caches, action: .remove),
        Target(name: "Yarn cache (Berry)", path: "\(home)/.yarn/berry/cache", category: .caches, action: .remove),
        Target(name: "pip cache", path: "\(home)/Library/Caches/pip", category: .caches, action: .command("pip3 cache purge")),
        Target(name: "Composer cache", path: "\(home)/Library/Caches/composer", category: .caches, action: .command("composer clear-cache")),
        Target(name: "Composer cache", path: "\(home)/.composer/cache", category: .caches, action: .command("composer clear-cache")),
        Target(name: "CocoaPods cache", path: "\(home)/Library/Caches/CocoaPods", category: .caches, action: .command("pod cache clean --all")),
        Target(name: "Swift package cache", path: "\(home)/Library/Caches/org.swift.swiftpm", category: .caches, action: .remove),
        Target(name: "Carthage cache", path: "\(home)/Library/Caches/org.carthage.CarthageKit", category: .caches, action: .remove),
        Target(name: "Deno cache", path: "\(home)/Library/Caches/deno", category: .caches, action: .command("deno clean")),
        Target(name: "~/.cache (uv, puppeteer, …)", path: "\(home)/.cache", category: .caches, action: .contents),
        Target(name: "Hugging Face models", path: "\(home)/.cache/huggingface", category: .caches, action: .remove),
        Target(name: "Go module & build cache", path: "\(home)/go/pkg", category: .caches, action: .command("go clean -modcache -cache")),
        Target(name: "Gradle caches", path: "\(home)/.gradle/caches", category: .caches, action: .remove),
        Target(name: "Gradle wrapper downloads", path: "\(home)/.gradle/wrapper/dists", category: .caches, action: .remove),
        Target(name: "Maven repository", path: "\(home)/.m2/repository", category: .caches, action: .remove),
        Target(name: "Cargo registry", path: "\(home)/.cargo/registry", category: .caches, action: .contents),
        Target(name: "Logs", path: "\(home)/Library/Logs", category: .caches, action: .contents),
        Target(name: "Trash", path: "\(home)/.Trash", category: .caches, action: .emptyTrash),

        Target(name: "Homebrew", path: "/opt/homebrew", category: .developer, action: .command("brew cleanup -s --prune=all")),
        Target(name: "Xcode DerivedData", path: "\(home)/Library/Developer/Xcode/DerivedData", category: .developer, action: .contents),
        Target(name: "Xcode archives", path: "\(home)/Library/Developer/Xcode/Archives", category: .developer, action: .remove),
        Target(name: "iOS device support", path: "\(home)/Library/Developer/Xcode/iOS DeviceSupport", category: .developer, action: .remove),
        Target(name: "watchOS device support", path: "\(home)/Library/Developer/Xcode/watchOS DeviceSupport", category: .developer, action: .remove),
        Target(name: "tvOS device support", path: "\(home)/Library/Developer/Xcode/tvOS DeviceSupport", category: .developer, action: .remove),
        Target(name: "SwiftUI previews", path: "\(home)/Library/Developer/Xcode/UserData/Previews", category: .developer, action: .remove),
        Target(name: "Simulator devices", path: "\(home)/Library/Developer/CoreSimulator", category: .developer, action: .command("xcrun simctl delete unavailable")),
        Target(name: "Simulator runtimes", path: "/Library/Developer/CoreSimulator", category: .developer, action: .command("xcrun simctl runtime delete --unusable")),
        Target(name: "Android emulators", path: "\(home)/.android/avd", category: .developer, action: .remove),
        Target(name: "Android system images", path: "\(home)/Library/Android/sdk/system-images", category: .developer, action: .remove),
        Target(name: "Ollama models", path: "\(home)/.ollama/models", category: .developer, action: .remove),
        Target(name: "Rust toolchains", path: "\(home)/.rustup", category: .developer, action: nil),
        Target(name: "Node versions (fnm)", path: "\(home)/.local/share/fnm", category: .developer, action: nil),

        Target(name: "Claude", path: "\(home)/Library/Application Support/Claude", category: .appData, action: nil),
        Target(name: "Telegram", path: "\(home)/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram", category: .appData, action: nil),
        Target(name: "Docker", path: "\(home)/Library/Containers/com.docker.docker", category: .appData, action: .command(dockerPrune)),
        Target(name: "OrbStack", path: "\(home)/.orbstack", category: .appData, action: .command(dockerPrune)),
        Target(name: "Delta Chat", path: "\(home)/Library/Containers/chat.delta.desktop.electron", category: .appData, action: nil),
        Target(name: "iOS device backups", path: "\(home)/Library/Application Support/MobileSync", category: .appData, action: nil),

        Target(name: "Downloads", path: "\(home)/Downloads", category: .personal, action: nil),
        Target(name: "Photos Library", path: "\(home)/Pictures/Photos Library.photoslibrary", category: .personal, action: nil),
        Target(name: "Screenshots", path: "\(home)/Pictures/Screenshots", category: .personal, action: nil),
        Target(name: "Desktop", path: "\(home)/Desktop", category: .personal, action: nil),
        Target(name: "Movies", path: "\(home)/Movies", category: .personal, action: nil),
    ]

    /// Never with --volumes: volumes hold databases and other data.
    static let dockerPrune = "docker system prune --force"

    /// What emptying a folder leaves in place: entries listed on their own
    /// inside another entry's folder, and Ballast's own logs.
    static let keptWhenEmptying: [String] = {
        let emptied = targets.filter { $0.action == .contents }.map(\.path)
        let nested = targets.map(\.path).filter { path in emptied.contains { path.hasPrefix($0 + "/") } }
        return nested + [Paths.logsDir]
    }()

    /// Kept folders directly or further inside `folder`, outermost only, so
    /// their sizes can be taken off the folder's once.
    static func kept(inside folder: String, kept: [String] = keptWhenEmptying) -> [String] {
        let inside = kept.filter { $0.hasPrefix(folder + "/") }
        return inside.filter { path in !inside.contains { path.hasPrefix($0 + "/") } }
    }

    /// Whether cleaning `outer` with `action` also cleans `inner`. Emptying
    /// a folder keeps what's listed on its own, so pip's cache stays a
    /// separate item even with ~/Library/Caches on the list.
    static func covers(_ outer: String, action: CleanAction, _ inner: String, kept: [String] = keptWhenEmptying) -> Bool {
        guard inner.hasPrefix(outer + "/") else { return false }
        guard action == .contents else { return true }
        return !kept.contains { inner == $0 || inner.hasPrefix($0 + "/") }
    }

    /// Whether `dir` is regenerable build output: see `ArtifactKind.detect`.
    static func isProjectArtifact(_ dir: URL) -> Bool {
        ArtifactKind.detect(dir) != nil
    }
}
