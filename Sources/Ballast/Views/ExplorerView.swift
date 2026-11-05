import SwiftUI

struct ExplorerView: View {
    let model: AppModel
    @State private var selection: ExplorerRow.ID?
    @State private var sortOrder = [KeyPathComparator(\ExplorerRow.total, order: .reverse)]
    @AppStorage("explorerColoring") private var coloring: TreemapColoring = .size
    /// Large files listed among the folders, in the table and the map.
    @AppStorage("explorerShowsFiles") private var showsFiles = false
    /// The height the divider was dragged to; the map gets less when the
    /// window is too short to fit it above the table.
    @State private var mapHeight: CGFloat = 320
    @State private var shownMapHeight: CGFloat = 320
    @State private var dragStartHeight: CGFloat?
    @AppStorage("explorerShowsMap") private var showsMap = true

    // Search
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searchedFor = ""
    @State private var hitSelection: SearchHit.ID?
    @State private var explainingHit: SearchHit.ID?
    @FocusState private var searchFocused: Bool

    // The open folder, worked out when it changes rather than in body.
    @State private var rows: [ExplorerRow] = []
    @State private var rowsByID: [ExplorerRow.ID: ExplorerRow] = [:]
    @State private var tiles: [TreemapTile] = []
    /// The heaviest row, for share-bar depth.
    @State private var largest: Int64 = 1
    /// Verdicts for the rows, by display path, assessed off the main thread.
    @State private var verdicts: [String: Safety] = [:]
    @State private var verdictRequests: [VerdictRequest] = []

    /// A folder this screen asked to open that hasn't arrived yet.
    @State private var pendingOpen: Int64?
    /// The skeleton waits a moment: most folders open faster than that.
    @State private var showsSkeleton = false
    /// The last open didn't arrive in time.
    @State private var openFailed = false
    /// The row whose "What is this?" popover is open.
    @State private var explaining: ExplorerRow.ID?
    /// Counts "Try Again" presses, so each one waits for the root afresh.
    @State private var rootAttempt = 0

    private static let minMapHeight: CGFloat = 200
    /// How long a folder may take to open before Ballast says so.
    private static let openTimeout: Duration = .seconds(6)

    private var isSearching: Bool { SearchQuery.pattern(for: query) != nil }

