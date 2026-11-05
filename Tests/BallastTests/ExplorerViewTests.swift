import AppKit
import SwiftUI
import Testing
@testable import Ballast

// Explorer, Largest Files, Duplicates, the treemap and System Data: the
// pure helpers behind them, plus an opt-in snapshot board
// (`BALLAST_SNAPSHOTS=<folder> swift test --filter ExplorerSnapshots`).

private enum Fixture {
    static let now = Int64(Date.now.timeIntervalSince1970)
    static let day: Int64 = 86_400

    static func dir(_ id: Int64, _ name: String, _ total: Int64, parent: Int64? = 1, files: Int64 = 120,
                    err: Int32 = 0, newest: Int64 = now - 3 * day, own: Int64 = 0) -> DirRow {
        DirRow(id: id, parent: parent, name: name, own: own, ownFiles: 0, total: total, files: files, err: err,
               newest: newest)
    }

    static func file(_ id: Int64, _ path: String, _ bytes: Int64, modified: Int64 = now - 40 * day) -> LargeFile {
        LargeFile(id: id, dir: 1, name: (path as NSString).lastPathComponent, bytes: bytes, size: bytes,
                  modified: modified, inode: UInt64(id), path: path)
    }

    static let files: [LargeFile] = [
        file(1, "/Users/me/Movies/Trip.mov", 9_400_000_000),
        file(2, "/Users/me/Downloads/Xcode_26.xip", 7_100_000_000),
        file(3, "/Users/me/.orbstack/data/disk.img", 6_300_000_000),
        file(4, "/Users/me/Movies/Export final.mp4", 2_200_000_000, modified: now - 400 * day),
        file(5, "/Users/me/Documents/archive.zip", 880_000_000),
        file(6, "/Users/me/Music/Logic/Session.logicx/Audio.wav", 310_000_000),
    ]
}

@MainActor @Suite struct ExplorerContentTests {
    @Test func rowsAreSortedOnceWithTheirPaths() {
        let children = [Fixture.dir(3, "Small", 10), Fixture.dir(2, "Big", 900), Fixture.dir(4, "Mid", 300)]
        let rows = ExplorerContent.rows(children: children, files: [Fixture.files[0]],
                                        path: { "/Users/me/\($0.name)" },
                                        sortedBy: [KeyPathComparator(\ExplorerRow.total, order: .reverse)])
        #expect(rows.map(\.name) == ["Trip.mov", "Big", "Mid", "Small"])
        #expect(rows[1].path == "/Users/me/Big")
        #expect(rows[0].path == "/Users/me/Movies/Trip.mov")
        // Ids never collide between folders and files with the same number.
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(ExplorerContent.verdictRequests(rows).first { $0.path.hasSuffix(".mov") }?.isDirectory == false)
    }

    @Test func tilesFoldTheRestAndKeepRowIds() {
        let children = (0..<45).map { Fixture.dir(Int64(100 + $0), "F\($0)", Int64(1000 - $0)) }
        let rows = ExplorerContent.rows(children: children, files: [], path: { "/Users/me/\($0.name)" },
                                        sortedBy: [KeyPathComparator(\ExplorerRow.total, order: .reverse)])
        let current = Fixture.dir(1, "me", 100_000, parent: nil, own: 5_000)
        let tiles = ExplorerContent.tiles(rows: rows, current: current, isPlanned: { $0 == "/Users/me/F0" })
        #expect(tiles.filter { $0.kind == .folder }.count == ExplorerContent.maxTiles)
        #expect(tiles.contains { $0.kind == .rest && $0.bytes == (40..<45).reduce(0) { $0 + Int64(1000 - $1) } })
        #expect(tiles.contains { $0.kind == .files && $0.bytes == 5_000 })
        #expect(tiles.first { $0.name == "F0" }?.planned == true)
        #expect(tiles.first { $0.name == "F0" }?.id == rows.first { $0.name == "F0" }?.id)
        #expect(tiles == tiles.sorted { $0.bytes > $1.bytes })
    }

