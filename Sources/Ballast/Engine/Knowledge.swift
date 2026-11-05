import Darwin
import Foundation

/// What Ballast knows about one location on disk: what it is, who uses it,
/// whether it can go, and how it comes back. The tables live in the
/// Knowledge*.swift files, one per domain; `SafetyCheck` consults them
/// before its general rules, and the UI uses `Knowledge.explain(path:)`
/// for "What is this?".
struct KnowledgeEntry: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable, CaseIterable {
        case cache, download, userData, model, backup, log, buildOutput, installer, appSupport, system
    }

    /// Stable identifier, "domain.thing": never shown, safe to persist.
    let id: String
    /// What it is, in a few words: "Apple Music downloads".
    let name: String
    /// Relative to the home folder, or absolute when it starts with "/".
    /// `*`, `?` and `[…]` match within one path component; anything inside
    /// a matching folder is covered by the entry too.
    let pathPattern: String
    /// Apps that use it, by bundle id (an app name also works): one of
    /// them running means "quit first". Empty for generic patterns, where
    /// the folder names the wildcards matched stand in.
    var owners: [String] = []
    let kind: Kind
    let verdict: Safety.Level
    /// The verdict for things inside it, when it differs: a backup can go
    /// as a whole, but removing files out of it corrupts it.
    var insideVerdict: Safety.Level? = nil
    /// How Ballast would free it, when it can; nil means review or guide.
    var action: CleanAction? = nil
    /// Plain sentence: what happens when it's removed, and how it comes back.
    let regenerates: String
    /// The in-app way to clean it, when there is one.
    var guidance: String? = nil
    /// macOS only shows it to apps with Full Disk Access.
    var needsFullDiskAccess = false
    /// Synced or system-managed data: nothing inside may be overridden by a
    /// more specific entry, and it is never cleaned.
    var neverTouch = false
    /// Versioned siblings ("PyCharm2023.3" beside "PyCharm2024.2"): a
    /// folder for an older version than one beside it is left over, so safe.
    var olderVersionsSafe = false

    /// The verdict's reason, in the words shown in the Cleanup List.
    var reason: String {
        [name + ".", regenerates, guidance].compactMap { $0 }.joined(separator: " ")
    }
}

/// An entry matched against a path.
struct KnowledgeMatch: Sendable, Hashable {
    let entry: KnowledgeEntry
    /// The folder the pattern matched: the path itself or one of its parents.
    let matchedPath: String
    /// The path is inside `matchedPath` rather than the folder itself.
    let isInside: Bool
    /// What each wildcard component matched, in order.
    let captures: [String]

    var level: Safety.Level { isInside ? (entry.insideVerdict ?? entry.verdict) : entry.verdict }

    var reason: String {
        guard isInside else { return entry.reason }
        if level == .blocked && entry.verdict != .blocked {
            return "Inside: \(entry.name). Removing pieces of it can damage the rest.\(entry.guidance.map { " " + $0 } ?? "")"
        }
        return "Inside: \(entry.name). \(entry.regenerates)\(entry.guidance.map { " " + $0 } ?? "")"
    }

    /// Who to look for among running apps: the entry's owners, or for a
    /// generic pattern the folder names it matched ("Slack" in
    /// Application Support/*/Cache) and the one below.
    func ownerKeys(path: String) -> [String] {
        if !entry.owners.isEmpty { return entry.owners }
        var keys = captures
        if isInside, let next = path.dropFirst(matchedPath.count + 1).split(separator: "/").first {
            keys.append(String(next))
        }
        return keys
    }
}

enum Knowledge {
    /// Every entry, by domain.
    static let entries: [KnowledgeEntry] =
        KnowledgeCloud.entries + KnowledgeApple.entries + KnowledgeMusic.entries + KnowledgeBrowsers.entries
        + KnowledgeMessaging.entries + KnowledgeCreative.entries + KnowledgeDeveloper.entries + KnowledgeApps.entries

    private struct Compiled: Sendable {
        let entry: KnowledgeEntry
        let absolute: Bool
        /// Lowercased components; `literal[i]` says whether one has no wildcard.
        let components: [String]
        let literal: [Bool]
        let literalCount: Int
    }

    private static let compiled: [Compiled] = entries.map { entry in
        let absolute = entry.pathPattern.hasPrefix("/")
        let components = entry.pathPattern.split(separator: "/").map { $0.lowercased() }
        let literal = components.map { !$0.contains(where: { "*?[".contains($0) }) }
        return Compiled(entry: entry, absolute: absolute, components: components, literal: literal,
                        literalCount: literal.filter { $0 }.count)
    }

    /// The entry that describes `path` (an absolute display path), if any.
    /// The most specific pattern wins: the most literal components, then
    /// the most components, then the earlier entry. An entry marked
    /// `neverTouch` beats anything more specific inside it.
    static func lookup(path: String, home: String = NSHomeDirectory()) -> KnowledgeMatch? {
        let absolute: Bool
        let prefix: String
        if path.hasPrefix(home + "/") {
            absolute = false
            prefix = home
        } else if path.hasPrefix("/") {
            absolute = true
            prefix = ""
        } else {
            return nil
        }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        let lowered = parts.map { $0.lowercased() }

        var best: (compiled: Compiled, captures: [String])?
        func rank(_ c: Compiled) -> (Int, Int, Int) { (c.entry.neverTouch ? 1 : 0, c.literalCount, c.components.count) }
        for candidate in compiled where candidate.absolute == absolute && candidate.components.count <= parts.count {
            var captures: [String] = []
            var matches = true
            for (index, component) in candidate.components.enumerated() {
                if candidate.literal[index] {
                    if component != lowered[index] { matches = false; break }
                } else if fnmatch(component, parts[index], FNM_CASEFOLD) == 0 {
                    captures.append(parts[index])
                } else {
                    matches = false
                    break
                }
            }
            guard matches else { continue }
            if let current = best, rank(current.compiled) >= rank(candidate) { continue }
            best = (candidate, captures)
        }
        guard let best else { return nil }
        let count = best.compiled.components.count
        let matched = prefix + "/" + parts.prefix(count).joined(separator: "/")
        return KnowledgeMatch(entry: best.compiled.entry, matchedPath: matched,
                              isInside: parts.count > count, captures: best.captures)
    }

