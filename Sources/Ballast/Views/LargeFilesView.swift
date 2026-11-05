import SwiftUI

/// "Largest files" on the Overview: the ten largest files of at least
/// `LargeFiles.threshold`, with a kind filter and the whole list a click away.
struct LargestFiles: View {
    let model: AppModel
    let list: LargeFileList
    /// Unreadable folders: their files can't be listed.
    let locked: Int
    /// Runs the full scan that fills the list, when the index predates it.
    let rescan: (() -> Void)?
    @State private var kind: FileKind?
    @State private var filtered = LargeFileFilter.Result.empty
    /// The first filter pass has run (it's quick, but runs after the first frame).
    @State private var ready = false
    @State private var showingAll = false
    @State private var verdicts: [String: Safety] = [:]

    private static let shown = 10

    private var visible: ArraySlice<LargeFile> { filtered.shown.prefix(Self.shown) }

    var body: some View {
        ChartSection(title: "Largest files", note: list.isComplete ? LargeFileText.caption(locked: locked) : nil,
                     total: list.isComplete ? filtered.bytes : nil, padded: false) {
            if list.isComplete, !list.files.isEmpty {
                KindFilterBar(kinds: filtered.kinds, selection: $kind)
                if filtered.shown.count > Self.shown {
                    Button("Show All") { showingAll = true }
                        .buttonStyle(.link)
                }
            }
        } content: {
            Group {
                if !list.isComplete {
                    SectionNote(symbol: "doc.text.magnifyingglass", text: "Largest files appear after the next full scan.",
                                action: rescan.map { ("Full Rescan", $0) }, actionDisabled: model.isBusyWithUserWork)
                        .padding(.horizontal, Theme.Space.inset)
                } else if !ready {
                    SkeletonRows(count: 3)
                        .padding(.horizontal, Theme.Space.inset)
                } else if filtered.shown.isEmpty {
                    EmptyChart(symbol: "checkmark.circle", title: "No large files",
                               message: "\(LargeFileText.none(kind)) Files this size show up here as soon as a scan finds one.")
                } else {
                    let largest = filtered.shown.first?.bytes ?? 1
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { RowHairline(leading: 66) }
                        row(file, largest: largest)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .animation(Motion.animation(Motion.layout), value: kind)
        .task(id: FilterKey(files: list.files, kind: kind)) {
            filtered = LargeFileFilter.apply(list.files, kind: kind)
            ready = true
        }
        .task(id: VerdictKey(rows: visible.map(\.path), protected: model.preferences.protectedFolders)) {
            let requests = visible.map { VerdictRequest(path: $0.path, isDirectory: false) }
            guard !requests.isEmpty else { return }
            let found = await model.verdicts(for: requests)
            guard !Task.isCancelled else { return }
            verdicts.merge(found) { _, new in new }
        }
        .sheet(isPresented: $showingAll) {
            LargeFilesSheet(model: model, list: list, locked: locked, kind: kind)
                .ownsInkPlate()
        }
    }

    private func row(_ file: LargeFile, largest: Int64) -> some View {
        LargeFileRow(file: file, location: model.location(of: file.path), largest: largest,
                     safety: verdicts[file.path], isPlanned: model.isPlanned(file.path),
                     toggle: { [model] in Motion.with(Motion.feedback) { model.toggle(model.listItem(for: file)) } },
                     showInExplorer: { [model] in LargeFileRow.showInExplorer(file, model: model) })
    }
}

/// What a filtered list depends on, for `.task(id:)`.
struct FilterKey: Equatable {
    let files: [LargeFile]
    let kind: FileKind?
}

enum LargeFileText {
    static var threshold: String { LargeFiles.threshold.formatted(.byteCount(style: .file)) }

    /// What's listed and, honestly, what can't be.
    static func caption(locked: Int) -> String {
        let listed = "Files of \(threshold) or more"
        guard locked > 0 else { return listed }
        return "\(listed) · Files in \(locked.formatted()) locked folder\(locked == 1 ? "" : "s") aren't listed"
    }

    static func none(_ kind: FileKind?) -> String {
        guard let kind else { return "No file is \(threshold) or more." }
        return "No \(kind.title.lowercased()) of \(threshold) or more."
    }
}

/// One large file: the list toggle, its icon, where it is and when it
/// last changed, its share of the largest file and its size. Clicking
/// previews it; "What is this?" and Show in Finder appear on hover.
struct LargeFileRow: View {
    let file: LargeFile
    /// Where it is, for the detail line ("~/Movies").
    let location: String
    let largest: Int64
    /// Its verdict, assessed off the main thread; nil while that runs.
    var safety: Safety?
    var isPlanned = false
    var toggle: () -> Void = {}
    var showInExplorer: () -> Void = {}
    @State private var hovered = false
    @State private var explaining = false

    /// Lands in its folder with large files shown, so it's there.
    @MainActor static func showInExplorer(_ file: LargeFile, model: AppModel) {
        UserDefaults.standard.set(true, forKey: "explorerShowsFiles")
        model.showInExplorer(file.path)
    }

    private var item: PlanItem? {
        safety.map {
            PlanItem(name: file.name, path: file.path, bytes: file.bytes, action: .remove, isDirectory: false,
                     safety: $0, included: $0.level == .safe)
        }
    }

    var body: some View {
        let tools = hovered || explaining
        HStack(spacing: 12) {
            ListToggle(item: item, isOn: isPlanned, action: toggle)
                .frame(width: 20)

            Button { QuickLook.toggle(file.path) } label: {
                HStack(spacing: 12) {
                    Image(nsImage: Icons.icon(for: file.path))
                        .resizable()
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(location) · \(Age.relative(file.modified))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(file.name), \(file.bytes.bytes), in \(location)")
            .accessibilityHint("Shows a preview")

            HStack(spacing: 6) {
                InfoPopoverButton(path: file.path, level: safety?.level, isShown: $explaining)
                Button { Finder.reveal(file.path) } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                    .accessibilityLabel("Show \(file.name) in Finder")
            }
            .opacity(tools ? 1 : 0)
            .allowsHitTesting(tools)
            .accessibilityHidden(!tools)
            .animation(Motion.animation(Motion.feedback), value: tools)

            ShareBar(fraction: Double(file.bytes) / Double(max(largest, 1)))
                .frame(width: 72, height: 5)
            Sounding(bytes: file.bytes)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.inset)
        .padding(.vertical, Theme.Space.rowY)
        .background(hovered ? Theme.water.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .onHover { hovered = $0 }
        .draggable(URL(fileURLWithPath: file.path))
        .help(safety?.level == .blocked ? "Protected: \(safety?.reason ?? "")" : "Quick Look · \(file.size.bytes) of data")
        .contextMenu {
            Button("Quick Look") { QuickLook.toggle(file.path) }
            Button("Show in Finder") { Finder.reveal(file.path) }
            Button("Show in Explorer", action: showInExplorer)
            Button("What Is This?") { explaining = true }
            Divider()
            Button("Copy Path") { Finder.copy(file.path) }
            if let safety, safety.level == .blocked {
                Divider()
                Text("Protected: \(safety.reason)")
            }
        }
    }
}

/// Every large file on the disk, filtered by kind.
struct LargeFilesSheet: View {
    let model: AppModel
    let list: LargeFileList
    let locked: Int
    @State var kind: FileKind?
    @State private var filtered = LargeFileFilter.Result.empty
    @State private var ready = false
    @State private var verdicts: [String: Safety] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Largest Files").font(.title2.weight(.semibold))
                        Text("\(filtered.shown.count.formatted()) file\(filtered.shown.count == 1 ? "" : "s"). \(LargeFileText.caption(locked: locked)).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Sounding(bytes: filtered.bytes, font: Theme.hero(32))
                }
                if !filtered.kinds.isEmpty {
                    KindFilterBar(kinds: filtered.kinds, selection: $kind)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 14)

            if !ready {
                SkeletonRows(count: 8)
                    .padding(.horizontal, Theme.Space.inset)
                    .chartSurface()
                    .padding(.horizontal, 24)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if filtered.shown.isEmpty {
                EmptyChart(symbol: "checkmark.circle", title: "No large files",
                           message: "\(LargeFileText.none(kind)) Files this size show up here as soon as a scan finds one.")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    // Lazy: each row reads an icon from disk.
                    LazyVStack(spacing: 0) {
                        let largest = filtered.shown.first?.bytes ?? 1
                        ForEach(Array(filtered.shown.enumerated()), id: \.element.id) { index, file in
                            if index > 0 { RowHairline(leading: 66) }
                            LargeFileRow(file: file, location: model.location(of: file.path), largest: largest,
                                         safety: verdicts[file.path], isPlanned: model.isPlanned(file.path),
                                         toggle: { [model] in Motion.with(Motion.feedback) { model.toggle(model.listItem(for: file)) } },
                                         showInExplorer: { [model] in
                                             dismiss()
                                             LargeFileRow.showInExplorer(file, model: model)
                                         })
                        }
                    }
                    .padding(.vertical, 4)
                    .chartSurface()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.ink)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 680, height: 600)
        .background(Theme.water)
        .animation(Motion.animation(Motion.layout), value: kind)
        .task(id: FilterKey(files: list.files, kind: kind)) {
            filtered = LargeFileFilter.apply(list.files, kind: kind)
            ready = true
        }
        .task(id: VerdictKey(rows: list.files, protected: model.preferences.protectedFolders)) {
            // Largest first, a chunk at a time: the top of the list gets
            // its toggles while the rest is still being assessed.
            let requests = list.files.map { VerdictRequest(path: $0.path, isDirectory: false) }
            await model.verdicts(for: requests) { found in verdicts.merge(found) { _, new in new } }
        }
    }
}
