import Foundation

/// Free space over time, plus how much each cleanup freed. Kept outside the
/// index because a full scan replaces the index file.
struct HistoryPoint: Codable, Identifiable, Sendable {
    let date: Date
    let free: Int64
    /// Bytes freed by a cleanup at this moment, if this point marks one.
    var freed: Int64?

    var id: Date { date }
}

enum History {
    private static let url = URL(fileURLWithPath: Paths.supportDir + "/history.json")
    private static let maxPoints = 2_000

    static func load() -> [HistoryPoint] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([HistoryPoint].self, from: data)) ?? []
    }

    /// Appends a reading unless it adds nothing: same hour and within 1 GB of
    /// the previous one. Cleanup readings are always kept.
    static func record(free: Int64, freed: Int64? = nil) -> [HistoryPoint] {
        var points = load()
        if freed == nil, let last = points.last,
           Date.now.timeIntervalSince(last.date) < 3600, abs(last.free - free) < 1 << 30 {
            return points
        }
        points.append(HistoryPoint(date: .now, free: free, freed: freed))
        points = Array(points.suffix(maxPoints))
        try? FileManager.default.createDirectory(atPath: Paths.supportDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(points).write(to: url, options: .atomic)
        return points
    }
}