    @Test func systemFoldersAreLand() {
        #expect(ExplorerContent.isLand("/System"))
        #expect(ExplorerContent.isLand("/private/var/folders"))
        #expect(!ExplorerContent.isLand("/Users/me/System"))
        #expect(!ExplorerContent.isLand("/Library"))
        #expect(!ExplorerContent.isLand(nil))
    }

    @Test func treemapBandsFollowRelativeWeight() {
        func tile(_ bytes: Int64, locked: Bool = false, land: Bool = false, kind: TreemapTile.Kind = .folder) -> TreemapTile {
            TreemapTile(id: "\(bytes)", dirID: 1, name: "x", bytes: bytes, locked: locked, planned: false, kind: kind, land: land)
        }
        #expect(TreemapCanvas.band(for: TreemapCanvas.level(of: tile(1000), coloring: .size, largest: 1000)) == 4)
        #expect(TreemapCanvas.band(for: TreemapCanvas.level(of: tile(10), coloring: .size, largest: 1000)) == 0)
        #expect(TreemapCanvas.band(for: TreemapCanvas.level(of: tile(250), coloring: .size, largest: 1000)) == 2)
        #expect(TreemapCanvas.style(for: tile(5, locked: true), coloring: .size, largest: 10).outlined)
        #expect(TreemapCanvas.style(for: tile(5, kind: .rest), coloring: .size, largest: 10).outlined)
        #expect(!TreemapCanvas.style(for: tile(5, land: true), coloring: .size, largest: 10).outlined)
        let old = TreemapTile(id: "o", dirID: 1, name: "o", bytes: 1, locked: false, planned: false, kind: .folder,
                              newest: Fixture.now - 400 * Fixture.day)
        #expect(TreemapCanvas.band(for: TreemapCanvas.level(of: old, coloring: .age, largest: 10)) == 4)
    }

    @Test func layoutIsKeptWithItsTiles() {
        let tiles = [TreemapTile(id: "a", dirID: 1, name: "a", bytes: 3, locked: false, planned: false, kind: .folder),
                     TreemapTile(id: "b", dirID: 2, name: "b", bytes: 1, locked: false, planned: false, kind: .folder)]
        let layout = TreemapCanvas.Layout(tiles: tiles, size: CGSize(width: 400, height: 100))
        #expect(layout.rects.count == tiles.count)
        #expect(layout.largest == 3)
        #expect(layout.index(at: CGPoint(x: 10, y: 10)) == 0)
        #expect(layout.index(at: CGPoint(x: 390, y: 90)) == 1)
    }
}

@MainActor @Suite struct LargeFileFilterTests {
    @Test func filtersAndCountsKindsOnce() {
        let all = LargeFileFilter.apply(Fixture.files, kind: nil)
        #expect(all.shown.count == Fixture.files.count)
        #expect(all.bytes == Fixture.files.reduce(0) { $0 + $1.bytes })
        #expect(all.kinds.map(\.kind) == FileKind.allCases.filter { kind in Fixture.files.contains { $0.kind == kind } })
        let videos = LargeFileFilter.apply(Fixture.files, kind: .video)
        #expect(videos.shown.map(\.name) == ["Trip.mov", "Export final.mp4"])
        #expect(videos.kinds == all.kinds)
        #expect(LargeFileFilter.apply([], kind: nil) == .empty)
    }
}

@MainActor @Suite struct SystemDataSheetTests {
    static func report(onDisk: [SystemDataItem] = [], hidden: [SystemDataItem] = [], snapshots: [String] = []) -> SystemDataReport {
        SystemDataReport(onDisk: onDisk, hidden: hidden, snapshots: snapshots, purgeable: 0,
                         total: (onDisk + hidden).reduce(0) { $0 + $1.bytes })
    }

