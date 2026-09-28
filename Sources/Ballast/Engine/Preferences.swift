import Foundation
import os

/// Settings the engine needs too: the app, `--index` and `--auto-clean` all
/// read the same file. Auto-clean rules keep their own file (autoclean.json).
struct Preferences: Codable, Equatable, Sendable {
    /// Display paths the scanner skips entirely, e.g. "/Users/me/VMs".
    var excludedFolders: [String] = []
    /// Display paths that are never cleaned, nor anything inside them.
    var protectedFolders: [String] = []
    /// Big folders unchanged for this long are suggested for review.
    var staleMonths = 6
    /// Where the Cleanup List's picker starts: Move to Trash unless changed.
    var deletePermanentlyByDefault = false

    static let staleChoices = [3, 6, 12, 24]

    init() {}

    // Missing keys fall back to defaults, so files from older versions load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()
        excludedFolders = try c.decodeIfPresent([String].self, forKey: .excludedFolders) ?? defaults.excludedFolders
        protectedFolders = try c.decodeIfPresent([String].self, forKey: .protectedFolders) ?? defaults.protectedFolders
        staleMonths = try c.decodeIfPresent(Int.self, forKey: .staleMonths) ?? defaults.staleMonths
        deletePermanentlyByDefault = try c.decodeIfPresent(Bool.self, forKey: .deletePermanentlyByDefault)
            ?? defaults.deletePermanentlyByDefault
    }

    private static var url: URL { URL(fileURLWithPath: Paths.supportDir + "/settings.json") }

    /// Last loaded or saved copy, so hot paths (safety checks, walks) don't
    /// read the file each time.
    private static let cache = OSAllocatedUnfairLock<Preferences?>(initialState: nil)

    static var current: Preferences {
        if let cached = cache.withLock({ $0 }) { return cached }
        return load()
    }

    static func load() -> Preferences {
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
            ?? Preferences()
        cache.withLock { $0 = loaded }
        return loaded
    }

    func save() {
        Self.cache.withLock { $0 = self }
        try? FileManager.default.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.url, options: .atomic)
    }

    /// The form folders are stored in: symlinks resolved (/tmp is
    /// /private/tmp), no trailing slash.
    static func normalized(_ path: String) -> String {
        var resolved = realpath(path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? (path as NSString).standardizingPath
        while resolved.count > 1, resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }
}

/// Folders the scanner leaves out, matched on volume paths
/// ("/System/Volumes/Data/Users/me/VMs").
struct Exclusions: Sendable, Equatable {
    let paths: Set<String>

    init(_ displayPaths: [String]) {
        paths = Set(displayPaths.filter { !$0.isEmpty }.map { path in
            var path = path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return Paths.onVolume(path)
        })
    }

    static var current: Exclusions { Exclusions(Preferences.current.excludedFolders) }

    var isEmpty: Bool { paths.isEmpty }

    /// Exactly an excluded folder: what the walker skips.
    func contains(_ volumePath: String) -> Bool {
        paths.contains(volumePath)
    }

    /// An excluded folder or anything inside one.
    func covers(_ volumePath: String) -> Bool {
        paths.contains { volumePath == $0 || volumePath.hasPrefix($0 + "/") }
    }

    /// Stored with the index, so a changed list is noticed on the next update.
    var fingerprint: String { paths.sorted().joined(separator: "\n") }

    init(fingerprint: String) {
        paths = Set(fingerprint.split(separator: "\n").map(String.init))
    }
}
