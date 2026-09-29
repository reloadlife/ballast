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
    @State private var showingAll = false

    private static let shown = 10

    var body: some View {
        let files = list.files.filter { kind == nil || $0.kind == kind }
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Largest files").font(.headline)
                    Spacer(minLength: 8)
                    if list.isComplete, !list.files.isEmpty {
                        KindPicker(files: list.files, kind: $kind)
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                        if files.count > Self.shown {
                            Button("Show All") { showingAll = true }
                                .buttonStyle(.link)
                        }
                    }
                }
                if list.isComplete {
                    Text(LargeFileText.caption(locked: locked))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            VStack(spacing: 0) {
                if !list.isComplete {
                    LargeFileNote(symbol: "doc.text.magnifyingglass", text: "Largest files appear after the next full scan.",
                                  action: rescan.map { ("Full Rescan", $0) })
                } else if files.isEmpty {
                    LargeFileNote(symbol: "checkmark.circle", text: LargeFileText.none(kind))
                } else {
                    let largest = files[0].bytes
                    ForEach(Array(files.prefix(Self.shown).enumerated()), id: \.element.id) { index, file in
                        if index > 0 { Divider().padding(.leading, 14) }
                        LargeFileRow(model: model, file: file, largest: largest)
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .sheet(isPresented: $showingAll) {
            LargeFilesSheet(model: model, list: list, locked: locked, kind: kind)
        }
    }
}

/// All kinds, then each kind that has files.
private struct KindPicker: View {
    let files: [LargeFile]
    @Binding var kind: FileKind?

    var body: some View {
        let present = Set(files.map(\.kind))
        Picker("Kind", selection: $kind) {
            Text("All Kinds").tag(FileKind?.none)
            ForEach(FileKind.allCases.filter(present.contains)) { Text($0.title).tag(Optional($0)) }
        }
    }
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

private struct LargeFileNote: View {
    let symbol: String
    let text: String
    var action: (title: String, perform: () -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action.title, action: action.perform)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// One large file: its icon, where it is and when it last changed, its
/// size, and the list toggle. Clicking previews it.
struct LargeFileRow: View {
    let model: AppModel
    let file: LargeFile
    let largest: Int64
    @State private var hovered = false

    private var detail: String {
        "\(model.location(of: file.path)) · \(Age.relative(file.modified))"
    }

    var body: some View {
        let item = model.listItem(for: file)
        HStack(spacing: 12) {
            ListToggle(item: item, isOn: model.isPlanned(file.path)) {
                withAnimation(Motion.animation(.snappy)) { model.toggle(item) }
            }
            .frame(width: 20)

            Button { QuickLook.toggle(file.path) } label: {
                HStack(spacing: 12) {
                    Image(nsImage: Icons.icon(for: file.path))
                        .resizable()
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(detail)
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
            .accessibilityLabel("\(file.name), \(file.bytes.bytes), in \(model.location(of: file.path))")
            .accessibilityHint("Shows a preview")

            if hovered {
                Button { Finder.reveal(file.path) } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
            SizeBar(fraction: Double(file.bytes) / Double(max(largest, 1)))
                .frame(width: 80, height: 5)
            Text(file.bytes.bytes)
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(hovered ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovered = $0 }
        .draggable(URL(fileURLWithPath: file.path))
        .help(item.safety.level == .blocked ? "Protected: \(item.safety.reason)" : "Quick Look · \(file.size.bytes) of data")
        .contextMenu {
            Button("Quick Look") { QuickLook.toggle(file.path) }
            Button("Show in Finder") { Finder.reveal(file.path) }
            Button("Show in Explorer") {
                // Lands in its folder with large files shown, so it's there.
                UserDefaults.standard.set(true, forKey: "explorerShowsFiles")
                model.showInExplorer(file.path)
            }
            Button("Copy Path") { Finder.copy(file.path) }
            if item.safety.level == .blocked {
                Divider()
                Text("Protected: \(item.safety.reason)")
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let files = list.files.filter { kind == nil || $0.kind == kind }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Largest Files").font(.title2.weight(.semibold))
                    Text("\(files.count.formatted()) file\(files.count == 1 ? "" : "s"), \(files.reduce(0) { $0 + $1.bytes }.bytes) in all. \(LargeFileText.caption(locked: locked)).")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                KindPicker(files: list.files, kind: $kind)
                    .pickerStyle(.segmented)
                    .labelsHidden()
            }
            .padding(20)
            Divider()
            ScrollView {
                // Lazy: each row reads an icon and a safety verdict from disk.
                LazyVStack(spacing: 0) {
                    if files.isEmpty {
                        LargeFileNote(symbol: "checkmark.circle", text: LargeFileText.none(kind))
                    }
                    let largest = files.first?.bytes ?? 1
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { Divider().padding(.leading, 14) }
                        LargeFileRow(model: model, file: file, largest: largest)
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(.bar)
        }
        .frame(width: 640, height: 560)
    }
}