    var body: some View {
        Group {
            if model.activeOverview == nil, let disk = model.selectedDiskInfo {
                // Another drive, before its first scan.
                EmptyChart(symbol: disk.isRemovable ? "externaldrive" : "internaldrive",
                           title: "\(disk.name) hasn't been scanned",
                           message: disk.isConnected
                               ? "Ballast scans other drives only when you ask. A scan maps every folder on it."
                               : "Connect \(disk.name) to scan it.") {
                    Button("Scan \(disk.name)") { Task { await model.scanDisk(disk.uuid, full: true) } }
                        .buttonStyle(.ink)
                        .disabled(model.isBusyWithUserWork || !disk.isConnected)
                }
                .frame(maxHeight: .infinity)
            } else if isSearching {
                results
            } else {
                browser
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Folders")
        .searchFocused($searchFocused)
        // Debounced, and run on the index reader, off the main thread.
        .task(id: query) {
            guard isSearching else {
                hits = []
                searchedFor = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let found = await model.search(query)
            guard !Task.isCancelled else { return }
            hits = found
            searchedFor = query
            hitSelection = nil
        }
        .onAppear {
            model.isExplorerShown = true
            model.openRootIfIdle()
            rebuild()
            focusSearchIfRequested()
        }
        .onDisappear { model.isExplorerShown = false }
        .onChange(of: model.searchRequested) { focusSearchIfRequested() }
        .onChange(of: model.children) { arrived() }
        .onChange(of: model.trail) { arrived() }
        .onChange(of: model.folderFiles) { rebuild() }
        .onChange(of: showsFiles) { rebuild() }
        .onChange(of: sortOrder) { rebuild() }
        .onChange(of: model.plannedPaths) { rebuildTiles() }
        .task(id: VerdictKey(rows: verdictRequests, protected: model.preferences.protectedFolders)) {
            // Keep what's known for rows still here (a refresh of the same
            // folder doesn't blink), drop the rest, then assess in the
            // order the list shows, a chunk at a time.
            let wanted = Set(verdictRequests.map(\.path))
            verdicts = verdicts.filter { wanted.contains($0.key) }
            let ordered = rows.compactMap { row in
                row.path.map { VerdictRequest(path: $0, isDirectory: row.folder != nil) }
            }
            await model.verdicts(for: ordered) { found in verdicts.merge(found) { _, new in new } }
        }
        .task(id: pendingOpen) {
            guard pendingOpen != nil else { return }
            guard (try? await Task.sleep(for: .milliseconds(180))) != nil else { return }
            Motion.with(Motion.state) { showsSkeleton = true }
            guard (try? await Task.sleep(for: Self.openTimeout)) != nil else { return }
            // The index didn't answer: stop waiting and say so.
            pendingOpen = nil
            showsSkeleton = false
            openFailed = true
        }
        // The disk root is opened by the model, not through `open(_:)`:
        // it gets the same deadline, so the skeleton always ends.
        .task(id: "\(waitingForRoot)-\(rootAttempt)") {
            guard waitingForRoot else { return }
            guard (try? await Task.sleep(for: Self.openTimeout)) != nil, waitingForRoot else { return }
            openFailed = true
        }
    }

    private var waitingForRoot: Bool { model.trail.isEmpty && model.activeOverview != nil }

    /// ⌘F from anywhere lands here.
    private func focusSearchIfRequested() {
        guard model.searchRequested else { return }
        model.searchRequested = false
        Task { searchFocused = true }
    }

    // MARK: Content

    private func open(_ id: Int64) {
        selection = nil
        explaining = nil
        openFailed = false
        guard id != model.trail.last?.id else { return }
        pendingOpen = id
        model.open(id)
    }

    /// A folder arrived (this screen's request or anyone's).
    private func arrived() {
        if pendingOpen == nil || pendingOpen == model.trail.last?.id {
            pendingOpen = nil
            showsSkeleton = false
        }
        if !model.trail.isEmpty { openFailed = false }
        rebuild()
    }

    private func rebuild() {
        let files = showsFiles ? model.folderFiles ?? [] : []
        rows = ExplorerContent.rows(children: model.children, files: files, path: model.displayPath(of:),
                                    sortedBy: sortOrder)
        rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        largest = max(rows.map(\.total).max() ?? 1, 1)
        let requests = ExplorerContent.verdictRequests(rows)
        if requests != verdictRequests { verdictRequests = requests }
        if let selection, rowsByID[selection] == nil { self.selection = nil }
        rebuildTiles()
    }

    private func rebuildTiles() {
        let planned = model.plannedPaths
        tiles = ExplorerContent.tiles(rows: rows, current: model.trail.last, isPlanned: planned.contains)
    }

    /// The open folder hasn't arrived yet: the first load, or a slow one.
    private var isLoading: Bool {
        (waitingForRoot && !openFailed) || (pendingOpen != nil && showsSkeleton)
    }

    private var browser: some View {
        VStack(spacing: 0) {
            ExplorerHeader(
                crumbs: crumbs,
                total: model.trail.last?.total,
                unseen: unseenBytes,
                showsMap: $showsMap, showsFiles: $showsFiles, coloring: $coloring,
                filesAvailable: model.folderFiles != nil,
                open: open, reveal: revealSelectionOrFolder)
            if openFailed, !model.trail.isEmpty {
                SectionNote(symbol: "exclamationmark.circle",
                            text: "That folder didn't open. The index may be busy with an update; try again in a moment.")
                    .font(.callout)
                    .padding(.horizontal, 20)
                    .transition(.opacity)
            }
            // Not a VSplitView: that's an AppKit split view whose panes carry
            // the sidebar and inspector insets into their minimum widths,
            // which crashed narrow windows with the Cleanup List open.
            if showsMap, !(model.trail.isEmpty && !isLoading) {
                map
                    .frame(minHeight: Self.minMapHeight, maxHeight: mapHeight)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownMapHeight = $0 }
                    // The map keeps its height and the list gives way first,
                    // as with a split view.
                    .layoutPriority(1)
                ResizeDivider { translation in
                    let start = dragStartHeight ?? shownMapHeight
                    dragStartHeight = start
                    mapHeight = max(start + translation, Self.minMapHeight)
                } ended: {
                    dragStartHeight = nil
                }
            }
            list
                .frame(minHeight: 180, maxHeight: .infinity)
            if let selected = selection.flatMap({ rowsByID[$0] }) {
                selectionCallout(selected)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)),
                                            removal: .opacity.animation(Motion.animation(Motion.exit))))
            }
        }
        .animation(Motion.animation(Motion.state), value: selection == nil)
        .animation(Motion.animation(Motion.state), value: openFailed)
    }

    private var crumbs: [Crumb] {
        model.trail.enumerated().map { index, row in
            Crumb(id: row.id, name: index == 0 ? model.activeDiskName : row.name)
        }
    }

    /// The walk sees folders only; the rest of "used" is the sealed system
    /// volume, snapshots and purgeable space.
    private var unseenBytes: Int64? {
        guard model.trail.count == 1, model.selectedDisk == .startup, let root = model.trail.first,
              model.usedBytes > root.total else { return nil }
        return model.usedBytes - root.total
    }

    private func revealSelectionOrFolder() {
        if let path = selection.flatMap({ rowsByID[$0] })?.path {
            Finder.reveal(path)
        } else if let current = model.trail.last {
            Task { if let path = await model.path(of: current.id) { Finder.reveal(path) } }
        }
    }

    // MARK: Map

    @ViewBuilder
    private var map: some View {
        Group {
            if tiles.isEmpty, isLoading {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.depth[0])
                    .loadingShimmer(true)
                    .accessibilityLabel("Loading map")
            } else {
                TreemapCanvas(tiles: tiles, coloring: coloring, selectedID: selection) { tile in
                    if let id = tile.dirID {
                        open(id)
                    } else if let path = tile.filePath {
                        QuickLook.toggle(path)
                    }
                }
                .opacity(pendingOpen != nil && showsSkeleton ? 0.45 : 1)
                .animation(Motion.animation(Motion.state), value: showsSkeleton)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        Group {
            if isLoading {
                ScrollView {
                    SkeletonRows(count: 8)
                        .padding(.horizontal, Theme.Space.inset)
                }
                .scrollDisabled(true)
                .chartSurface()
                .transition(.opacity)
            } else if model.trail.isEmpty {
                EmptyChart(symbol: model.activeOverview == nil ? "internaldrive" : "exclamationmark.circle",
                           title: model.activeOverview == nil ? "This Mac hasn't been scanned" : "Couldn't open the disk",
                           message: model.activeOverview == nil
                               ? "Scan this Mac from the Overview first; Explorer shows what the scan measured."
                               : "The index didn't answer in time, usually because an update is writing to it.") {
                    if model.activeOverview != nil {
                        Button("Try Again") {
                            openFailed = false
                            rootAttempt += 1
                            // A fresh request, so it supersedes one that
                            // never answered (`openRootIfIdle` would wait on it).
                            if let root = model.activeOverview?.root { open(root.id) } else { model.openRootIfIdle() }
                        }
                        .buttonStyle(.glass)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                emptyFolder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
                    .chartSurface()
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .animation(Motion.animation(Motion.state), value: isLoading)
    }

    private var emptyFolder: some View {
        let current = model.trail.last
        let hiddenFiles = !showsFiles && !(model.folderFiles ?? []).isEmpty
        let own = current?.own ?? 0
        return EmptyChart(
            symbol: "folder",
            title: own > 0 ? "No folders inside" : "This folder is empty",
            message: hiddenFiles
                ? "Its \(own.bytes) are files, including some of \(LargeFileText.threshold) or more. Show them to see which."
                : own > 0 ? "Its \(own.bytes) are files that each take less than \(LargeFileText.threshold). Finder lists them one by one."
                : "Nothing here takes space.") {
            if hiddenFiles {
                Button("Show Large Files") { showsFiles = true }
                    .buttonStyle(.glass)
            } else if own > 0 {
                Button("Show in Finder", action: revealSelectionOrFolder)
                    .buttonStyle(.glass)
            }
        }
    }

    private var table: some View {
        let parentTotal = max(model.trail.last?.total ?? 1, 1)
        return Table(of: ExplorerRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                ExplorerNameCell(row: row)
            }
            .width(min: 140, ideal: 320)

            TableColumn("Items", value: \.items) { row in
                ExplorerItemsCell(row: row)
            }
            .width(min: 52, ideal: 72)
            .alignment(.trailing)

            TableColumn("Last Changed", value: \.newest) { row in
                AgeText(newest: row.newest, muted: !isActionable(row))
            }
            .width(min: 72, ideal: 104)

            TableColumn("Size", value: \.total) { row in
                ExplorerSizeCell(row: row, parentTotal: parentTotal, largest: largest)
            }
            .width(min: 120, ideal: 210)

            TableColumn("") { row in
                actions(row)
            }
            .width(52)
        } rows: {
            ForEach(rows) { row in
                if let path = row.path {
                    TableRow(row).draggable(URL(fileURLWithPath: path))
                } else {
                    TableRow(row)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: ExplorerRow.ID.self) { ids in
            if let row = ids.first.flatMap({ rowsByID[$0] }) { menu(for: row, selected: ids) }
        } primaryAction: { ids in
            // Folders open; files, which have nothing inside to show, preview.
            if let row = ids.first.flatMap({ rowsByID[$0] }) {
                if let folder = row.folder { open(folder.id) } else if let file = row.file { QuickLook.toggle(file.path) }
            }
        }
        // Space previews the selected row, as in Finder.
        .onKeyPress(.space) {
            guard let path = selection.flatMap({ rowsByID[$0] })?.path else { return .ignored }
            QuickLook.toggle(path)
            return .handled
        }
    }

    private func verdict(_ row: ExplorerRow) -> Safety? {
        row.path.flatMap { verdicts[$0] }
    }

    private func isActionable(_ row: ExplorerRow) -> Bool {
        !row.isLocked && row.total > 0 && verdict(row)?.level != .blocked
    }

    /// What the list toggle shows, from the off-main verdict.
    private func displayItem(_ row: ExplorerRow) -> PlanItem? {
        guard let path = row.path, let safety = verdict(row) else { return nil }
        return PlanItem(name: row.name, path: path, bytes: row.total, action: .remove, isDirectory: row.folder != nil,
                        safety: safety, included: safety.level == .safe)
    }

    /// The model's own item for a row, assessed when someone acts on it.
    private func listItem(_ row: ExplorerRow) -> PlanItem? {
        if let folder = row.folder { return model.listItem(for: folder) }
        return row.file.map(model.listItem(for:))
    }

    private func toggle(_ row: ExplorerRow) {
        guard let item = listItem(row) else { return }
        Motion.with(Motion.feedback) { model.toggle(item) }
    }

    /// "What is this?" (shown on the selected row, or while its popover is
    /// open) and the list toggle.
    private func actions(_ row: ExplorerRow) -> some View {
        HStack(spacing: 6) {
            if let path = row.path {
                let shown = selection == row.id || explaining == row.id
                InfoPopoverButton(path: path, level: verdict(row)?.level, isShown: Binding(
                    get: { explaining == row.id },
                    set: { explaining = $0 ? row.id : (explaining == row.id ? nil : explaining) }))
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
                    .animation(Motion.animation(Motion.feedback), value: shown)
            }
            let item = displayItem(row)
            ListToggle(item: item, isOn: row.path.map(model.isPlanned) ?? false) { toggle(row) }
        }
    }

    @ViewBuilder
    private func menu(for row: ExplorerRow, selected ids: Set<ExplorerRow.ID>) -> some View {
        if let folder = row.folder {
            Button("Open") { open(folder.id) }
        }
        if row.path != nil {
            Button("Quick Look") { if let path = row.path { QuickLook.toggle(path) } }
        }
        if let safety = verdict(row), safety.level == .blocked {
            Text("Protected: \(safety.reason)")
        } else if let path = row.path {
            Button(model.isPlanned(path) ? "Remove from Cleanup List" : "Add to Cleanup List") { toggle(row) }
        }
        if row.path != nil {
            Button("What Is This?") {
                selection = row.id
                explaining = row.id
            }
        }
        Divider()
        Button("Show in Finder") {
            if let file = row.file {
                Finder.reveal(file.path)
            } else if let folder = row.folder {
                Task { if let path = await model.path(of: folder.id) { Finder.reveal(path) } }
            }
        }
        Divider()
        Button("Copy Path") {
            if let file = row.file {
                Finder.copy(file.path)
            } else if let folder = row.folder {
                Task { if let path = await model.path(of: folder.id) { Finder.copy(path) } }
            }
        }
        if row.folder != nil {
            Button("Copy as CSV") { Finder.copy(csv(ids)) }
        }
    }

    /// The chosen folders with a header line, ready to paste into a spreadsheet.
    private func csv(_ ids: Set<ExplorerRow.ID>) -> String {
        let whole = model.trail.last?.total ?? 0
        let chosen = rows.filter { ids.contains($0.id) }
        return CSV.document(chosen.compactMap { row in
            guard let folder = row.folder, let path = row.path else { return nil }
            return ExportRow(path: path, row: folder, of: whole)
        })
    }

    // MARK: Selection

    /// The selected row on a glass callout: where it is, its verdict, and
    /// the screen's one ink action, adding it to the Cleanup List.
    private func selectionCallout(_ row: ExplorerRow) -> some View {
        let safety = verdict(row)
        let isPlanned = row.path.map(model.isPlanned) ?? false
        return HStack(alignment: .center, spacing: 12) {
            if let safety {
                SafetyMark(level: safety.level)
                    .font(.title3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.path ?? row.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(safety?.reason ?? (row.isLocked ? "Ballast couldn't read this folder. Overview › Scan as Admin can measure it." : "Checking…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let folder = row.folder {
                Button("Open") { open(folder.id) }
                    .buttonStyle(.glass)
            } else if let path = row.path {
                Button("Quick Look") { QuickLook.toggle(path) }
                    .buttonStyle(.glass)
            }
            if let safety, safety.level != .blocked {
                if isPlanned {
                    Button("Remove from List") { toggle(row) }
                        .buttonStyle(.glass)
                } else {
                    Button("Add to Cleanup List") { toggle(row) }
                        .buttonStyle(.ink)
                }
            }
        }
        .padding(.horizontal, Theme.Space.inset)
        .padding(.vertical, 12)
        .chartGlass(radius: Theme.Radius.card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected: \(row.name)")
    }

    // MARK: Search results

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(summary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Group {
                if searchedFor != query && hits.isEmpty {
                    ScrollView {
                        SkeletonRows(count: 6)
                            .padding(.horizontal, Theme.Space.inset)
                    }
                    .scrollDisabled(true)
                    .chartSurface()
                } else if hits.isEmpty {
                    EmptyChart(symbol: "magnifyingglass",
                               title: "No folders match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”",
                               message: "Search looks at folder names across the whole disk. Try part of the name, or clear the search to browse.") {
                        Button("Clear Search") { query = "" }
                            .buttonStyle(.glass)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    hitsTable
                        .chartSurface()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private var hitsTable: some View {
        Table(hits, selection: $hitSelection) {
            TableColumn("Name") { hit in
                Label {
                    Text(hit.row.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: hit.row.err != 0 ? "lock.fill" : "folder.fill")
                        .foregroundStyle(hit.row.err != 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.sea))
                        .frame(width: 18)
                }
            }
            .width(min: 120, ideal: 220)

            TableColumn("Location") { hit in
                Text(model.location(of: hit.path))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(hit.path)
            }
            .width(min: 100, ideal: 280)

            TableColumn("Last Changed") { hit in
                AgeText(newest: hit.row.newest, muted: hit.row.err != 0)
            }
            .width(min: 72, ideal: 104)

            TableColumn("Size") { hit in
                Group {
                    if hit.row.err != 0 {
                        Text("Locked").foregroundStyle(.secondary)
                    } else {
                        Sounding(bytes: hit.row.total)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 72, ideal: 96)

            TableColumn("") { hit in
                InfoPopoverButton(path: hit.path, isShown: Binding(
                    get: { explainingHit == hit.id },
                    set: { explainingHit = $0 ? hit.id : (explainingHit == hit.id ? nil : explainingHit) }))
                    .opacity(hitSelection == hit.id || explainingHit == hit.id ? 1 : 0)
                    .allowsHitTesting(hitSelection == hit.id || explainingHit == hit.id)
                    .accessibilityHidden(hitSelection != hit.id && explainingHit != hit.id)
            }
            .width(24)
        }
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: SearchHit.ID.self) { ids in
            if let hit = ids.first.flatMap({ id in hits.first { $0.id == id } }) {
                Button("Show in Explorer") { show(hit) }
                Button("Show in Finder") { Finder.reveal(hit.path) }
                Button("Quick Look") { QuickLook.toggle(hit.path) }
                Button("What Is This?") {
                    hitSelection = hit.id
                    explainingHit = hit.id
                }
                Divider()
                Button("Copy Path") { Finder.copy(hit.path) }
            }
        } primaryAction: { ids in
            if let hit = ids.first.flatMap({ id in hits.first { $0.id == id } }) { show(hit) }
        }
        .onKeyPress(.space) {
            guard let hit = hitSelection.flatMap({ id in hits.first { $0.id == id } }) else { return .ignored }
            QuickLook.toggle(hit.path)
            return .handled
        }
        .onExitCommand { query = "" }
    }

    private var summary: String {
        guard searchedFor == query else { return "Searching…" }
        let quoted = "“\(query.trimmingCharacters(in: .whitespacesAndNewlines))”"
        if hits.count >= 200 { return "The 200 largest folders matching \(quoted)" }
        return "\(hits.count) folder\(hits.count == 1 ? "" : "s") matching \(quoted), largest first"
    }

    /// Leaves search and opens the folder, like drilling in from the table.
    private func show(_ hit: SearchHit) {
        query = ""
        open(hit.row.id)
    }
}

// MARK: Cells

/// The Name column: icon and name. Locked folders get a lock.
struct ExplorerNameCell: View {
    let row: ExplorerRow

    var body: some View {
        Label {
            Text(row.name).lineLimit(1).truncationMode(.middle)
        } icon: {
            if let file = row.file {
                Image(nsImage: Icons.icon(for: file.path)).resizable().frame(width: 16, height: 16).frame(width: 18)
            } else {
                // One width for both symbols, so names start on one edge.
                Image(systemName: row.isLocked ? "lock.fill" : "folder.fill")
                    .foregroundStyle(row.isLocked ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.sea))
                    .frame(width: 18)
            }
        }
        .help(help)
    }

    private var help: String {
        switch row.item {
        case .folder(let folder):
            folder.err != 0 ? "Ballast couldn't read this folder" : (row.path ?? folder.name)
        case .file(let file):
            file.size == file.bytes ? file.name : "\(file.name): \(file.size.bytes) of data, \(file.bytes.bytes) on disk"
        }
    }
}

/// The Items column: how many files a folder holds.
struct ExplorerItemsCell: View {
    let row: ExplorerRow

    var body: some View {
        Group {
            if row.folder == nil {
                Text("File")
            } else if row.isLocked {
                Text("–")
            } else {
                Text(row.items.formatted())
            }
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel(row.folder == nil ? "File" : "\(row.items.formatted()) files")
    }
}

/// The Size column: the row's share of the open folder as a depth-tinted
/// bar, and its size as a sounding on one right-aligned column edge.
struct ExplorerSizeCell: View {
    let row: ExplorerRow
    let parentTotal: Int64
    let largest: Int64

    var body: some View {
        HStack(spacing: 10) {
            ShareBar(fraction: Double(row.total) / Double(max(parentTotal, 1)),
                     weight: Double(row.total) / Double(max(largest, 1)))
                .frame(height: 5)
            Group {
                if row.isLocked {
                    // Unmeasured is not zero.
                    Text("Locked")
                        .foregroundStyle(.secondary)
                        .help("Ballast couldn't read this folder. Overview › Scan as Admin can measure it.")
                } else {
                    Sounding(bytes: row.total)
                }
            }
            .frame(width: 78, alignment: .trailing)
        }
    }
}

/// A split-view style divider between the map and the table: a hairline
/// with a wider grab area and the up-down resize pointer.
private struct ResizeDivider: View {
    let changed: (CGFloat) -> Void
    let ended: () -> Void

    var body: some View {
        RowHairline()
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { changed($0.translation.height) }
                            .onEnded { _ in ended() }
                    )
            }
            .accessibilityHidden(true)
    }
}
