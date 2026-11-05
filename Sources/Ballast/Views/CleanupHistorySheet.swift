import SwiftUI

/// The last cleanups, newest first, with Put Back for the ones whose items
/// are still in the Trash.
struct CleanupHistorySheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// What's still in the Trash per cleanup, checked off the main thread
    /// (it looks at the disk); nil until the first check ends.
    @State private var trash: [UUID: HistoryTrash]?

    var body: some View {
        let busy = model.isBusyWithUserWork
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Cleanup History").font(.title2.weight(.semibold))
                Text("Put Back returns what a cleanup moved to the Trash, for as long as it's still there.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            Hairline()

            if model.cleanupLog.isEmpty {
                EmptyChart(symbol: "clock.arrow.circlepath", title: "No cleanups yet",
                           message: "Each cleanup is listed here, including auto-clean runs, with a way to put things back while they're in the Trash.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(spacing: 0) {
                            ForEach(Array(model.cleanupLog.reversed().enumerated()), id: \.element.id) { index, record in
                                if index > 0 { Hairline(leading: 46) }
                                HistoryRow(record: record, trash: trash?[record.id],
                                           putBackReport: model.putBackReport?.recordID == record.id ? model.putBackReport : nil,
                                           busy: busy) {
                                    Task { await model.putBack(record.id) }
                                }
                            }
                        }
                        .chartSurface(radius: Theme.Radius.row)

                        Text("Items deleted permanently, emptied from the Trash, or cleaned by a tool's own command (like `npm cache clean`) can't be put back.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(24)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                if busy {
                    HistoryStatus(progress: model.scanProgress)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(.bar)
        }
        .frame(width: 580, height: 520)
        .background(Theme.water)
        .onAppear { model.reloadCleanupLog() }
        // Again whenever the log changes or a run ends (Put Back, emptying
        // the Trash), since either changes what's still there.
        .task(id: HistoryKey(ids: model.cleanupLog.map(\.id), busy: busy, putBack: model.putBackReport?.recordID)) {
            let log = model.cleanupLog
            let found = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: log.map { ($0.id, HistoryTrash($0, checkingDisk: true)) })
            }.value
            guard !Task.isCancelled else { return }
            trash = found
        }
    }
}

private struct HistoryKey: Equatable {
    let ids: [UUID]
    let busy: Bool
    let putBack: UUID?
}

/// What of a cleanup went to the Trash, and how much of it is still there.
struct HistoryTrash: Sendable, Equatable {
    /// Moves to the Trash the cleanup made.
    let trashed: Int
    /// Of those, still in the Trash and not put back.
    let pending: Int

    /// With `checkingDisk`, looks at the disk (`CleanupRecord.pending`),
    /// so only off the main thread; without, nothing counts as pending.
    init(_ record: CleanupRecord, checkingDisk: Bool = false) {
        trashed = record.items.reduce(0) { $0 + $1.moves.count }
        pending = checkingDisk ? record.pending.count : 0
    }

    init(trashed: Int, pending: Int) {
        self.trashed = trashed
        self.pending = pending
    }
}

/// The job holding the gate, from the live progress, so only this line
/// redraws as it changes.
private struct HistoryStatus: View {
    let progress: ScanProgressModel

    var body: some View {
        HStack(spacing: 8) {
            DepthProgress(fraction: nil)
                .frame(width: 64)
            Text(progress.status?.title ?? "Working")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// One cleanup: when, what, where it stands, and Put Back while it can.
struct HistoryRow: View {
    let record: CleanupRecord
    /// Nil while the Trash is being checked.
    let trash: HistoryTrash?
    let putBackReport: PutBackReport?
    var busy = false
    var putBack: () -> Void = {}

    var body: some View {
        let pending = trash?.pending ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Theme.sea)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let trash {
                        Label(status(trash), systemImage: statusSymbol(trash))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Checking the Trash")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    ByteColumn(bytes: record.bytes, width: 84)
                    if pending > 0 {
                        Button("Put Back", action: putBack)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(busy)
                            .help("Move \(pending) item\(pending == 1 ? "" : "s") from the Trash back where they were")
                    }
                }
            }
            if let putBackReport {
                PutBackSummary(report: putBackReport)
                    .padding(.leading, 34)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .animation(Motion.animation(Motion.state), value: trash)
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        if record.auto { return "wand.and.sparkles" }
        return record.items.contains { !$0.moves.isEmpty } ? "trash" : "flame"
    }

    private var title: String {
        let count = record.items.count
        let noun = record.auto ? "build folder\(count == 1 ? "" : "s")" : "item\(count == 1 ? "" : "s")"
        let when = record.date.formatted(date: .abbreviated, time: .shortened)
        let prefix = record.auto ? "Auto-clean: " : ""
        return "\(prefix)\(count) \(noun) · \(when)"
    }

    /// The first few names, so a cleanup can be recognized.
    private var detail: String {
        let names = record.items.map(\.name)
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) and \(names.count - 3) more" : shown
    }

    private func status(_ trash: HistoryTrash) -> String {
        if trash.trashed == 0 { return record.permanent ? "Deleted permanently" : "Cleaned by tool commands" }
        if trash.pending > 0 {
            return trash.pending == trash.trashed ? "In the Trash" : "\(trash.pending) of \(trash.trashed) still in the Trash"
        }
        return record.wasPutBack ? "Put back" : "No longer in the Trash"
    }

    private func statusSymbol(_ trash: HistoryTrash) -> String {
        if trash.trashed == 0 { return "flame" }
        if trash.pending > 0 { return "arrow.uturn.backward.circle" }
        return record.wasPutBack ? "checkmark.circle" : "xmark.bin"
    }
}