    /// "What is this?": the entry describing `path`, or the folder it's in.
    static func explain(path: String, home: String = NSHomeDirectory()) -> KnowledgeEntry? {
        lookup(path: path, home: home)?.entry
    }

    /// The entry with this id.
    static func entry(id: String) -> KnowledgeEntry? {
        byID[id]
    }

    private static let byID: [String: KnowledgeEntry] = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// Entries without wildcards, as absolute paths: what can be listed
    /// or kept by exact path.
    static func literalPaths(where include: (KnowledgeEntry) -> Bool, home: String = NSHomeDirectory()) -> [String] {
        compiled.filter { $0.literal.allSatisfy { $0 } && include($0.entry) }.map { item in
            item.absolute ? item.entry.pathPattern : home + "/" + item.entry.pathPattern
        }
    }

    // MARK: Building blocks for the tables

    /// The cache folders Chromium and Electron keep inside a profile.
    static let chromiumProfileCaches: [(folder: String, name: String)] = [
        ("Cache", "web cache"), ("Code Cache", "compiled script cache"), ("GPUCache", "graphics cache"),
        ("DawnCache", "graphics shader cache"), ("DawnGraphiteCache", "graphics shader cache"),
        ("DawnWebGPUCache", "WebGPU shader cache"), ("Service Worker/CacheStorage", "offline website copies"),
        ("Service Worker/ScriptCache", "website script cache"),
    ]

    /// Cache folders Chromium keeps once per install, beside the profiles.
    static let chromiumSharedCaches: [(folder: String, name: String)] = [
        ("GrShaderCache", "graphics shader cache"), ("ShaderCache", "graphics shader cache"),
        ("GraphiteDawnCache", "graphics shader cache"), ("component_crx_cache", "downloaded browser components"),
        ("Crashpad", "crash reports waiting to be sent"),
    ]

    /// An Electron app's data folder: protected as a whole (sign-in,
    /// settings, local data), with its regenerable caches carved out.
    static func electron(_ id: String, _ app: String, root: String, owners: [String],
                         guidance: String? = nil, extra: [(folder: String, name: String)] = []) -> [KnowledgeEntry] {
        let data = KnowledgeEntry(
            id: id, name: "\(app)'s data", pathPattern: root, owners: owners, kind: .appSupport, verdict: .blocked,
            regenerates: "Your sign-in, settings and anything \(app) saved locally. Removing it signs you out and can lose data.",
            guidance: guidance
        )
        let caches = (chromiumProfileCaches + [("Crashpad", "crash reports waiting to be sent")] + extra).map { folder, name in
            KnowledgeEntry(
                id: id + "." + slug(folder), name: "\(app) \(name)", pathPattern: root + "/" + folder, owners: owners,
                kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "\(app) makes it again as you use it."
            )
        }
        return [data] + caches
    }

    /// A Chromium browser's data: profiles protected, caches carved out.
    static func chromium(_ id: String, _ browser: String, root: String, caches: String?, owners: [String],
                         guidance: String) -> [KnowledgeEntry] {
        var found = [KnowledgeEntry(
            id: id, name: "\(browser) profiles", pathPattern: root, owners: owners, kind: .userData, verdict: .blocked,
            regenerates: "Bookmarks, saved passwords, history, open tabs and extensions. They don't come back unless you sync.",
            guidance: guidance
        )]
        found += chromiumCaches(id, browser, root: root, owners: owners)
        found.append(KnowledgeEntry(
            id: id + ".on-device-model", name: "\(browser)'s on-device AI model", pathPattern: root + "/OptGuideOnDeviceModel",
            owners: owners, kind: .model, verdict: .caution, action: .remove,
            regenerates: "A language model of several gigabytes for \(browser)'s built-in AI features. \(browser) downloads it again while those features are on.",
            guidance: "To keep it from coming back, turn off on-device AI in \(browser)'s settings under System."
        ))
        if let caches {
            found.append(KnowledgeEntry(
                id: id + ".caches", name: "\(browser) web cache", pathPattern: caches, owners: owners,
                kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "\(browser) fills it again as you browse; pages load a little slower at first."
            ))
        }
        return found
    }

    /// The caches inside a Chromium data folder ("User Data"): per profile,
    /// and the ones shared by every profile.
    static func chromiumCaches(_ id: String, _ app: String, root: String, owners: [String]) -> [KnowledgeEntry] {
        chromiumProfileCaches.map { folder, name in
            KnowledgeEntry(
                id: id + ".profile." + slug(folder), name: "\(app) \(name)", pathPattern: root + "/*/" + folder,
                owners: owners, kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "\(app) fills it again as it's used; pages load a little slower at first."
            )
        } + chromiumSharedCaches.map { folder, name in
            KnowledgeEntry(
                id: id + "." + slug(folder), name: "\(app) \(name)", pathPattern: root + "/" + folder,
                owners: owners, kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "\(app) makes or downloads it again when needed."
            )
        }
    }

    /// "Service Worker/CacheStorage" → "service-worker-cachestorage".
    static func slug(_ text: String) -> String {
        text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
    }
}
