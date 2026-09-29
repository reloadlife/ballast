import Darwin
import Foundation

struct Overview: Sendable {
    let root: DirRow
    let top: [DirRow]
    let home: DirRow?
    let homeChildren: [DirRow]
    /// Folders blocked by Unix permissions: an admin scan can read them.
    let lockedByPermissions: Int
    /// Folders blocked by macOS privacy protection: need Full Disk Access.
    let lockedByPrivacy: Int
    let scannedAt: Date?
}

/// A folder where space concentrates: big, with no subfolder holding more
/// than a quarter of it, so the space is really here and not further down.
struct Hotspot: Identifiable, Sendable {
    let row: DirRow
    /// Display path.
    let path: String
    var id: Int64 { row.id }
}

/// A folder found by Explorer search.
struct SearchHit: Identifiable, Sendable, Hashable {
    let row: DirRow
    /// Display path.
    let path: String
    var id: Int64 { row.id }
}

/// Read side of an index, used by the UI. Scans write through their own
/// connection, so reads never wait on a running scan. One reader per
/// index: the startup disk's, and one for each other volume with one.
actor IndexReader {
    /// The SQLite file.
    let index: String
    /// The startup disk's index: paths there are volume paths
    /// ("/System/Volumes/Data/Users/…"); other volumes' are real paths.
    let isStartup: Bool
    private var db: IndexDB?

    init(index: String = Paths.index, isStartup: Bool = true) {
        self.index = index
        self.isStartup = isStartup
    }

    private func onVolume(_ display: String) -> String {
        isStartup ? Paths.onVolume(display) : display
    }
    /// Build folders found in the current index; recomputed after reopen().
    private var artifactCache: [Artifact]?

    private func scannedArtifacts(_ db: IndexDB) -> [Artifact] {
        if let artifactCache { return artifactCache }
        let found = ArtifactScanner.scan(db)
        artifactCache = found
        return found
    }

    func reopen() {
        artifactCache = nil
        db = FileManager.default.fileExists(atPath: index) ? try? IndexDB(path: index, mode: .read) : nil
    }

    func overview() -> Overview? {
        db.flatMap { Self.overview($0, home: isStartup) }
    }

    /// Static so command-line runs can read the index without the actor.
    /// `home` looks up the home folder, which only the startup disk has.
    static func overview(_ db: IndexDB, home findHome: Bool = true) -> Overview? {
        guard let root = try? db.root() else { return nil }
        let homePath = Paths.onVolume(NSHomeDirectory())
        let home = findHome ? (try? db.locate(homePath))?.last.flatMap { $0.path == homePath ? $0.row : nil } : nil
        // A drive's .Trashes only lets each user into their own folder; it
        // can't be read by design, so it isn't news worth a note.
        let locked = ((try? db.unreadable()) ?? []).filter { findHome || !($0.name == ".Trashes" && $0.parent == root.id) }
        return Overview(
            root: root,
            top: (try? db.children(of: root.id)) ?? [],
            home: home,
            homeChildren: home.flatMap { try? db.children(of: $0.id) } ?? [],
            lockedByPermissions: locked.count { $0.err == EACCES },
            lockedByPrivacy: locked.count { $0.err != EACCES },
            scannedAt: (try? db.meta("scannedAt")).flatMap { $0.flatMap(Double.init) }.map(Date.init(timeIntervalSince1970:))
        )
    }

    /// Root-first breadcrumb plus the folder's children, biggest first.
    func explore(_ id: Int64) -> (trail: [DirRow], children: [DirRow]) {
        guard let db else { return ([], []) }
        return ((try? db.chain(to: id)) ?? [], (try? db.children(of: id)) ?? [])
    }

    /// Deepest indexed folder on `path` (a volume path).
    func deepest(_ path: String) -> Int64? {
        (try? db?.locate(path))??.last?.row.id
    }

    func path(of id: Int64) -> String? {
        try? db?.path(of: id)
    }

    /// Size of an exactly indexed folder, for items dragged onto the list.
    func size(ofPath path: String) -> (bytes: Int64, newest: Int64)? {
        let volumePath = onVolume(path)
        guard let found = (try? db?.locate(volumePath))??.last, found.path == volumePath else { return nil }
        return (found.row.total, found.row.newest)
    }

    /// Volume paths of unreadable folders; `permissionsOnly` limits the list
    /// to ones root can open.
    func lockedPaths(permissionsOnly: Bool) -> [String] {
        guard let db, let rows = try? db.unreadable() else { return [] }
        return rows
            .filter { !permissionsOnly || $0.err == EACCES }
            .compactMap { try? db.path(of: $0.id) }
    }

    // MARK: Search

    /// Folders anywhere on the disk whose name contains `text`, biggest first.
    func search(_ text: String, limit: Int = 200) -> [SearchHit] {
        guard let db, let rows = try? db.search(text, limit: limit) else { return [] }
        // Hits share ancestors, so each folder's path is looked up once.
        var paths: [Int64: String] = [:]
        func path(_ id: Int64) -> String? {
            if let known = paths[id] { return known }
            guard let row = try? db.row(id) else { return nil }
            let full = row.parent.map { path($0).map { $0 + "/" + row.name } } ?? row.name
            paths[id] = full
            return full
        }
        return rows.compactMap { row in path(row.id).map { SearchHit(row: row, path: Paths.display($0)) } }
    }

    // MARK: Growth

    /// Sizes worth keeping for "what grew": display path → bytes for every
    /// folder of at least the store's floor.
    func growthSizes() -> [String: Int64] {
        db.map(Self.growthSizes) ?? [:]
    }

    static func growthSizes(_ db: IndexDB) -> [String: Int64] {
        Dictionary(bigFolders(in: db, atLeast: GrowthStore.floor).map { ($0.path, $0.row.total) },
                   uniquingKeysWith: max)
    }

    // MARK: Suggestions

    /// Known locations, project build output, and big folders nobody has
    /// touched in `staleMonths` (six unless changed in Settings).
    func cleanup(staleMonths: Int) -> [ScanResult] {
        guard isStartup, let db else { return [] }
        return Self.cleanup(db, staleMonths: staleMonths, artifacts: scannedArtifacts(db))
    }

    /// `artifacts` comes from ArtifactScanner, which the actor caches.
    static func cleanup(_ db: IndexDB, staleMonths: Int, artifacts found: [Artifact]) -> [ScanResult] {
        func size(_ display: String) -> DirRow? {
            let path = Paths.onVolume(display)
            guard let found = (try? db.locate(path))?.last, found.path == path else { return nil }
            return found.row
        }
        let known: [ScanResult] = Catalog.targets.compactMap { target in
            guard let row = size(target.path) else { return nil }
            // What emptying keeps (pip's cache in ~/Library/Caches) is
            // listed on its own, not in this entry's size.
            var bytes = row.total
            if target.action == .contents {
                bytes -= Catalog.kept(inside: target.path).compactMap { size($0)?.total }.reduce(0, +)
            }
            guard bytes > 0 else { return nil }
            return ScanResult(target: target, bytes: bytes, newest: row.newest)
        }
        let big = bigFolders(in: db, atLeast: 10 << 20)
        let artifacts = results(for: found)
        let claimed = Set(known.map(\.target.path) + artifacts.map(\.target.path))
        return known + artifacts + stale(big, months: staleMonths, excluding: claimed)
    }

    func hotspots(limit: Int = 10, atLeast floor: Int64 = 1 << 30) -> [Hotspot] {
        guard let db else { return [] }
        let big = Self.bigFolders(in: db, atLeast: floor)
        let largestChild = Dictionary(
            big.compactMap { entry in entry.row.parent.map { ($0, entry.row.total) } },
            uniquingKeysWith: max
        )
        return big
            .filter { $0.row.parent != nil }
            .filter { Double(largestChild[$0.row.id] ?? 0) < Double($0.row.total) * 0.25 }
            .sorted { $0.row.total > $1.row.total }
            .prefix(limit)
            .map { Hotspot(row: $0.row, path: $0.path) }
    }

    /// Every folder of at least `bytes`, with its display path. Totals only
    /// grow toward the root, so each row's ancestors are in the set too.
    private static func bigFolders(in db: IndexDB, atLeast bytes: Int64) -> [(row: DirRow, path: String)] {
        guard let rows = try? db.rows(atLeast: bytes) else { return [] }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var paths: [Int64: String] = [:]
        func path(_ id: Int64) -> String? {
            if let known = paths[id] { return known }
            guard let row = byID[id] else { return nil }
            let full = row.parent.map { path($0).map { $0 + "/" + row.name } } ?? row.name
            paths[id] = full
            return full
        }
        return rows.compactMap { row in path(row.id).map { (row, Paths.display($0)) } }
    }

    /// Suggestions for build folders: "app/node_modules" for projects in
    /// ~/projects, "~/…" elsewhere at home, "Drive/…" on other drives.
    static func results(for artifacts: [Artifact]) -> [ScanResult] {
        let projects = Catalog.home + "/projects/"
        return artifacts.filter { $0.bytes >= 1 << 20 }.map { artifact in
            let name = artifact.path.hasPrefix(projects) ? String(artifact.path.dropFirst(projects.count))
                : artifact.path.hasPrefix("/Volumes/") ? String(artifact.path.dropFirst("/Volumes/".count))
                : artifact.path.replacingOccurrences(of: Catalog.home, with: "~")
            return ScanResult(
                target: Target(name: name, path: artifact.path, category: .artifacts, action: .remove),
                bytes: artifact.bytes, newest: artifact.projectNewest,
                kind: artifact.kind, projectNewest: artifact.projectNewest
            )
        }
    }

    /// Build folders on this volume as suggestions, for other drives.
    func artifactSuggestions() -> [ScanResult] {
        guard let db else { return [] }
        return Self.results(for: scannedArtifacts(db))
    }

    /// Every confirmed build folder, any size: what auto-clean rules act on.
    func allArtifacts() -> [Artifact] {
        guard let db else { return [] }
        return scannedArtifacts(db)
    }

    private static func stale(_ big: [(row: DirRow, path: String)], months: Int, excluding claimed: Set<String>) -> [ScanResult] {
        let cutoff = Int64(Date.now.addingTimeInterval(-Double(months) * 30.44 * 86_400).timeIntervalSince1970)
        let library = Catalog.home + "/Library/"
        let candidates = big.filter { entry in
            entry.row.total >= 500 << 20
                && entry.row.newest > 0 && entry.row.newest < cutoff
                && Cleaner.canRemove(entry.path)
                && !entry.path.hasPrefix(library)
                && !entry.path.hasSuffix(".photoslibrary")
                && !claimed.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") || $0.hasPrefix(entry.path + "/") }
        }
        return outermost(candidates).sorted { $0.row.total > $1.row.total }.prefix(50).map { entry in
            ScanResult(
                target: Target(
                    name: entry.path.replacingOccurrences(of: Catalog.home, with: "~"),
                    path: entry.path, category: .stale, action: .remove
                ),
                bytes: entry.row.total,
                newest: entry.row.newest
            )
        }
    }

    /// Drops entries nested inside another entry: node_modules inside
    /// node_modules is already counted by the outer one.
    private static func outermost(_ entries: [(row: DirRow, path: String)]) -> [(row: DirRow, path: String)] {
        var kept: [(row: DirRow, path: String)] = []
        var keptPaths = Set<String>()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            var ancestor = (entry.path as NSString).deletingLastPathComponent
            var nested = false
            while ancestor.count > 1 {
                if keptPaths.contains(ancestor) { nested = true; break }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            if !nested {
                kept.append(entry)
                keptPaths.insert(entry.path)
            }
        }
        return kept
    }
}
