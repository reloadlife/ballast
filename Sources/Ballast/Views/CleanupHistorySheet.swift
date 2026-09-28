import SwiftUI

/// The last cleanups, newest first, with Put Back for the ones whose items
/// are still in the Trash.
struct CleanupHistorySheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Cleanup History").font(.title2.weight(.semibold))
                Text("Put Back returns what a cleanup moved to the Trash, for as long as it's still there.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            Divider()

            if model.cleanupLog.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No cleanups yet").font(.headline)
                    Text("Each cleanup is listed here, including auto-clean runs.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(spacing: 0) {
                            ForEach(Array(model.cleanupLog.reversed().enumerated()), id: \.element.id) { index, record in
                                if index > 0 { Divider().padding(.leading, 14) }
                                HistoryRow(model: model, record: record)
                            }
                        }
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

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
            HStack {
                if let status = model.status {
                    ProgressView().controlSize(.small)
                    Text(status.title).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(.bar)
        }
        .frame(width: 580, height: 520)
        .onAppear { model.reloadCleanupLog() }
    }
}

private struct HistoryRow: View {
    let model: AppModel
    let record: CleanupRecord

    var body: some View {
        let pending = record.pending.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(status(pending: pending))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(record.bytes.bytes).monospacedDigit()
                    if pending > 0 {
                        Button("Put Back") { Task { await model.putBack(record.id) } }
                            .controlSize(.small)
                            .disabled(model.isScanning)
                            .help("Move \(pending) item\(pending == 1 ? "" : "s") from the Trash back where they were")
                    }
                }
            }
            if let report = model.putBackReport, report.recordID == record.id {
                PutBackSummary(report: report)
                    .padding(.leading, 32)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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

    private func status(pending: Int) -> String {
        let trashed = record.items.flatMap(\.moves)
        if trashed.isEmpty { return record.permanent ? "Deleted permanently" : "Cleaned by tool commands" }
        if pending > 0 {
            return pending == trashed.count ? "In the Trash" : "\(pending) of \(trashed.count) still in the Trash"
        }
        return record.wasPutBack ? "Put back" : "No longer in the Trash"
    }
}
