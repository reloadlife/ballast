import SwiftUI

struct ExplorerView: View {
    let model: AppModel
    @State private var selection: DirRow.ID?
    @State private var sortOrder = [KeyPathComparator(\DirRow.total, order: .reverse)]
    @AppStorage("explorerColoring") private var coloring: TreemapColoring = .size
    /// The height the divider was dragged to; the map gets less when the
    /// window is too short to fit it above the table.
    @State private var mapHeight: CGFloat = 320
    @State private var shownMapHeight: CGFloat = 320
    @State private var dragStartHeight: CGFloat?
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searchedFor = ""
    @State private var hitSelection: SearchHit.ID?
    @FocusState private var searchFocused: Bool

    private static let maxTiles = 40
    private static let minMapHeight: CGFloat = 200

    private var isSearching: Bool { SearchQuery.pattern(for: query) != nil }

    var body: some View {
        Group {
            if isSearching {
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
            focusSearchIfRequested()
        }
        .onDisappear { model.isExplorerShown = false }
        .onChange(of: model.searchRequested) { focusSearchIfRequested() }
    }

    /// ⌘F from anywhere lands here.
    private func focusSearchIfRequested() {
        guard model.searchRequested else { return }
        model.searchRequested = false
        Task { searchFocused = true }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Not a VSplitView: that's an AppKit split view whose panes carry
            // the sidebar and inspector insets into their minimum widths,
            // which crashed narrow windows with the Cleanup List open.
            TreemapCanvas(tiles: tiles, coloring: coloring) { tile in
                if let id = tile.dirID { open(id) }
            }
            .padding(12)
            .frame(minHeight: Self.minMapHeight, maxHeight: mapHeight)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownMapHeight = $0 }
            // The map keeps its height and the table gives way first, as
            // with a split view.
            .layoutPriority(1)

            ResizeDivider { translation in
                let start = dragStartHeight ?? shownMapHeight
                dragStartHeight = start
                mapHeight = max(start + translation, Self.minMapHeight)
            } ended: {
                dragStartHeight = nil
            }

            table
                .frame(minHeight: 180, maxHeight: .infinity)
        }
    }

    private func open(_ id: Int64) {
        selection = nil
        model.open(id)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                if model.trail.count > 1 { open(model.trail[model.trail.count - 2].id) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(model.trail.count < 2)
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .help("Back (⌘←)")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.trail.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        let isLast = index == model.trail.count - 1
                        Button(index == 0 ? Paths.volumeName : row.name) { open(row.id) }
                            .buttonStyle(.plain)
                            .fontWeight(isLast ? .semibold : .regular)
                            .foregroundStyle(isLast ? .primary : .secondary)
                    }
                }
            }

            Picker("Color by", selection: $coloring) {
                ForEach(TreemapColoring.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(coloring == .size ? "Darker tiles are bigger" : "More orange means longer untouched")

            if let current = model.trail.last {
                Text(current.total.bytes)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if model.trail.count == 1, model.usedBytes > current.total {
                    // The walk sees folders only; the rest of "used" is the
                    // sealed system volume, snapshots and purgeable space.
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help("\((model.usedBytes - current.total).bytes) of used space isn't in any folder Ballast can see: the macOS system volume, APFS snapshots and purgeable space.")
                }
                Button {
                    // The selected folder if there is one, else the open one.
                    if let selected, let path = model.displayPath(of: selected) {
                        Finder.reveal(path)
                    } else {
                        Task { if let path = await model.path(of: current.id) { Finder.reveal(path) } }
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("r", modifiers: [.command, .option])
                .help("Show in Finder (⌥⌘R)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var selected: DirRow? {
        selection.flatMap { id in model.children.first { $0.id == id } }
    }

    // MARK: Map

    private var tiles: [TreemapTile] {
        let shown = model.children.filter { $0.total > 0 }.prefix(Self.maxTiles)
        var tiles = shown.map { row in
            TreemapTile(id: "\(row.id)", dirID: row.id, name: row.name, bytes: row.total, locked: row.err != 0,
                        planned: model.displayPath(of: row).map(model.isPlanned) ?? false, kind: .folder,
                        newest: row.newest)
        }
        let rest = model.children.dropFirst(shown.count).reduce(0) { $0 + $1.total }
        if rest > 0 {
            tiles.append(TreemapTile(id: "rest", dirID: nil, name: "Other folders", bytes: rest,
                                     locked: false, planned: false, kind: .rest))
        }
        if let current = model.trail.last, current.own > 0 {
            tiles.append(TreemapTile(id: "files", dirID: nil, name: "Files", bytes: current.own,
                                     locked: false, planned: false, kind: .files))
        }
        return tiles.sorted { $0.bytes > $1.bytes }
    }

    // MARK: Table

    private var table: some View {
        let parentTotal = max(model.trail.last?.total ?? 1, 1)
        return Table(of: DirRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                Label {
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: row.err != 0 ? "lock.fill" : "folder.fill")
                        .foregroundStyle(row.err != 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
                .help(row.err != 0 ? "Ballast couldn't read this folder" : "\(row.files.formatted()) files")
            }
            .width(min: 120, ideal: 340)

            TableColumn("Last Changed", value: \.newest) { row in
                let actionable = row.err == 0 && row.total > 0 && model.listItem(for: row)?.safety.level != .blocked
                AgeBadge(newest: row.newest, muted: !actionable)
            }
            .width(min: 72, ideal: 110)

            TableColumn("Size", value: \.total) { row in
                HStack(spacing: 10) {
                    SizeBar(fraction: Double(row.total) / Double(parentTotal))
                        .frame(height: 5)
                    if row.err != 0 {
                        // Unmeasured is not zero.
                        Text("Locked")
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .trailing)
                            .help("Ballast couldn't read this folder. Overview › Scan as Admin can measure it.")
                    } else {
                        Text(row.total.bytes)
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                }
            }
            .width(min: 110, ideal: 220)

            TableColumn("") { row in
                let item = model.listItem(for: row)
                ListToggle(item: item, isOn: item.map { model.isPlanned($0.path) } ?? false) {
                    if let item { withAnimation(Motion.animation(.snappy)) { model.toggle(item) } }
                }
            }
            .width(28)
        } rows: {
            ForEach(model.children.sorted(using: sortOrder)) { row in
                TableRow(row)
                    .draggable(URL(fileURLWithPath: model.displayPath(of: row) ?? "/"))
            }
        }
        .contextMenu(forSelectionType: DirRow.ID.self) { ids in
            if let id = ids.first, let row = model.children.first(where: { $0.id == id }) {
                Button("Open") { open(id) }
                if let item = model.listItem(for: row) {
                    if item.safety.level == .blocked {
                        Text("Protected: \(item.safety.reason)")
                    } else {
                        Button(model.isPlanned(item.path) ? "Remove from Cleanup List" : "Add to Cleanup List") {
                            model.toggle(item)
                        }
                    }
                }
                Divider()
                Button("Show in Finder") {
                    Task { if let path = await model.path(of: id) { Finder.reveal(path) } }
                }
                if let path = model.displayPath(of: row) {
                    Button("Quick Look") { QuickLook.toggle(path) }
                }
                Divider()
                Button("Copy Path") {
                    Task { if let path = await model.path(of: id) { Finder.copy(path) } }
                }
                Button("Copy as CSV") { Finder.copy(csv(ids)) }
            }
        } primaryAction: { ids in
            if let id = ids.first { open(id) }
        }
        // Space previews the selected folder, as in Finder.
        .onKeyPress(.space) {
            guard let selected, let path = model.displayPath(of: selected) else { return .ignored }
            QuickLook.toggle(path)
            return .handled
        }
    }

    /// The chosen rows with a header line, ready to paste into a spreadsheet.
    private func csv(_ ids: Set<DirRow.ID>) -> String {
        let whole = model.trail.last?.total ?? 0
        let rows = model.children.sorted(using: sortOrder).filter { ids.contains($0.id) }
        return CSV.document(rows.compactMap { row in model.displayPath(of: row).map { ExportRow(path: $0, row: row, of: whole) } })
    }

    // MARK: Search results

    private var results: some View {
        VStack(spacing: 0) {
            HStack {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if hits.isEmpty && searchedFor == query {
                ContentUnavailableView.search(text: query)
            } else {
                Table(hits, selection: $hitSelection) {
                    TableColumn("Name") { hit in
                        Label {
                            Text(hit.row.name).lineLimit(1).truncationMode(.middle)
                        } icon: {
                            Image(systemName: hit.row.err != 0 ? "lock.fill" : "folder.fill")
                                .foregroundStyle(hit.row.err != 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        }
                    }
                    .width(min: 120, ideal: 220)

                    TableColumn("Location") { hit in
                        Text(location(of: hit))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(hit.path)
                    }
                    .width(min: 100, ideal: 280)

                    TableColumn("Last Changed") { hit in
                        AgeBadge(newest: hit.row.newest, muted: hit.row.err != 0)
                    }
                    .width(min: 72, ideal: 110)

                    TableColumn("Size") { hit in
                        Text(hit.row.err != 0 ? "Locked" : hit.row.total.bytes)
                            .monospacedDigit()
                            .foregroundStyle(hit.row.err != 0 ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 72, ideal: 90)
                }
                .contextMenu(forSelectionType: SearchHit.ID.self) { ids in
                    if let hit = ids.first.flatMap({ id in hits.first { $0.id == id } }) {
                        Button("Show in Explorer") { show(hit) }
                        Button("Show in Finder") { Finder.reveal(hit.path) }
                        Button("Quick Look") { QuickLook.toggle(hit.path) }
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
        }
    }

    private var summary: String {
        guard searchedFor == query else { return "Searching…" }
        let quoted = "“\(query.trimmingCharacters(in: .whitespacesAndNewlines))”"
        if hits.count >= 200 { return "The 200 largest folders matching \(quoted)" }
        return "\(hits.count) folder\(hits.count == 1 ? "" : "s") matching \(quoted), largest first"
    }

    private func location(of hit: SearchHit) -> String {
        let parent = (hit.path as NSString).deletingLastPathComponent
        return parent == "/" ? Paths.volumeName : parent.replacingOccurrences(of: Catalog.home, with: "~")
    }

    /// Leaves search and opens the folder, like drilling in from the table.
    private func show(_ hit: SearchHit) {
        query = ""
        open(hit.row.id)
    }
}

/// A split-view style divider between the map and the table: a hairline
/// with a wider grab area and the up-down resize pointer.
private struct ResizeDivider: View {
    let changed: (CGFloat) -> Void
    let ended: () -> Void

    var body: some View {
        Divider()
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