    @Test func everyLoadEndsInAFinishedState() {
        #expect(SystemDataPhase.after(report: nil, hasIndex: false) == .notScanned)
        #expect(SystemDataPhase.after(report: Self.report(), hasIndex: false) == .notScanned)
        #expect(SystemDataPhase.after(report: nil, hasIndex: true) == .timedOut)
        #expect(SystemDataPhase.after(report: Self.report(), hasIndex: true) == .empty)
        let item = SystemDataItem(name: "System logs", detail: "", bytes: 1, action: .none)
        #expect(SystemDataPhase.after(report: Self.report(onDisk: [item]), hasIndex: true) == .loaded)
        #expect(SystemDataPhase.after(report: Self.report(snapshots: ["com.apple.TimeMachine.x"]), hasIndex: true) == .loaded)
    }

    @Test func adviceAddsToTheDescription() {
        for area in SystemDataCatalog.areas {
            let item = SystemDataItem(name: area.name, detail: area.detail, bytes: 1, action: .explore(area.path))
            #expect(SystemDataAdvice.path(of: item) == area.path)
            if let advice = SystemDataAdvice.advice(for: item) {
                #expect(!area.detail.contains(advice), "\(area.name) repeats its description")
            }
        }
        for name in ["Shared app data", "Other users & Shared", "Other system files", "Staged updates"] {
            #expect(SystemDataAdvice.advice(for: SystemDataItem(name: name, detail: "", bytes: 1, action: .none)) != nil)
        }
        let admin = SystemDataItem(name: "Not measured", detail: "", bytes: 1, action: .adminScan)
        let none = SystemDataItem(name: "Not measured", detail: "", bytes: 1, action: .none)
        #expect(SystemDataAdvice.advice(for: admin) != SystemDataAdvice.advice(for: none))
        #expect(SystemDataAdvice.path(of: SystemDataItem(name: "x", detail: "", bytes: 1, action: .explore("/"))) == nil)
    }
}

@MainActor @Suite struct DuplicatesSectionTests {
    @Test func notesNameWhatWasLeftOut() {
        let empty = DuplicateReport(groups: [], cloned: [], hardLinks: 0, protectedFiles: 0, checked: 10)
        #expect(DuplicatesSection.notes(empty).isEmpty)
        let some = DuplicateReport(groups: [], cloned: [], hardLinks: 2, protectedFiles: 1, checked: 10)
        let notes = DuplicatesSection.notes(some)
        #expect(notes.count == 2)
        #expect(Set(notes).count == notes.count)
    }
}

// MARK: Snapshots

@MainActor @Suite struct ExplorerSnapshots {
    nonisolated static let folder = ProcessInfo.processInfo.environment["BALLAST_SNAPSHOTS"]

    private static let crumbs = [Crumb(id: 1, name: "Macintosh HD"), Crumb(id: 2, name: "Users"), Crumb(id: 3, name: "me"),
                                 Crumb(id: 4, name: "projects"), Crumb(id: 5, name: "client-work-2026"),
                                 Crumb(id: 6, name: "ballast-monorepo"), Crumb(id: 7, name: "node_modules")]

    private static func header(width: CGFloat, compact: Bool) -> some View {
        ExplorerHeader(crumbs: crumbs, total: 84_300_000_000, unseen: nil,
                       showsMap: .constant(true), showsFiles: .constant(false), coloring: .constant(.size),
                       filesAvailable: true, compact: compact, open: { _ in }, reveal: {})
            .frame(width: width)
    }

    private static var rows: [ExplorerRow] {
        let children = [
            Fixture.dir(10, "Library", 48_000_000_000, files: 412_000),
            Fixture.dir(11, "Developer", 21_500_000_000, files: 180_330, newest: Fixture.now - 300 * Fixture.day),
            Fixture.dir(12, "Movies", 9_800_000_000, files: 42),
            Fixture.dir(13, "Music", 2_100_000_000, files: 3_120),
            Fixture.dir(14, "Private", 0, files: 0, err: 13),
        ]
        return ExplorerContent.rows(children: children, files: [Fixture.files[0]], path: { "/Users/me/\($0.name)" },
                                    sortedBy: [KeyPathComparator(\ExplorerRow.total, order: .reverse)])
    }

