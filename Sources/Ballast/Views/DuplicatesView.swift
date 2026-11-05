import SwiftUI

/// Suggestions › Duplicate Files: found only when asked, since it reads
/// the files. Each set of copies keeps one; the others can go on the list.
///
/// A self-contained chart section: it works in a ScrollView or VStack, and
/// inside a List it clears its row's insets, separator and background.
struct DuplicatesSection: View {
    let model: AppModel
    /// Verdicts for every copy, assessed off the main thread per report.
    @State private var safety: [String: Safety] = [:]

    var body: some View {
        ChartSection(title: "Duplicate files", note: "Copies of the same file, \(LargeFileText.threshold) or more.",
                     total: reclaimable, padded: false) {
            if case .done = model.duplicateSearch {
                Button("Find Again") { Task { await model.findDuplicates() } }
                    .buttonStyle(.link)
                    .tint(Theme.control)
            }
        } content: {
            content
                .padding(.vertical, 4)
        }
        .animation(Motion.animation(Motion.layout), value: phaseID)
        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .task(id: VerdictKey(rows: reportPaths, protected: model.preferences.protectedFolders)) {
            let requests = reportPaths.map { VerdictRequest(path: $0, isDirectory: false) }
            guard !requests.isEmpty else { return }
            let found = await model.verdicts(for: requests)
            guard !Task.isCancelled else { return }
            safety = found
        }
    }

    /// With the copies people picked to keep, not only the suggested ones.
    private var reclaimable: Int64? {
        guard case .done(let report) = model.duplicateSearch else { return nil }
        return report.groups.reduce(0) { $0 + $1.reclaimable(keeping: model.keptCopy(in: $1)) }
    }

    private var reportPaths: [String] {
        guard case .done(let report) = model.duplicateSearch else { return [] }
        return report.groups.flatMap { $0.copies.map(\.path) }
    }

    /// Which state is showing, for the transition between them.
    private var phaseID: Int {
        switch model.duplicateSearch {
        case .idle: 0
        case .running: 1
        case .done: 2
        case .failed: 3
        }
    }

    @ViewBuilder
    private var content: some View {
        let files = model.largeFiles
        switch model.duplicateSearch {
        case .idle, .failed:
            if !files.isComplete {
                SectionNote(symbol: "doc.on.doc", text: "Duplicates can be found once a full scan has listed your large files.")
                    .padding(.horizontal, Theme.Space.inset)
            } else {
                DuplicatesStart(fileCount: files.files.count, volume: Paths.volumeName, failure: failure) {
                    Task { await model.findDuplicates() }
                }
                .padding(.horizontal, Theme.Space.inset)
            }

        case .running(let progress):
            VStack(alignment: .leading, spacing: 8) {
                DuplicatesProgress(progress: progress) { model.cancelDuplicates() }
                SkeletonRows(count: 3)
            }
            .padding(.horizontal, Theme.Space.inset)
            .padding(.vertical, 6)

        case .done(let report):
            if report.groups.isEmpty {
                EmptyChart(symbol: "checkmark.circle", title: "No duplicates",
                           message: "No copies among \((report.checked - report.protectedFiles).formatted()) large files. Find Again after you've downloaded or copied big files.")
            } else {
                Text("Ballast keeps the oldest copy outside Downloads, the Desktop and the Trash, unless you pick another.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.inset)
                    .padding(.vertical, 8)
                ForEach(report.groups) { group in
                    RowHairline(leading: Theme.Space.inset)
                    DuplicateGroupRow(
                        group: group, kept: model.keptCopy(in: group), safety: safety, planned: model.plannedPaths,
                        location: model.location(of:),
                        keep: { [model] path in Motion.with(Motion.feedback) { model.keep(path, in: group) } },
                        addOthers: { [model] in Motion.with(Motion.feedback) { model.addDuplicates(in: group) } },
                        showInExplorer: { [model] path in model.showInExplorer(path) })
                        .padding(.horizontal, Theme.Space.inset)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                                removal: .opacity.animation(Motion.animation(Motion.exit))))
                }
            }
            let notes = Self.notes(report)
            if !notes.isEmpty {
                RowHairline(leading: Theme.Space.inset)
                ForEach(Array(notes.enumerated()), id: \.offset) { _, text in
                    SectionNote(symbol: "info.circle", text: text)
                        .font(.callout)
                        .padding(.horizontal, Theme.Space.inset)
                }
            }
        }
    }

    private var failure: String? {
        if case .failed(let message) = model.duplicateSearch { "Couldn't finish: \(message)" } else { nil }
    }

    /// What was left out, and why.
    static func notes(_ report: DuplicateReport) -> [String] {
        var notes: [String] = []
        let cloned = report.cloned.count
        if cloned > 0 {
            let copies = report.cloned.reduce(0) { $0 + $1.copies.count }
            notes.append("\(cloned) set\(cloned == 1 ? "" : "s") of copies (\(copies) files) already share storage as APFS clones, so removing them wouldn't free anything.")
        }
        if report.hardLinks > 0 {
            notes.append("\(report.hardLinks) hard link\(report.hardLinks == 1 ? " is" : "s are") another name for a file listed once, not a copy.")
        }
        if report.protectedFiles > 0 {
            notes.append("\(report.protectedFiles) file\(report.protectedFiles == 1 ? " is" : "s are") where Ballast doesn't clean (outside your home folder, apps' data, Photos, version history), so \(report.protectedFiles == 1 ? "it wasn't" : "they weren't") compared.")
        }
        return notes
    }
}

