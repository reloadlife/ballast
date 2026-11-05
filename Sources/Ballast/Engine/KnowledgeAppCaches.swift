import Darwin
import Foundation

/// What `AppCaches` reads from disk, replaceable in tests (and by an
/// index-backed version that knows sizes without walking folders).
struct AppCacheFileSystem: Sendable {
    /// Whether anything is at the path.
    var exists: @Sendable (String) -> Bool
    /// Names of the entries in a folder.
    var children: @Sendable (String) -> [String]
    /// Bytes a folder takes on disk.
    var size: @Sendable (String) -> Int64
    /// `MCMMetadataIdentifier` of a container, see `AppData.containerIdentifier`.
    var containerIdentifier: @Sendable (String) -> String?

    /// The real disk. Sizes are measured by walking the folder, so use it
    /// off the main thread.
    static let live = AppCacheFileSystem(
        exists: { path in
            var st = stat()
            return lstat(path, &st) == 0
        },
        children: { path in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] },
        size: { path in AppCacheFileSystem.allocatedSize(path) },
        containerIdentifier: { AppData.containerIdentifier($0) }
    )

    /// Allocated bytes of everything under `path`, without following links.
    static func allocatedSize(_ path: String) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// One regenerable cache folder of an app.
struct AppCacheFolder: Identifiable, Sendable, Hashable {
    let path: String
    /// What it is: "Cache", "Saved windows", "Slack web cache".
    let label: String
    let bytes: Int64
    /// The knowledge entry describing it, when there is one.
    let knowledgeID: String?
    var id: String { path }
}

/// An app's caches, ready for "Clear Slack's cache (1.2 GB)".
struct AppCacheBreakdown: Identifiable, Sendable, Hashable {
    let bundleID: String
    let name: String
    /// The app bundle, for its icon (`NSWorkspace.shared.icon(forFile:)`).
    let appPath: String
    /// Largest first.
    let folders: [AppCacheFolder]
    var id: String { bundleID }
    var bytes: Int64 { folders.reduce(0) { $0 + $1.bytes } }
    var title: String { "Clear \(name)'s cache" }
}

/// Per-app cache breakdown: only the parts an app rebuilds on its own.
/// Cookies (HTTPStorages), website data (WebKit) and everything else in
/// an app's data folders are left out: removing them signs you out or
/// loses data.
enum AppCaches {
    /// What Chromium and Electron apps keep in their data folder that they
    /// rebuild: the folder name, and how to call it.
    static let chromiumFolders: [(folder: String, label: String)] =
        Knowledge.chromiumProfileCaches.map { ($0.folder, $0.name.prefix(1).uppercased() + $0.name.dropFirst()) }
        + [("Crashpad", "Crash reports waiting to be sent")]

