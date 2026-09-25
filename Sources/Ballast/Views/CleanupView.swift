import SwiftUI

/// Suggestions: known caches, build files and big untouched folders, each
/// one click away from the Cleanup List.
struct CleanupView: View {
    let model: AppModel
    let explore: (String) -> Void

    var body: some View {
        List {
            Section { summary }
                .listRowSeparator(.hidden)

            ForEach(Category.allCases) { category in
                let rows = model.cleanup(in: category)
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { result in
                            SuggestionRow(
                                result: result, largest: rows[0].bytes,
                                item: model.listItem(for: result),
                                planned: model.isPlanned(result.target.path),
                                toggle: { withAnimation(.snappy) { model.toggle(result) } },
                                explore: { explore(result.target.path) }
                            )
                        }
                    } header: {
                        header(category)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.reclaimable.bytes) can be cleaned safely")
                    .font(.title2.weight(.semibold))
                Text("Add items to the Cleanup List with \(Image(systemName: "plus.circle")), then press Clean Up. Nothing is removed until you do.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Add All Safe Items") {
                withAnimation(.snappy) { addSafe() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("Add every cache and build folder to the Cleanup List")
        }
        .padding(.vertical, 12)
    }

    private func header(_ category: Category) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(category.rawValue).font(.headline)
            Text(category.advice).foregroundStyle(.secondary)
            Spacer()
            if category == .artifacts {
                Button("Add Ones Older Than 3 Months") {
                    withAnimation(.snappy) { addArtifacts(olderThan: 90) }
                }
                .buttonStyle(.link)
            }
            Text(model.total(in: category).bytes)
                .font(.headline)
                .monospacedDigit()
        }
        .padding(.top, 10)
    }

    private func addSafe() {
        for result in model.cleanup where result.target.category.isReclaimable && !model.isPlanned(result.target.path) {
            if let item = model.listItem(for: result), item.safety.level != .blocked { model.toggle(item) }
        }
    }

    private func addArtifacts(olderThan days: Double) {
        let cutoff = Int64(Date.now.addingTimeInterval(-days * 86_400).timeIntervalSince1970)
        for result in model.cleanup(in: .artifacts) where result.newest < cutoff && !model.isPlanned(result.target.path) {
            model.toggle(result)
        }
    }
}

private struct SuggestionRow: View {
    let result: ScanResult
    let largest: Int64
    let item: PlanItem?
    let planned: Bool
    let toggle: () -> Void
    let explore: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            if item != nil {
                ListToggle(item: item, isOn: planned, action: toggle)
            } else {
                Image(systemName: "eye")
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)
                    .help("Review this one yourself in Explorer")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(result.target.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hovered {
                Button(action: explore) { Image(systemName: "arrow.right.circle") }
                    .buttonStyle(.borderless)
                    .help("Open in Explorer")
            }
            AgeBadge(newest: result.newest)
                .frame(width: 80, alignment: .trailing)
            SizeBar(fraction: largest > 0 ? Double(result.bytes) / Double(largest) : 0)
                .frame(width: 80, height: 5)
            Text(result.bytes.bytes)
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .draggable(URL(fileURLWithPath: result.target.path))
        .contextMenu {
            Button("Open in Explorer", action: explore)
            Button("Show in Finder") { Finder.reveal(result.target.path) }
            if let hint = result.target.hint {
                Button("Copy Command") { Finder.copy(hint) }
            }
        }
    }

    private var detail: String {
        let path = result.target.path.replacingOccurrences(of: Catalog.home, with: "~")
        if let action = result.target.action, case .command(let command) = action {
            return "\(path) · runs \(command)"
        }
        return path
    }
}
