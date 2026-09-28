import Darwin
import Foundation

/// The disk at a glance, saved to status.json for surfaces that can't open
/// the index: the menu bar item and the widget. Every figure is the one the
/// Overview shows, so all of them agree.
///
/// Foundation only, and no other Ballast types: the widget extension links
/// this module and nothing else of Ballast's.
public struct StatusSnapshot: Codable, Equatable, Sendable {
    /// The Overview storage bar's categories, in its order.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case applications, yourFiles, caches, buildFiles, system

        public var title: String {
            switch self {
            case .applications: "Applications"
            case .yourFiles: "Your files"
            case .caches: "Caches"
            case .buildFiles: "Build files"
            case .system: "System Data"
            }
        }
    }

    public struct Segment: Codable, Equatable, Sendable {
        public let kind: Kind
        public let bytes: Int64

        public init(kind: Kind, bytes: Int64) {
            self.kind = kind
            self.bytes = bytes
        }
    }

    /// When the figures below were taken.
    public var date: Date
    public var volumeName: String
    public var totalBytes: Int64
    /// Available for important usage, as the Overview and Finder count it.
    public var freeBytes: Int64
    /// What fills the used space; empty until the disk has been scanned.
    public var segments: [Segment]
    /// What "Add All Safe Items" would clean.
    public var safeToClean: Int64
    /// Measured space freed by cleanups in the last seven days.
    public var freedLastWeek: Int64
    /// When the index was last brought up to date.
    public var scannedAt: Date?

    public init(
        date: Date, volumeName: String, totalBytes: Int64, freeBytes: Int64, segments: [Segment],
        safeToClean: Int64, freedLastWeek: Int64, scannedAt: Date?
    ) {
        self.date = date
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.segments = segments
        self.safeToClean = safeToClean
        self.freedLastWeek = freedLastWeek
        self.scannedAt = scannedAt
    }

    public var usedBytes: Int64 { max(totalBytes - freeBytes, 0) }

    /// New free-space reading, keeping everything that needs the index.
    /// System Data is the balancing segment (used minus everything else), so
    /// it moves with the reading and the bar still adds up.
    public func updating(free: Int64, total: Int64, at date: Date = .now) -> StatusSnapshot {
        var copy = self
        copy.date = date
        copy.freeBytes = free
        copy.totalBytes = total
        if segments.contains(where: { $0.kind == .system }) {
            let others = segments.filter { $0.kind != .system }.reduce(0) { $0 + $1.bytes }
            copy.segments = segments.map { segment in
                segment.kind == .system ? Segment(kind: .system, bytes: max(copy.usedBytes - others, 0)) : segment
            }
        }
        return copy
    }

    // MARK: File

    /// ~/Library/Application Support/Ballast, the same folder as
    /// `Paths.supportDir`, spelled out so this file needs nothing else. The
    /// home folder comes from the user database, not NSHomeDirectory(): in
    /// the sandboxed widget that points into its container, and the widget's
    /// read-only exception is for this real path.
    public static let directory = realHome + "/Library/Application Support/Ballast"
    public static var url: URL { URL(fileURLWithPath: directory + "/status.json") }

    private static let realHome: String = {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }()

    public static func load() -> StatusSnapshot? {
        try? read()
    }

    /// Like `load()`, with the reason when there's nothing to show.
    public static func read() throws -> StatusSnapshot {
        try decoder.decode(StatusSnapshot.self, from: Data(contentsOf: url))
    }

    /// Written atomically: readers never see half a file.
    public func save() {
        try? FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true)
        try? Self.encoder.encode(self).write(to: Self.url, options: .atomic)
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// The startup volume's size and free space, read the one way every Ballast
/// surface reads it.
public enum DiskCapacity {
    /// Free space the way the Overview and Finder count it: available for
    /// important usage, which includes purgeable space macOS can reclaim.
    /// Nil rather than a different figure when that can't be read.
    public static var current: (free: Int64, total: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return nil }
        return (free, Int64(total))
    }

    /// "Macintosh HD", or whatever the startup volume is called.
    public static let volumeName: String =
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
}
