import Darwin
import Foundation

/// A place a music, audio, photo or video app keeps something big, from
/// the knowledge base: Apple Music downloads, Spotify's cache, GarageBand
/// and Logic Pro sound libraries, Final Cut Pro render files, Photos
/// previews, Podcasts downloads. Some can go on the Cleanup List; the
/// rest (`canAddToPlan` false) say how to clean them in their app.
struct MediaLocation: Identifiable, Sendable, Hashable {
    /// The knowledge entry's id and the path it matched: "spotify.cache|/Users/…".
    let id: String
    let knowledgeID: String
    /// What it is: "Apple Music downloads".
    let name: String
    /// Display path.
    let path: String
    /// Everything at the location: what cleaning it frees.
    let bytes: Int64
    /// The part not listed under a more specific location inside it (the
    /// Music library minus its Apple Music downloads): what the list is
    /// sorted by and what a section total adds up.
    let ownBytes: Int64
    /// The safety verdict when the list loaded, with the apps open then.
    /// Adding it to the Cleanup List checks again.
    let level: Safety.Level
    /// The verdict's reason, in the Cleanup List's words.
    let reason: String
    let kind: KnowledgeEntry.Kind
    /// What happens when it's removed, and how it comes back.
    let regenerates: String
    /// How to clean it in its app, when there is a way.
    let guidance: String?
    /// The app it belongs to, when it's installed: "Music", "Spotify".
    let appName: String?
    /// How Ballast frees it; nil means guidance only.
    let action: CleanAction?
    /// macOS only shows it to apps with Full Disk Access.
    let needsFullDiskAccess: Bool
    /// The Suggestions entry that already counts and cleans it (Spotify's
    /// cache is in "User caches"), by path; see `AppCaches.coveringTarget`.
    var coveredBy: String? = nil

    /// Blocked locations, and ones Ballast has no way to clean, are
    /// guidance only.
    var canAddToPlan: Bool { level != .blocked && action != nil }

    /// The Cleanup List entry, when it can have one.
    var planCandidate: PlanCandidate? {
        guard canAddToPlan, let action else { return nil }
        return PlanCandidate(name: name, path: path, bytes: bytes, action: action)
    }
}

/// Finds the music and media locations on this Mac.
enum MediaLocations {
    /// Knowledge domains that are music and media apps (KnowledgeCreative
    /// also holds editors and games, which are left out).
    static let domains = ["music.", "podcasts.", "audio.", "spotify.", "ableton.", "adobe.", "video.", "photos."]

    /// Smaller locations aren't worth a row.
    static let minimumBytes: Int64 = 50_000_000

    /// The entries the section is built from.
    static let entries: [KnowledgeEntry] = Knowledge.entries.filter { entry in domains.contains { entry.id.hasPrefix($0) } }

    /// Every music and media location of at least `minimumBytes` (of its
    /// own, see `MediaLocation.ownBytes`), largest first. Wildcards are
    /// expanded against `fs` once per call; sizes come from `fs` too (the
    /// index, with walks only for what it doesn't hold). `assess` gives
    /// each location's verdict. `cancel` makes it stop and return nothing.
    static func locations(
        home: String = NSHomeDirectory(), fs: AppCacheFileSystem = .live, apps: AppInventory,
        minimumBytes: Int64 = minimumBytes, entries: [KnowledgeEntry] = entries, targets: [Target] = Catalog.targets,
        cancel: CancelFlag? = nil, assess: (String) -> Safety
    ) -> [MediaLocation] {
        var found: [(entry: KnowledgeEntry, path: String)] = []
        var seen = Set<String>()
        for entry in entries {
            if cancel?.isSet == true { return [] }
            for path in expand(entry.pathPattern, home: home, fs: fs) where seen.insert(path).inserted {
                // Only where this entry is the one that describes the path:
                // a more specific or a never-touch entry wins.
                guard let match = Knowledge.lookup(path: path, home: home), match.entry.id == entry.id, !match.isInside
                else { continue }
                found.append((entry, path))
            }
        }

        var sized: [(entry: KnowledgeEntry, path: String, bytes: Int64)] = []
        for item in found {
            if cancel?.isSet == true { return [] }
            sized.append((item.entry, item.path, fs.size(item.path)))
        }

        // Deepest first, so a location knows which of its insides are listed.
        let deepestFirst = sized.sorted { ($0.path.split(separator: "/").count, $1.path) > ($1.path.split(separator: "/").count, $0.path) }
        var listed: [String: Int64] = [:]
        var result: [MediaLocation] = []
        for item in deepestFirst {
            let inside = listed.filter { $0.key.hasPrefix(item.path + "/") }
            let outermost = inside.filter { path, _ in !inside.keys.contains { path.hasPrefix($0 + "/") } }
            let own = max(item.bytes - outermost.values.reduce(0, +), 0)
            guard own >= minimumBytes else { continue }
            listed[item.path] = item.bytes
            let safety = assess(item.path)
            result.append(MediaLocation(
                id: item.entry.id + "|" + item.path, knowledgeID: item.entry.id, name: item.entry.name, path: item.path,
                bytes: item.bytes, ownBytes: own, level: safety.level, reason: safety.reason, kind: item.entry.kind,
                regenerates: item.entry.regenerates, guidance: item.entry.guidance,
                appName: appName(owners: item.entry.owners, apps: apps),
                action: safety.level == .blocked ? nil : item.entry.action,
                needsFullDiskAccess: item.entry.needsFullDiskAccess,
                coveredBy: AppCaches.coveringTarget(item.path, targets: targets)
            ))
        }
        return result.sorted { ($0.ownBytes, $1.path) > ($1.ownBytes, $0.path) }
    }

    /// The first owner that's installed or open, by name.
    static func appName(owners: [String], apps: AppInventory) -> String? {
        for owner in owners {
            if let app = apps.installed.first(where: { $0.bundleID == owner }) { return app.name }
            if let app = apps.running.first(where: { $0.bundleID == owner }) { return app.name }
        }
        return nil
    }

    /// The folders a knowledge pattern matches: relative to `home`, or
    /// absolute when it starts with "/". Wildcard components are matched
    /// against the folder's listing, ignoring case, so "Media*" finds
    /// "Media.localized".
    static func expand(_ pattern: String, home: String, fs: AppCacheFileSystem) -> [String] {
        var paths = [pattern.hasPrefix("/") ? "" : home]
        for component in pattern.split(separator: "/").map(String.init) {
            let wildcard = component.contains(where: { "*?[".contains($0) })
            paths = paths.flatMap { base -> [String] in
                guard wildcard else { return [base + "/" + component] }
                return fs.children(base.isEmpty ? "/" : base)
                    .filter { fnmatch(component, $0, FNM_CASEFOLD) == 0 }
                    .sorted()
                    .map { base + "/" + $0 }
            }
            if paths.isEmpty { return [] }
        }
        return paths.filter(fs.exists)
    }
}