    /// The cache folders of `app` that exist, outermost only, with sizes.
    /// `others` are the other installed apps: a folder another app could
    /// also be using (same name, same group) is left out. UUID-named
    /// containers are only matched with `readContainerMetadata`, as in
    /// `AppData.folders`.
    static func folders(
        for app: AppBundle, others: [AppBundle], library: String = AppLocations.standard.library,
        fs: AppCacheFileSystem = .live, readContainerMetadata: Bool = false
    ) -> [AppCacheFolder] {
        let id = app.bundleID
        guard !id.isEmpty else { return [] }
        let otherApps = others.filter { $0.path != app.path }
        var found: [(path: String, label: String, knowledge: String?)] = []
        func add(_ path: String, _ label: String, knowledge: String? = nil) {
            guard fs.exists(path), !found.contains(where: { $0.path == path }) else { return }
            found.append((path, label, knowledge))
        }

        add(library + "/Caches/" + id, "Cache")
        add(library + "/Saved Application State/" + id + ".savedState", "Saved windows")

        // Containers: by bundle id, and UUID-named ones whose metadata names the app.
        var containers = [library + "/Containers/" + id]
        if readContainerMetadata {
            let root = library + "/Containers"
            containers += fs.children(root).filter { UUID(uuidString: $0) != nil }
                .map { root + "/" + $0 }
                .filter { fs.containerIdentifier($0) == id }
        }
        let supportKeys = [id, app.name].filter { key in
            !key.isEmpty && !otherApps.contains { $0.name == key || $0.bundleID == key }
        }
        for container in containers {
            add(container + "/Data/Library/Caches", "Container cache")
            for key in supportKeys {
                for (folder, label) in chromiumFolders {
                    add(container + "/Data/Library/Application Support/" + key + "/" + folder, label)
                }
            }
        }

        // Group containers the app declares and no other installed app does.
        let shared = Set(otherApps.flatMap(\.groups))
        let groupRoot = library + "/Group Containers"
        var groups = Set(app.groups.filter { !shared.contains($0) }.map { groupRoot + "/" + $0 })
        if readContainerMetadata, !app.groups.isEmpty {
            for name in fs.children(groupRoot) {
                if let group = fs.containerIdentifier(groupRoot + "/" + name), app.groups.contains(group), !shared.contains(group) {
                    groups.insert(groupRoot + "/" + name)
                }
            }
        }
        for group in groups.sorted() { add(group + "/Library/Caches", "Shared cache") }

        // Electron and Chromium apps keep their caches in Application Support.
        for key in supportKeys {
            for (folder, label) in chromiumFolders {
                add(library + "/Application Support/" + key + "/" + folder, label)
            }
        }

        // Caches the knowledge base names for this app (Chrome's in
        // Google/Chrome, VS Code's in Code, Spotify's, Steam's…).
        for entry in Knowledge.entries where entry.owners.contains(id) && isRegenerable(entry) {
            for path in expand(entry.pathPattern, library: library, fs: fs) {
                add(path, entry.name, knowledge: entry.id)
            }
        }

        // Whatever convention says, a folder the knowledge base doesn't
        // call regenerable (a cloud-sync container's caches, a download
        // folder) is never offered as an app's cache.
        let home = (library as NSString).deletingLastPathComponent
        found.removeAll { item in
            guard let match = Knowledge.lookup(path: item.path, home: home) else { return false }
            return match.entry.neverTouch || match.level > .quitFirst
        }
        let outermost = found.filter { item in
            !found.contains { other in other.path != item.path && item.path.hasPrefix(other.path + "/") }
        }
        return outermost
            .map { AppCacheFolder(path: $0.path, label: $0.label, bytes: fs.size($0.path), knowledgeID: $0.knowledge) }
            .sorted { ($0.bytes, $1.path) > ($1.bytes, $0.path) }
    }

    /// Every app's caches of at least `minimumBytes`, largest first. Each
    /// bundle id is listed once, for the first copy of the app.
    static func breakdown(
        apps: [AppBundle], library: String = AppLocations.standard.library, fs: AppCacheFileSystem = .live,
        readContainerMetadata: Bool = false, minimumBytes: Int64 = 1
    ) -> [AppCacheBreakdown] {
        var seen = Set<String>()
        var result: [AppCacheBreakdown] = []
        for app in apps where !app.bundleID.isEmpty && seen.insert(app.bundleID).inserted {
            let folders = folders(for: app, others: apps, library: library, fs: fs,
                                  readContainerMetadata: readContainerMetadata).filter { $0.bytes > 0 }
            let breakdown = AppCacheBreakdown(bundleID: app.bundleID, name: app.name, appPath: app.path, folders: folders)
            if !folders.isEmpty, breakdown.bytes >= minimumBytes { result.append(breakdown) }
        }
        return result.sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
    }

    /// Entries a cache breakdown may offer: caches the app rebuilds.
    static func isRegenerable(_ entry: KnowledgeEntry) -> Bool {
        entry.kind == .cache && (entry.verdict == .safe || entry.verdict == .quitFirst) && !entry.neverTouch
    }

    /// The folders a home-relative "Library/…" pattern matches under
    /// `library`, wildcards expanded one component at a time.
    static func expand(_ pattern: String, library: String, fs: AppCacheFileSystem) -> [String] {
        guard pattern.hasPrefix("Library/") else { return [] }
        var paths = [library]
        for component in pattern.dropFirst("Library/".count).split(separator: "/").map(String.init) {
            let wildcard = component.contains(where: { "*?[".contains($0) })
            paths = paths.flatMap { base -> [String] in
                guard wildcard else { return [base + "/" + component] }
                return fs.children(base).filter { fnmatch(component, $0, FNM_CASEFOLD) == 0 }.sorted().map { base + "/" + $0 }
            }
        }
        return paths.filter(fs.exists)
    }
}