    private static var tiles: [TreemapTile] {
        let root = [
            Fixture.dir(20, "Users", 210_000_000_000), Fixture.dir(21, "Applications", 38_000_000_000),
            Fixture.dir(22, "System", 26_000_000_000), Fixture.dir(23, "Library", 18_000_000_000),
            Fixture.dir(24, "private", 12_000_000_000), Fixture.dir(25, "opt", 6_000_000_000, newest: Fixture.now - 500 * Fixture.day),
            Fixture.dir(26, "usr", 2_000_000_000), Fixture.dir(27, "Locked", 1_500_000_000, err: 13),
            Fixture.dir(28, "cores", 300_000_000),
        ]
        let rows = ExplorerContent.rows(children: root, files: [], path: { "/\($0.name)" },
                                        sortedBy: [KeyPathComparator(\ExplorerRow.total, order: .reverse)])
        return ExplorerContent.tiles(rows: rows, current: Fixture.dir(1, "/", 320_000_000_000, parent: nil, own: 900_000_000),
                                     isPlanned: { $0 == "/opt" })
    }

    private static var board: some View {
        let rows = Self.rows
        let largest = rows.map(\.total).max() ?? 1
        return VStack(alignment: .leading, spacing: 24) {
            header(width: 880, compact: false)
            header(width: 520, compact: true)
            TreemapCanvas(tiles: tiles, coloring: .size, selectedID: "d21", initialSize: CGSize(width: 840, height: 240)) { _ in }
                .frame(width: 840, height: 240)
            TreemapCanvas(tiles: tiles, coloring: .age, initialSize: CGSize(width: 840, height: 160)) { _ in }
                .frame(width: 840, height: 160)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 12) {
                        ExplorerNameCell(row: row).frame(width: 260, alignment: .leading)
                        ExplorerItemsCell(row: row).frame(width: 70)
                        AgeText(newest: row.newest, muted: row.isLocked).frame(width: 90, alignment: .leading)
                        ExplorerSizeCell(row: row, parentTotal: 84_300_000_000, largest: largest).frame(width: 220)
                    }
                    .padding(.vertical, 6)
                    RowHairline()
                }
            }
            .padding(.horizontal, 16)
            .chartSurface()
            SkeletonRows(count: 3).padding(.horizontal, 16).chartSurface()
        }
        .padding(28)
        .frame(width: 900)
        .background(Theme.water)
    }

    private static var filesBoard: some View {
        let kinds = LargeFileFilter.apply(Fixture.files, kind: nil).kinds
        let largest = Fixture.files[0].bytes
        let safety: [Safety?] = [.safe("Safe"), .caution("Check first"), nil, .blocked("Protected"), .safe("Safe"), .safe("Safe")]
        let dupe = DuplicateGroup(copies: [
            DuplicateCopy(path: "/Users/me/Movies/Trip.mov", bytes: 9_400_000_000, modified: Fixture.now - 90 * Fixture.day, sharing: nil),
            DuplicateCopy(path: "/Users/me/Downloads/Trip.mov", bytes: 9_400_000_000, modified: Fixture.now - 2 * Fixture.day, sharing: nil),
            DuplicateCopy(path: "/Users/me/Desktop/Trip copy.mov", bytes: 9_400_000_000, modified: Fixture.now - 1 * Fixture.day, sharing: nil),
        ], size: 9_400_000_000, hash: "abc")
        return VStack(alignment: .leading, spacing: 28) {
            ChartSection(title: "Largest files", note: LargeFileText.caption(locked: 3), total: 26_190_000_000, padded: false) {
                KindFilterBar(kinds: kinds, selection: .constant(.video))
            } content: {
                VStack(spacing: 0) {
                    ForEach(Array(Fixture.files.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { RowHairline(leading: 66) }
                        LargeFileRow(file: file, location: (file.path as NSString).deletingLastPathComponent
                                        .replacingOccurrences(of: "/Users/me", with: "~"),
                                     largest: largest, safety: safety[index], isPlanned: index == 1)
                    }
                }
                .padding(.vertical, 4)
            }
            ChartSection(title: "Duplicate files", note: "Copies of the same file, 50 MB or more.", total: 18_800_000_000, padded: false) {
                VStack(alignment: .leading, spacing: 0) {
                    DuplicatesProgress(progress: DuplicateProgress(stage: .hashing, files: 3, totalFiles: 12,
                                                                   bytes: 4_000_000_000, totalBytes: 10_000_000_000)) {}
                        .padding(.vertical, 8)
                    RowHairline()
                    DuplicateGroupRow(group: dupe, kept: dupe.suggestedKeep,
                                      safety: ["/Users/me/Desktop/Trip copy.mov": .caution("Check before cleaning: on the Desktop.")],
                                      planned: ["/Users/me/Downloads/Trip.mov"],
                                      location: { ($0 as NSString).deletingLastPathComponent.replacingOccurrences(of: "/Users/me", with: "~") },
                                      expanded: true, keep: { _ in }, addOthers: {}, showInExplorer: { _ in })
                    RowHairline()
                    DuplicatesStart(fileCount: 512, volume: "Macintosh HD", failure: "Couldn't finish: The file couldn't be read.") {}
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(28)
        .frame(width: 860)
        .background(Theme.water)
    }

    private static var systemBoard: some View {
        let onDisk = [
            SystemDataItem(name: "Shared app data", detail: SystemDataCatalog.areas[3].detail, bytes: 31_000_000_000, action: .explore("/Library")),
            SystemDataItem(name: "Temporary files & system caches", detail: SystemDataCatalog.areas[0].detail, bytes: 9_200_000_000,
                           action: .explore("/private/var/folders")),
            SystemDataItem(name: "Not measured", detail: "Space Ballast couldn't look inside: 12 locked folders, plus file-system overhead.",
                           bytes: 4_100_000_000, action: .adminScan),
        ]
        let hidden = ["VM", "Preboot", "System"].map {
            SystemDataCatalog.volume(SystemVolumes.Volume(name: $0, role: $0, bytes: $0 == "System" ? 12_000_000_000 : 6_000_000_000))
        }
        let total = (onDisk + hidden).reduce(0) { $0 + $1.bytes }
        return VStack(alignment: .leading, spacing: 24) {
            SystemDataHeader(total: total)
            VStack(alignment: .leading, spacing: 24) {
                FullDiskAccessCallout()
                SystemDataGroup(title: "On your data volume", note: "Folders Ballast measured outside your home folder and Applications.",
                                items: onDisk, total: total, isBusy: true) { _ in }
                SystemDataGroup(title: "Hidden macOS volumes", note: "Separate volumes macOS keeps next to your data.",
                                items: hidden, total: total) { _ in }
            }
            .padding(.horizontal, 24)
            EmptyChart(symbol: "exclamationmark.circle", title: "The disk layout didn't arrive",
                       message: "macOS didn't report its volume sizes in time, usually because the disk is busy. Try again in a moment.") {
                Button("Try Again") {}
            }
        }
        .padding(.bottom, 24)
        .frame(width: 640)
        .background(Theme.water)
    }

    @Test(.enabled(if: folder != nil)) func renderExplorer() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            try ComponentSnapshots.render(Self.board, name: "explorer-\(suffix)", appearance: appearance)
            try ComponentSnapshots.render(Self.filesBoard, name: "explorer-files-\(suffix)", appearance: appearance)
            try ComponentSnapshots.render(Self.systemBoard, name: "explorer-systemdata-\(suffix)", appearance: appearance)
        }
    }
}
