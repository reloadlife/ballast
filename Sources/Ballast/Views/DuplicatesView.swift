import SwiftUI

/// Suggestions › Duplicate Files: found only when asked, since it reads
/// the files. Each set of copies keeps one; the others can go on the list.
struct DuplicatesSection: View {
    let model: AppModel

    var body: some View {
        Section {
            content
        } header: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Duplicate Files").font(.headline)
                Text("Copies of the same file, \(LargeFileText.threshold) or more.").foregroundStyle(.secondary)
                Spacer()
                if case .done(let report) = model.duplicateSearch {
                    Button("Find Again") { Task { await model.findDuplicates() } }
                        .buttonStyle(.link)
                    Text(reclaimable(report).bytes)
                        .font(.headline)
                        .monospacedDigit()
                }
            }
            .padding(.top, 10)
        }
    }

    /// With the copies people picked to keep, not only the suggested ones.
    private func reclaimable(_ report: DuplicateReport) -> Int64 {
        report.groups.reduce(0) { $0 + $1.reclaimable(keeping: model.keptCopy(in: $1)) }
    }

    @ViewBuilder
    private var content: some View {
        let files = model.largeFiles
        switch model.duplicateSearch {
        case .idle, .failed:
            if !files.isComplete {
                note("doc.on.doc", "Duplicates can be found once a full scan has listed your large files.")
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Find copies among the \(files.files.count.formatted()) largest files on \(Paths.volumeName)")
                        Text(failure ?? "Files the same size are compared by their contents. Nothing is removed.")
                            .font(.callout)
                            .foregroundStyle(failure == nil ? .secondary : Color.red)
                    }
                    Spacer(minLength: 12)
                    Button("Find Duplicates") { Task { await model.findDuplicates() } }
                }
                .padding(.vertical, 6)
            }

        case .running(let progress):
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(status(progress))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Stop") { model.cancelDuplicates() }
            }
            .padding(.vertical, 6)

        case .done(let report):
            if report.groups.isEmpty {
                note("checkmark.circle", "No copies among \((report.checked - report.protectedFiles).formatted()) large files.")
            } else {
                Text("Ballast keeps the oldest copy outside Downloads, the Desktop and the Trash, unless you pick another.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(report.groups) { group in
                    DuplicateGroupView(model: model, group: group)
                }
            }
            ForEach(notes(report), id: \.self) { text in
                note("info.circle", text)
            }
        }
    }

    private var failure: String? {
        if case .failed(let message) = model.duplicateSearch { "Couldn't finish: \(message)" } else { nil }
    }

    private func status(_ progress: DuplicateProgress) -> String {
        switch progress.stage {
        case .comparing:
            "Comparing \(progress.files.formatted()) of \(progress.totalFiles.formatted()) files of the same size"
        case .hashing:
            "Reading \(min(progress.files + 1, progress.totalFiles).formatted()) of \(progress.totalFiles.formatted()) files · \(progress.bytes.bytes) of \(progress.totalBytes.bytes)"
        }
    }

    /// What was left out, and why.
    private func notes(_ report: DuplicateReport) -> [String] {
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

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// One set of identical files: which copy stays, and what the others free.
private struct DuplicateGroupView: View {
    let model: AppModel
    let group: DuplicateGroup
    @State private var expanded = false

    var body: some View {
        let kept = model.keptCopy(in: group)
        let freed = group.freed(keeping: kept)
        let items = model.duplicateItems(in: group)
        let addable = items.filter { $0.safety.level != .blocked }
        let added = !addable.isEmpty && addable.allSatisfy { model.isPlanned($0.path) }
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(group.copies) { copy in
                CopyRow(model: model, copy: copy, isKept: copy.path == kept, freed: freed[copy.path] ?? 0,
                        item: items.first { $0.path == copy.path }) {
                    withAnimation(Motion.animation(.snappy)) { model.keep(copy.path, in: group) }
                }
            }
        } label: {
            HStack(spacing: 12) {
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
                Button(added ? "Others Added" : "Add Others") {
                    withAnimation(Motion.animation(.snappy)) { model.addDuplicates(in: group) }
                }
                .controlSize(.small)
                .disabled(added || addable.isEmpty)
                .help(addable.isEmpty ? "The other copies are protected" : "Add every copy but the one you keep to the Cleanup List")
                Text(group.reclaimable(keeping: kept).bytes)
                    .monospacedDigit()
                    .frame(width: 76, alignment: .trailing)
            }
            .padding(.vertical, 2)
        }
    }
}

private struct CopyRow: View {
    let model: AppModel
    let copy: DuplicateCopy
    let isKept: Bool
    let freed: Int64
    let item: PlanItem?
    let keep: () -> Void

    private var detail: String {
        var parts = [model.location(of: copy.path), "Modified \(Date(timeIntervalSince1970: TimeInterval(copy.modified)).formatted(date: .abbreviated, time: .omitted))"]
        if copy.sharing?.sharesAll == true { parts.append("Shares storage with another copy") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: keep) {
                Image(systemName: isKept ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isKept ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .help(isKept ? "This copy stays" : "Keep this copy instead")
            .accessibilityLabel(isKept ? "Keeping \(copy.name)" : "Keep \(copy.name) instead")

            VStack(alignment: .leading, spacing: 2) {
                Text(copy.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let item, !isKept, item.safety.level != .safe {
                    Label(item.safety.reason, systemImage: item.safety.level.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isKept {
                Text("Keep")
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
            } else {
                if let item, model.isPlanned(item.path) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .help("On the Cleanup List")
                }
                Text(freed.bytes)
                    .monospacedDigit()
                    .foregroundStyle(freed == 0 ? .secondary : .primary)
                    .frame(width: 76, alignment: .trailing)
                    .help(freed == 0 ? "Shares its storage with the copy you keep, so removing it frees nothing" : "Space removing this copy frees")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .draggable(URL(fileURLWithPath: copy.path))
        .contextMenu {
            Button("Quick Look") { QuickLook.toggle(copy.path) }
            Button("Show in Finder") { Finder.reveal(copy.path) }
            Button("Show in Explorer") { model.showInExplorer(copy.path) }
            Divider()
            Button("Copy Path") { Finder.copy(copy.path) }
        }
    }
}
