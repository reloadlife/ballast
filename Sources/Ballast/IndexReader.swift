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

/// Read side of the index, used by the UI. Scans write through their own
/// connection, so reads never wait on a running scan.
actor IndexReader {
    private var db: IndexDB?
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
        db = FileManager.default.fileExists(atPath: Paths.index) ? try? IndexDB(path: Paths.index, mode: .read) : nil
    }

    func overview() -> Overview? {
        guard let db, let root = try? db.root() else { return nil }
        let homePath = Paths.onVolume(NSHomeDirectory())
        let home = (try? db.locate(homePath))?.last.flatMap { $0.path == homePath ? $0.row : nil }
        let locked = (try? db.unreadable()) ?? []
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
        let volumePath = Paths.onVolume(path)
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

    // MARK: Suggestions

    /// Known locations, project build output, and big folders nobody has
    /// touched in six months.
    func cleanup() -> [ScanResult] {
        guard let db else { return [] }
        let known: [ScanResult] = Catalog.targets.compactMap { target in
            let path = Paths.onVolume(target.path)
            guard let found = (try? db.locate(path))?.last, found.path == path, found.row.total > 0 else { return nil }
            return ScanResult(target: target, bytes: found.row.total, newest: found.row.newest)
        }
        let big = bigFolders(in: db, atLeast: 10 << 20)
        let artifacts = self.artifacts(in: db)
        let claimed = Set(known.map(\.target.path) + artifacts.map(\.target.path))
        return known + artifacts + stale(big, excluding: claimed)
    }

    func hotspots(limit: Int = 10) -> [Hotspot] {
        guard let db else { return [] }
        let big = bigFolders(in: db, atLeast: 1 << 30)
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
    private func bigFolders(in db: IndexDB, atLeast bytes: Int64) -> [(row: DirRow, path: String)] {
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

    private func artifacts(in db: IndexDB) -> [ScanResult] {
        let projects = Catalog.home + "/projects/"
        return scannedArtifacts(db).filter { $0.bytes >= 1 << 20 }.map { artifact in
            let name = artifact.path.hasPrefix(projects) ? String(artifact.path.dropFirst(projects.count))
                : artifact.path.replacingOccurrences(of: Catalog.home, with: "~")
            return ScanResult(
                target: Target(name: name, path: artifact.path, category: .artifacts, action: .remove),
                bytes: artifact.bytes, newest: artifact.projectNewest,
                kind: artifact.kind, projectNewest: artifact.projectNewest
            )
        }
    }

    /// Every confirmed build folder, any size: what auto-clean rules act on.
    func allArtifacts() -> [Artifact] {
        guard let db else { return [] }
        return scannedArtifacts(db)
    }

    private func stale(_ big: [(row: DirRow, path: String)], excluding claimed: Set<String>) -> [ScanResult] {
        let cutoff = Int64(Date.now.addingTimeInterval(-182 * 86_400).timeIntervalSince1970)
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
    private func outermost(_ entries: [(row: DirRow, path: String)]) -> [(row: DirRow, path: String)] {
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
