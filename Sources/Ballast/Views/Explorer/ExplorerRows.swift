import Foundation

/// A row in Explorer's list: a folder, or a large file shown among them.
/// Built once per folder change with its display path, never in a body.
struct ExplorerRow: Identifiable, Hashable {
    enum Item: Hashable {
        case folder(DirRow)
        case file(LargeFile)
    }

    let item: Item
    /// Display path; nil when the row isn't under the open folder's trail.
    let path: String?

    /// Stable and unique: folder and file ids come from different tables.
    var id: String {
        switch item {
        case .folder(let row): "d\(row.id)"
        case .file(let file): "f\(file.id)"
        }
    }

    var folder: DirRow? { if case .folder(let row) = item { row } else { nil } }
    var file: LargeFile? { if case .file(let file) = item { file } else { nil } }

    var name: String { folder?.name ?? file?.name ?? "" }
    var total: Int64 { folder?.total ?? file?.bytes ?? 0 }
    var newest: Int64 { folder?.newest ?? file?.modified ?? 0 }
    /// Files inside a folder; 0 for a file row.
    var items: Int64 { folder?.files ?? 0 }
    var isLocked: Bool { (folder?.err ?? 0) != 0 }
}

/// Explorer's rows and map tiles, worked out from the open folder.
enum ExplorerContent {
    static let maxTiles = 40

    /// macOS's own top-level folders on the data volume: nothing in them
    /// can be moved, so the map draws them as land.
    static let landRoots = ["/System", "/private", "/usr", "/bin", "/sbin", "/cores", "/dev"]

    static func isLand(_ path: String?) -> Bool {
        guard let path else { return false }
        return landRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Folders, then the open folder's large files when they're shown,
    /// sorted the way the list is.
    static func rows(children: [DirRow], files: [LargeFile], path: (DirRow) -> String?,
                     sortedBy order: [KeyPathComparator<ExplorerRow>]) -> [ExplorerRow] {
        let rows = children.map { ExplorerRow(item: .folder($0), path: path($0)) }
            + files.map { ExplorerRow(item: .file($0), path: $0.path) }
        return rows.sorted(using: order)
    }

    /// The map: the largest folders, the rest folded into one tile, the
    /// shown large files, and the folder's other loose files.
    static func tiles(rows: [ExplorerRow], current: DirRow?, isPlanned: (String) -> Bool) -> [TreemapTile] {
        let folders = rows.compactMap { row in row.folder.map { (row, $0) } }
            .filter { $0.1.total > 0 }
            .sorted { $0.1.total > $1.1.total }
        let shown = folders.prefix(maxTiles)
        var tiles = shown.map { row, folder in
            TreemapTile(id: row.id, dirID: folder.id, name: folder.name, bytes: folder.total, locked: folder.err != 0,
                        planned: row.path.map(isPlanned) ?? false, kind: .folder, newest: folder.newest,
                        land: isLand(row.path))
        }
        let rest = folders.dropFirst(shown.count).reduce(0) { $0 + $1.1.total }
        if rest > 0 {
            tiles.append(TreemapTile(id: "rest", dirID: nil, name: "Other folders", bytes: rest,
                                     locked: false, planned: false, kind: .rest))
        }
        let files = rows.compactMap(\.file)
        for file in files where file.bytes > 0 {
            tiles.append(TreemapTile(id: "f\(file.id)", dirID: nil, name: file.name, bytes: file.bytes, locked: false,
                                     planned: isPlanned(file.path), kind: .file, newest: file.modified,
                                     filePath: file.path))
        }
        if let current {
            let loose = current.own - files.reduce(0) { $0 + $1.bytes }
            if loose > 0 {
                tiles.append(TreemapTile(id: "files", dirID: nil, name: files.isEmpty ? "Files" : "Other files",
                                         bytes: loose, locked: false, planned: false, kind: .files))
            }
        }
        return tiles.sorted { $0.bytes > $1.bytes }
    }

    /// Verdict requests for every row that has a path.
    static func verdictRequests(_ rows: [ExplorerRow]) -> [VerdictRequest] {
        rows.compactMap { row in row.path.map { VerdictRequest(path: $0, isDirectory: row.folder != nil) } }
    }
}

/// One step of the breadcrumb trail.
struct Crumb: Identifiable, Hashable {
    let id: Int64
    let name: String
}
