import Foundation
import os

/// Settings the engine needs too: the app, `--index`, `--auto-clean` and
/// `--check-space` all read the same file. Auto-clean rules keep their own
/// file (autoclean.json).
struct Preferences: Codable, Equatable, Sendable {
    /// Display paths the scanner skips entirely, e.g. "/Users/me/VMs".
    var excludedFolders: [String] = []
    /// Display paths that are never cleaned, nor anything inside them.
    var protectedFolders: [String] = []
    /// Big folders unchanged for this long are suggested for review.
    var staleMonths = 6
    /// Where the Cleanup List's picker starts: Move to Trash unless changed.
    var deletePermanentlyByDefault = false
    /// Menu bar item with free space and quick actions. While it's shown,
    /// closing the last window keeps Ballast running.
    var showMenuBarItem = true
    /// Free space as text next to the menu bar icon.
    var menuBarShowsFreeSpace = false
    /// Notify when free space drops below `lowSpaceThresholdGB`, checked
    /// hourly by a LaunchAgent and while Ballast is open.
    var lowSpaceAlert = true
    /// Decimal gigabytes, like every figure Ballast shows.
    var lowSpaceThresholdGB = 20
    /// USB drives, SD cards and disk images in the sidebar's Disks section.
    var showRemovableDrives = true

    static let staleChoices = [3, 6, 12, 24]
    static let lowSpaceChoices = [5, 10, 20, 50, 100]

    var lowSpaceThreshold: Int64 { Int64(lowSpaceThresholdGB) * 1_000_000_000 }

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
        showMenuBarItem = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarItem) ?? defaults.showMenuBarItem
        menuBarShowsFreeSpace = try c.decodeIfPresent(Bool.self, forKey: .menuBarShowsFreeSpace)
            ?? defaults.menuBarShowsFreeSpace
        lowSpaceAlert = try c.decodeIfPresent(Bool.self, forKey: .lowSpaceAlert) ?? defaults.lowSpaceAlert
        lowSpaceThresholdGB = try c.decodeIfPresent(Int.self, forKey: .lowSpaceThresholdGB) ?? defaults.lowSpaceThresholdGB
        showRemovableDrives = try c.decodeIfPresent(Bool.self, forKey: .showRemovableDrives) ?? defaults.showRemovableDrives
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

    /// The excluded folders on another volume, whose paths in the index
    /// are its real ones ("/Volumes/Drive/VMs").
    init(drive mountPath: String, _ displayPaths: [String]) {
        paths = Set(displayPaths.compactMap { path in
            var path = path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path.hasPrefix(mountPath + "/") ? path : nil
        })
    }

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
