import SwiftUI

struct ExplorerView: View {
    let model: AppModel
    @State private var selection: DirRow.ID?
    @State private var sortOrder = [KeyPathComparator(\DirRow.total, order: .reverse)]
    @AppStorage("explorerColoring") private var coloring: TreemapColoring = .size

    private static let maxTiles = 40

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VSplitView {
                TreemapCanvas(tiles: tiles, coloring: coloring) { tile in
                    if let id = tile.dirID { open(id) }
                }
                .padding(12)
                .frame(minHeight: 200, idealHeight: 320)

                table
                    .frame(minHeight: 180)
            }
        }
        .onAppear { model.openRootIfIdle() }
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
                    Task { if let path = await model.path(of: current.id) { Finder.reveal(path) } }
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            .width(min: 180, ideal: 340)

            TableColumn("Last Changed", value: \.newest) { row in
                let actionable = row.err == 0 && row.total > 0 && model.listItem(for: row)?.safety.level != .blocked
                AgeBadge(newest: row.newest, muted: !actionable)
            }
            .width(min: 90, ideal: 110)

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
            .width(min: 150, ideal: 220)

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
                Button("Copy Path") {
                    Task { if let path = await model.path(of: id) { Finder.copy(path) } }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { open(id) }
        }
    }
}
