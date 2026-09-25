import Foundation
import SwiftUI

enum Category: String, CaseIterable, Identifiable, Sendable {
    case caches = "Caches"
    case artifacts = "Project Build Artifacts"
    case stale = "Untouched for 6+ Months"
    case developer = "Developer Tools"
    case appData = "App Data"
    case personal = "Personal Files"

    var id: String { rawValue }

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
        case .stale: "Big folders nothing has changed in half a year."
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

    var symbol: String {
        switch self {
        case .remove: "trash"
        case .contents: "tray.full"
        case .emptyTrash: "trash.slash"
        case .command: "terminal"
        }
    }

    /// Commands and Empty Trash can't go through the Trash.
    var isAlwaysPermanent: Bool {
        switch self {
        case .remove, .contents: false
        case .emptyTrash, .command: true
        }
    }

    func summary(for path: String) -> String {
        switch self {
        case .remove: "Remove"
        case .contents: "Remove everything inside"
        case .emptyTrash: "Empty the Trash"
        case .command(let command): command
        }
    }

    /// Equivalent shell command, for copying.
    func shell(for path: String) -> String {
        switch self {
        case .remove: "rm -rf '\(path)'"
        case .contents: "rm -rf '\(path)'/*"
        case .emptyTrash: "rm -rf ~/.Trash/*"
        case .command(let command): command
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
    var id: UUID { target.id }
}

enum Catalog {
    static let home = NSHomeDirectory()

    /// Known space hogs, looked up in the index on every reload.
    /// Entries must not overlap, otherwise category totals double-count.
    static let targets: [Target] = [
        Target(name: "User caches", path: "\(home)/Library/Caches", category: .caches, action: .contents),
        Target(name: "npm cache", path: "\(home)/.npm", category: .caches, action: .command("npm cache clean --force")),
        Target(name: "Bun install cache", path: "\(home)/.bun/install/cache", category: .caches, action: .command("bun pm cache rm")),
        Target(name: "~/.cache (uv, puppeteer, …)", path: "\(home)/.cache", category: .caches, action: .contents),
        Target(name: "Go module & build cache", path: "\(home)/go/pkg", category: .caches, action: .command("go clean -modcache -cache")),
        Target(name: "Gradle caches", path: "\(home)/.gradle/caches", category: .caches, action: .remove),
        Target(name: "Cargo registry", path: "\(home)/.cargo/registry", category: .caches, action: .contents),
        Target(name: "Trash", path: "\(home)/.Trash", category: .caches, action: .emptyTrash),

        Target(name: "Homebrew", path: "/opt/homebrew", category: .developer, action: .command("brew cleanup -s --prune=all")),
        Target(name: "Xcode DerivedData", path: "\(home)/Library/Developer/Xcode/DerivedData", category: .developer, action: .contents),
        Target(name: "Simulator devices", path: "\(home)/Library/Developer/CoreSimulator", category: .developer, action: .command("xcrun simctl delete unavailable")),
        Target(name: "Simulator runtimes", path: "/Library/Developer/CoreSimulator", category: .developer, action: nil),
        Target(name: "Rust toolchains", path: "\(home)/.rustup", category: .developer, action: nil),
        Target(name: "Node versions (fnm)", path: "\(home)/.local/share/fnm", category: .developer, action: nil),

        Target(name: "Claude", path: "\(home)/Library/Application Support/Claude", category: .appData, action: nil),
        Target(name: "Telegram", path: "\(home)/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram", category: .appData, action: nil),
        Target(name: "Docker", path: "\(home)/Library/Containers/com.docker.docker", category: .appData, action: nil),
        Target(name: "OrbStack", path: "\(home)/.orbstack", category: .appData, action: nil),
        Target(name: "Delta Chat", path: "\(home)/Library/Containers/chat.delta.desktop.electron", category: .appData, action: nil),
        Target(name: "iOS device backups", path: "\(home)/Library/Application Support/MobileSync", category: .appData, action: nil),

        Target(name: "Downloads", path: "\(home)/Downloads", category: .personal, action: nil),
        Target(name: "Photos Library", path: "\(home)/Pictures/Photos Library.photoslibrary", category: .personal, action: nil),
        Target(name: "Screenshots", path: "\(home)/Pictures/Screenshots", category: .personal, action: nil),
        Target(name: "Desktop", path: "\(home)/Desktop", category: .personal, action: nil),
        Target(name: "Movies", path: "\(home)/Movies", category: .personal, action: nil),
    ]

    /// Decides whether `dir` is regenerable build output that is safe to delete
    /// (it comes back with an install or a rebuild).
    ///
    /// Called for every indexed folder over 10 MB anywhere on the disk, so
    /// check the name first and touch the filesystem only for real candidates.
    ///
    /// Folder names are ambiguous: `target` is Cargo/Maven output only when a
    /// Cargo.toml or pom.xml sits beside it, and `build` or `dist` may be
    /// committed source in some repos. The parent folder can confirm the match:
    ///   let parent = dir.deletingLastPathComponent()
    ///   FileManager.default.fileExists(atPath: parent.appending(path: "Cargo.toml").path)
    static func isProjectArtifact(_ dir: URL) -> Bool {
        // TODO(you): cover .next, target, .venv, DerivedData, Pods, .turbo ...
        return dir.lastPathComponent == "node_modules"
    }
}
