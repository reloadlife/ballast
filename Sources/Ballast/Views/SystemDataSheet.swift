import SwiftUI

/// "What is System Data?": every part, its size, what it is, and what (if
/// anything) you can do about it.
struct SystemDataSheet: View {
    let model: AppModel
    let perform: (SystemDataItem.Action) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let report = model.systemData {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        section("On your data volume",
                                note: "Folders Ballast measured outside your home folder and Applications.",
                                items: report.onDisk, total: report.total)
                        section("Hidden macOS volumes",
                                note: "Separate volumes macOS keeps next to your data. They count as used space but aren't folders you can open.",
                                items: report.hidden, total: report.total)
                        if !report.snapshots.isEmpty { snapshots(report.snapshots) }
                        if report.purgeable > 1 << 30 {
                            Label("\(report.purgeable.bytes) is purgeable: caches macOS frees on its own when space runs low. It's already counted as available.",
                                  systemImage: "arrow.3.trianglepath")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Reading disk layout…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(.bar)
        }
        .frame(width: 620, height: 580)
        .task { await model.loadSystemData() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("System Data").font(.title2.weight(.semibold))
                Text("What macOS counts as System Data, and what you can do about it.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let report = model.systemData {
                Text(report.total.bytes)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .padding(24)
    }

    private func section(_ title: String, note: String, items: [SystemDataItem], total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(note).font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 14) }
                    row(item, total: total)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func row(_ item: SystemDataItem, total: Int64) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch item.action {
                case .explore:
                    Button("Show in Explorer") { perform(item.action) }
                        .buttonStyle(.link)
                        .font(.callout)
                case .adminScan:
                    Button("Scan as Admin…") { perform(item.action) }
                        .buttonStyle(.link)
                        .font(.callout)
                case .none:
                    EmptyView()
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 6) {
                Text(item.bytes.bytes).monospacedDigit()
                SizeBar(fraction: Double(item.bytes) / Double(max(total, 1)), tint: .gray)
                    .frame(width: 80, height: 5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func snapshots(_ names: [String]) -> some View {
        let updates = names.filter { $0.hasPrefix("com.apple.os.update") }
        let timeMachine = names.filter { $0.hasPrefix("com.apple.TimeMachine") }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Snapshots").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                if !updates.isEmpty {
                    Label("\(updates.count) macOS update snapshot\(updates.count == 1 ? "" : "s"): kept so an update can roll back. macOS removes them itself.",
                          systemImage: "arrow.uturn.backward.circle")
                }
                if !timeMachine.isEmpty {
                    Label("\(timeMachine.count) Time Machine local snapshot\(timeMachine.count == 1 ? "" : "s"): macOS deletes them automatically when space is needed.",
                          systemImage: "clock.arrow.circlepath")
                }
                Text("Snapshot sizes aren't reported by macOS; the space they hold is part of the volumes above.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}
