import Foundation

/// The disk at a glance, saved to status.json for surfaces that can't open
/// the index: the menu bar item today, a widget and App Intents later. Every
/// figure is the one the Overview shows, so all of them agree.
///
/// Foundation only, and no other Ballast types: a widget extension target
/// can compile this file on its own.
struct StatusSnapshot: Codable, Equatable, Sendable {
    /// The Overview storage bar's categories, in its order.
    enum Kind: String, Codable, CaseIterable, Sendable {
        case applications, yourFiles, caches, buildFiles, system

        var title: String {
            switch self {
            case .applications: "Applications"
            case .yourFiles: "Your files"
            case .caches: "Caches"
            case .buildFiles: "Build files"
            case .system: "System Data"
            }
        }
    }

    struct Segment: Codable, Equatable, Sendable {
        let kind: Kind
        let bytes: Int64
    }

    /// When the figures below were taken.
    var date: Date
    var volumeName: String
    var totalBytes: Int64
    /// Available for important usage, as the Overview and Finder count it.
    var freeBytes: Int64
    /// What fills the used space; empty until the disk has been scanned.
    var segments: [Segment]
    /// What "Add All Safe Items" would clean.
    var safeToClean: Int64
    /// Measured space freed by cleanups in the last seven days.
    var freedLastWeek: Int64
    /// When the index was last brought up to date.
    var scannedAt: Date?

    var usedBytes: Int64 { max(totalBytes - freeBytes, 0) }

    /// New free-space reading, keeping everything that needs the index.
    /// System Data is the balancing segment (used minus everything else), so
    /// it moves with the reading and the bar still adds up.
    func updating(free: Int64, total: Int64, at date: Date = .now) -> StatusSnapshot {
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
    /// `Paths.supportDir`, spelled out so this file needs nothing else.
    /// A sandboxed widget will need an App Group container instead.
    static let directory = NSHomeDirectory() + "/Library/Application Support/Ballast"
    static var url: URL { URL(fileURLWithPath: directory + "/status.json") }

    static func load() -> StatusSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(StatusSnapshot.self, from: data)
    }

    /// Written atomically: readers never see half a file.
    func save() {
        try? FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true)
        try? Self.encoder.encode(self).write(to: Self.url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
