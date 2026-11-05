import Foundation

/// "What is this?" for one path, ready to show: what the knowledge base
/// says about the path or the known folder it's inside.
struct KnowledgeExplanation: Sendable, Hashable, Identifiable {
    /// The knowledge entry's id ("music.apple-music-downloads").
    let entryID: String
    /// The folder the entry describes: the path itself, or the known
    /// folder the path is inside.
    let matchedPath: String
    /// The path is inside `matchedPath` rather than the folder itself.
    let isInside: Bool
    /// The heading: "Apple Music downloads", or "Inside Apple Music downloads".
    let title: String
    /// What it is, in a few words: "Apple Music downloads".
    let whatItIs: String
    let kind: KnowledgeEntry.Kind
    /// The kind in words: "Cache", "Downloads", "Your data"…
    let kindTitle: String
    /// What happens when it's removed, and whether and how it comes back.
    let whenRemoved: String
    /// The in-app way to clean it, when there is one.
    let guidance: String?
    /// The knowledge base's verdict for the path (inside a folder, the
    /// verdict for its contents). Running apps and protected folders can
    /// make the Cleanup List's verdict stricter; it's checked again then.
    let level: Safety.Level
    /// The verdict's reason, in the Cleanup List's words.
    let reason: String
    /// macOS only shows it to apps with Full Disk Access.
    let needsFullDiskAccess: Bool
    /// Apps that use it, by bundle id (or name).
    let owners: [String]
    /// How Ballast would free the path, when it can; nil means guidance only.
    let action: CleanAction?
    /// Synced or system-managed: never cleaned, nothing inside overrides it.
    let neverTouch: Bool

    var id: String { entryID + "|" + matchedPath }

    init(_ match: KnowledgeMatch) {
        let entry = match.entry
        entryID = entry.id
        matchedPath = match.matchedPath
        isInside = match.isInside
        title = match.isInside ? "Inside \(entry.name)" : entry.name
        whatItIs = entry.name
        kind = entry.kind
        kindTitle = entry.kind.title
        whenRemoved = entry.regenerates
        guidance = entry.guidance
        level = match.level
        reason = match.reason
        needsFullDiskAccess = entry.needsFullDiskAccess
        owners = entry.owners
        // An entry's action is for the folder it describes, not for a piece of it.
        action = match.isInside || match.level == .blocked ? nil : entry.action
        neverTouch = entry.neverTouch
    }
}

extension KnowledgeEntry.Kind {
    /// The kind in words, for "What is this?".
    var title: String {
        switch self {
        case .cache: "Cache"
        case .download: "Downloads"
        case .userData: "Your data"
        case .model: "AI model"
        case .backup: "Backup"
        case .log: "Logs"
        case .buildOutput: "Build output"
        case .installer: "Installer"
        case .appSupport: "App data"
        case .system: "System data"
        }
    }
}

extension Knowledge {
    /// "What is this?" for a display path; nil when the knowledge base
    /// doesn't know it. Pure lookup, no disk access.
    static func explanation(path: String, home: String = NSHomeDirectory()) -> KnowledgeExplanation? {
        lookup(path: path, home: home).map(KnowledgeExplanation.init)
    }

    /// The same, worked out off the main actor: views call this from a
    /// `.task`, never `explanation(path:)` in a body.
    static func explainAsync(path: String, home: String = NSHomeDirectory()) async -> KnowledgeExplanation? {
        await Task.detached(priority: .userInitiated) { explanation(path: path, home: home) }.value
    }

    /// Explanations for many paths at once (every row of a list), by path;
    /// paths the knowledge base doesn't know are left out.
    static func explainAsync(paths: [String], home: String = NSHomeDirectory()) async -> [String: KnowledgeExplanation] {
        await Task.detached(priority: .userInitiated) {
            var found: [String: KnowledgeExplanation] = [:]
            for path in paths where found[path] == nil {
                if let explanation = explanation(path: path, home: home) { found[path] = explanation }
            }
            return found
        }.value
    }
}