/// Before a search: what will be compared, the last failure if any, and
/// the button that starts it.
struct DuplicatesStart: View {
    let fileCount: Int
    let volume: String
    var failure: String?
    let find: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Find copies among the \(fileCount.formatted()) largest files on \(volume)")
                if let failure {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Files the same size are compared by their contents. Nothing is removed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(failure == nil ? "Find Duplicates" : "Try Again", action: find)
                .buttonStyle(.glass)
        }
        .padding(.vertical, Theme.Space.rowY)
    }
}

/// A running search: a thin depth line, what it's doing, and Stop.
struct DuplicatesProgress: View {
    let progress: DuplicateProgress
    let stop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                DepthProgress(fraction: progress.fraction)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
            }
            Button("Stop", action: stop)
                .buttonStyle(.glass)
        }
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        switch progress.stage {
        case .comparing:
            "Comparing \(progress.files.formatted()) of \(progress.totalFiles.formatted()) files of the same size"
        case .hashing:
            "Reading \(min(progress.files + 1, progress.totalFiles).formatted()) of \(progress.totalFiles.formatted()) files · \(progress.bytes.bytes) of \(progress.totalBytes.bytes)"
        }
    }
}

/// One set of identical files: which copy stays, and what the others free.
/// Exactly one copy is always kept; picking another moves the mark, and
/// "Add Others" never adds the kept one.
struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let kept: String
    let safety: [String: Safety]
    let planned: Set<String>
    let location: (String) -> String
    let keep: (String) -> Void
    let addOthers: () -> Void
    let showInExplorer: (String) -> Void
    @State private var expanded: Bool

    init(group: DuplicateGroup, kept: String, safety: [String: Safety], planned: Set<String>,
         location: @escaping (String) -> String, expanded: Bool = false,
         keep: @escaping (String) -> Void, addOthers: @escaping () -> Void,
         showInExplorer: @escaping (String) -> Void) {
        self.group = group
        self.kept = kept
        self.safety = safety
        self.planned = planned
        self.location = location
        self.keep = keep
        self.addOthers = addOthers
        self.showInExplorer = showInExplorer
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        let freed = group.freed(keeping: kept)
        let others = group.copies.filter { $0.path != kept }
        let addable = others.filter { safety[$0.path]?.level != .blocked }
        let added = !addable.isEmpty && addable.allSatisfy { planned.contains($0.path) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    Motion.with(Motion.state) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 12)
                        Image(nsImage: Icons.icon(for: group.copies[0].path))
                            .resizable()
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.copies.first { $0.path == kept }?.name ?? group.copies[0].name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(group.copies.count) copies · \(group.size.bytes) each")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.copies.count) copies of \(group.copies[0].name)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows each copy and which one stays")

                Button(added ? "Others Added" : "Add Others", action: addOthers)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(added || addable.isEmpty)
                    .help(addable.isEmpty ? "The other copies are protected" : "Add every copy but the one you keep to the Cleanup List")
                Sounding(bytes: group.reclaimable(keeping: kept))
                    .frame(width: 84, alignment: .trailing)
            }
            .padding(.vertical, Theme.Space.rowY)

            if expanded {
                VStack(spacing: 0) {
                    ForEach(group.copies) { copy in
                        CopyRow(copy: copy, location: location(copy.path), isKept: copy.path == kept,
                                freed: freed[copy.path] ?? 0, safety: safety[copy.path],
                                isPlanned: planned.contains(copy.path),
                                keep: { keep(copy.path) }, showInExplorer: { showInExplorer(copy.path) })
                    }
                }
                .padding(.leading, 22)
                .padding(.bottom, 6)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -4)),
                                        removal: .opacity.animation(Motion.animation(Motion.exit))))
            }
        }
    }
}

/// One copy: the "keep this one" radio, where it is, its verdict when it
/// isn't plainly safe, and what removing it frees.
struct CopyRow: View {
    let copy: DuplicateCopy
    let location: String
    let isKept: Bool
    let freed: Int64
    let safety: Safety?
    let isPlanned: Bool
    let keep: () -> Void
    let showInExplorer: () -> Void
    @State private var explaining = false

    private var detail: String {
        var parts = [location, "Modified \(Date(timeIntervalSince1970: TimeInterval(copy.modified)).formatted(date: .abbreviated, time: .omitted))"]
        if copy.sharing?.sharesAll == true { parts.append("Shares storage with another copy") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: keep) {
                Image(systemName: isKept ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isKept ? AnyShapeStyle(Theme.sea) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help(isKept ? "This copy stays" : "Keep this copy instead")
            .accessibilityLabel(isKept ? "Keeping \(copy.name)" : "Keep \(copy.name) instead")
            .accessibilityAddTraits(isKept ? .isSelected : [])

            VStack(alignment: .leading, spacing: 2) {
                Text(copy.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let safety, !isKept, safety.level != .safe {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        SafetyMark(level: safety.level)
                        Text(safety.reason)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            InfoPopoverButton(path: copy.path, level: safety?.level, isShown: $explaining)

            if isKept {
                Text("Keep")
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .trailing)
            } else {
                if isPlanned {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.sea)
                        .help("On the Cleanup List")
                        .accessibilityLabel("On the Cleanup List")
                }
                Sounding(bytes: freed, style: freed == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(width: 84, alignment: .trailing)
                    .help(freed == 0 ? "Shares its storage with the copy you keep, so removing it frees nothing" : "Space removing this copy frees")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .draggable(URL(fileURLWithPath: copy.path))
        .contextMenu {
            Button("Quick Look") { QuickLook.toggle(copy.path) }
            Button("Show in Finder") { Finder.reveal(copy.path) }
            Button("Show in Explorer", action: showInExplorer)
            Button("What Is This?") { explaining = true }
            if !isKept {
                Divider()
                Button("Keep This Copy", action: keep)
            }
            Divider()
            Button("Copy Path") { Finder.copy(copy.path) }
        }
    }
}
