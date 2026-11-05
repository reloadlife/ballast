import SwiftUI

/// Explorer's header: back, the breadcrumb trail, the open folder's size as
/// the screen's one figure, and the map controls on glass. It never
/// overflows: the trail folds its middle into a menu, then keeps only the
/// open folder, and below `compactWidth` the map controls fold into one
/// glass menu. Takes plain values, so it previews without AppModel.
struct ExplorerHeader: View {
    let crumbs: [Crumb]
    /// The open folder's size.
    let total: Int64?
    /// Used space no folder accounts for, shown at the disk root only.
    var unseen: Int64?
    @Binding var showsMap: Bool
    @Binding var showsFiles: Bool
    @Binding var coloring: TreemapColoring
    /// False until a full scan has listed large files.
    let filesAvailable: Bool
    let open: (Int64) -> Void
    let reveal: () -> Void

    /// Below this width the map controls fold into one menu.
    nonisolated static let compactWidth: CGFloat = 640
    @State private var compact = false

    /// Snapshots set `compact` directly; the app measures it.
    init(crumbs: [Crumb], total: Int64?, unseen: Int64? = nil, showsMap: Binding<Bool>, showsFiles: Binding<Bool>,
         coloring: Binding<TreemapColoring>, filesAvailable: Bool, compact: Bool = false,
         open: @escaping (Int64) -> Void, reveal: @escaping () -> Void) {
        self.crumbs = crumbs
        self.total = total
        self.unseen = unseen
        _showsMap = showsMap
        _showsFiles = showsFiles
        _coloring = coloring
        self.filesAvailable = filesAvailable
        self.open = open
        self.reveal = reveal
        _compact = State(initialValue: compact)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if crumbs.count > 1 { open(crumbs[crumbs.count - 2].id) }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .disabled(crumbs.count < 2)
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .help("Back (⌘←)")
            .accessibilityLabel("Back")

            Breadcrumb(crumbs: crumbs, open: open)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let total {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Sounding(bytes: total, font: Theme.hero(22))
                    if let unseen, unseen > 0 {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .help("\(unseen.bytes) of used space isn't in any folder Ballast can see: the macOS system volume, APFS snapshots and purgeable space.")
                            .accessibilityLabel("\(unseen.bytes) of used space isn't in any folder")
                    }
                }
                .fixedSize()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Folder size \(total.bytes)")
            }

            Group {
                if compact { controlsMenu } else { controls }
            }
            .fixedSize()

            Button(action: reveal) {
                Image(systemName: "folder")
            }
            .buttonStyle(.glass)
            .keyboardShortcut("r", modifiers: [.command, .option])
            .help("Show in Finder (⌥⌘R)")
            .accessibilityLabel("Show in Finder")
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactWidth } action: { compact = $0 }
    }

    private var filesHelp: String {
        guard filesAvailable else { return "Large files appear after the next full scan" }
        return showsFiles ? "Hide files of \(LargeFileText.threshold) or more"
            : "Show files of \(LargeFileText.threshold) or more among the folders"
    }

    /// The map controls as glass that merges into one floating tool.
    private var controls: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                Toggle(isOn: $showsMap) {
                    Label("Map", systemImage: "square.grid.3x3")
                }
                .help(showsMap ? "Hide the folder map" : "Show the folder map")

                Toggle(isOn: $showsFiles) {
                    Label("Large Files", systemImage: "doc")
                }
                .disabled(!filesAvailable)
                .help(filesHelp)

                Picker("Color by", selection: $coloring) {
                    ForEach(TreemapColoring.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .tint(Theme.control)
                .labelsHidden()
                .disabled(!showsMap)
                .help(coloring.help)
            }
            .toggleStyle(.button)
            .tint(Theme.control)
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
        }
    }

    private var controlsMenu: some View {
        Menu {
            Toggle("Show Map", isOn: $showsMap)
            Toggle("Show Large Files", isOn: $showsFiles)
                .disabled(!filesAvailable)
            Picker("Color by", selection: $coloring) {
                ForEach(TreemapColoring.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .help("Map and list options")
        .accessibilityLabel("View options")
    }
}

/// The trail from the disk to the open folder. Wide: every step. Tight:
/// the first step, the middle in a "…" menu, the last two. Tighter: the
/// open folder only, truncated in the middle.
struct Breadcrumb: View {
    let crumbs: [Crumb]
    let open: (Int64) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            trail(keeping: crumbs.count).fixedSize()
            if crumbs.count > 3 { trail(keeping: 2).fixedSize() }
            if crumbs.count > 2 { trail(keeping: 1).fixedSize() }
            last
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    /// First step, a menu of the hidden middle, then the last `keeping`.
    private func trail(keeping: Int) -> some View {
        let hidden = crumbs.count > keeping + 1 ? Array(crumbs[1..<(crumbs.count - keeping)]) : []
        let tail = Array(crumbs.suffix(hidden.isEmpty ? max(crumbs.count - 1, 0) : keeping))
        return HStack(spacing: 4) {
            if let first = crumbs.first {
                step(first, isLast: crumbs.count == 1)
            }
            if !hidden.isEmpty {
                chevron
                Menu {
                    ForEach(hidden.reversed()) { crumb in
                        Button(crumb.name) { open(crumb.id) }
                    }
                } label: {
                    Text("…")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("\(hidden.count) more folder\(hidden.count == 1 ? "" : "s")")
                .accessibilityLabel("\(hidden.count) more folders")
            }
            ForEach(tail) { crumb in
                chevron
                step(crumb, isLast: crumb.id == crumbs.last?.id)
            }
        }
    }

    /// Only the open folder, truncated when even that doesn't fit.
    private var last: some View {
        HStack(spacing: 4) {
            if crumbs.count > 1 {
                Menu {
                    ForEach(crumbs.dropLast().reversed()) { crumb in
                        Button(crumb.name) { open(crumb.id) }
                    }
                } label: {
                    Text("…")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Enclosing folders")
                chevron
            }
            if let crumb = crumbs.last {
                Text(crumb.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func step(_ crumb: Crumb, isLast: Bool) -> some View {
        Button(crumb.name) { open(crumb.id) }
            .buttonStyle(.plain)
            .fontWeight(isLast ? .semibold : .regular)
            .foregroundStyle(isLast ? .primary : .secondary)
            .lineLimit(1)
            .accessibilityAddTraits(isLast ? .isHeader : [])
    }
}
