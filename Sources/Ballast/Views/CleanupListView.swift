import AppKit
import SwiftUI

/// The right-hand panel: collect files, folders and suggestions, then clean
/// them in one go. Every item shows whether it's safe and why.
struct CleanupListView: View {
    let model: AppModel
    @AppStorage("cleanPermanently") private var permanently = false
    @State private var cleaning = false
    @State private var confirming = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let report = model.lastClean, !cleaning {
                result(report)
            } else if cleaning {
                working
            } else if model.plan.isEmpty && model.measuring == 0 {
                emptyState
            } else {
                list
                Divider()
                footer
            }
        }
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.add(urls: urls) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button(permanently ? "Delete Permanently" : "Move to Trash", role: permanently ? .destructive : nil) {
                clean(permanently: permanently)
            }
        } message: {
            Text(permanently
                 ? "This can't be undone."
                 : "You can put things back from the Trash until you empty it.")
        }
    }

    private var confirmTitle: String {
        let count = model.readyItems.count
        let noun = count == 1 ? "item" : "items"
        return permanently
            ? "Delete \(count) \(noun) (\(model.readyBytes.bytes)) permanently?"
            : "Move \(count) \(noun) (\(model.readyBytes.bytes)) to the Trash?"
    }

    private func clean(permanently: Bool) {
        cleaning = true
        Task {
            await model.cleanPlan(permanently: permanently)
            cleaning = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cleanup List").font(.title3.weight(.semibold))
                Text(model.plan.isEmpty ? "Nothing added yet" : "\(model.plan.count) items · \(model.planBytes.bytes)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add…", systemImage: "plus") { choose() }
                .buttonStyle(.glass)
                .help("Choose files or folders to add")
            if !model.plan.isEmpty {
                Menu {
                    Button("Remove Everything from List", role: .destructive) { withAnimation(Motion.animation(.default)) { model.clearPlan() } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(14)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = "Add to List"
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await model.add(urls: urls) }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tint)
                Text("Drop files or folders here")
                    .font(.headline)
                Text("Or press \(Image(systemName: "plus.circle")) next to anything in Explorer, Suggestions or Largest folders.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Choose Files…") { choose() }
                    .buttonStyle(.glass)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Ballast checks every item so cleaning never breaks an app:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach([Safety.Level.safe, .quitFirst, .caution, .blocked], id: \.self) { level in
                    Label {
                        Text(level.title)
                    } icon: {
                        Image(systemName: level.symbol).foregroundStyle(level.color)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(16)
    }

    // MARK: List

    private var list: some View {
        let waiting = model.plan.filter { !$0.isReady }
        let ready = model.plan.filter(\.isReady)
        return List {
            // What needs a decision comes first, where it can't be missed.
            if !waiting.isEmpty {
                Section {
                    ForEach(waiting) { ListItemRow(model: model, item: $0) }
                } header: {
                    Label("Needs you", systemImage: "hand.raised").foregroundStyle(.orange)
                }
            }
            if !ready.isEmpty {
                Section {
                    ForEach(ready) { ListItemRow(model: model, item: $0) }
                } header: {
                    Label("Ready to clean", systemImage: "checkmark.shield").foregroundStyle(.secondary)
                }
            }
            if model.measuring > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring \(model.measuring) item\(model.measuring == 1 ? "" : "s")…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .animation(Motion.animation(.snappy), value: model.plan)
    }

    // MARK: Footer

    private var footer: some View {
        let ready = model.readyItems
        let waiting = model.plan.count - ready.count
        return VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $permanently) {
                Text("Move to Trash").tag(false)
                Text("Delete Now").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if waiting > 0 {
                Label("\(waiting) item\(waiting == 1 ? "" : "s") in Needs you won't be cleaned yet.",
                      systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if model.isScanning {
                Label("Waiting for the current scan to finish…", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                confirming = true
            } label: {
                Label(
                    ready.isEmpty ? "Nothing Ready to Clean"
                        : permanently ? "Delete \(model.readyBytes.bytes)" : "Clean Up \(model.readyBytes.bytes)",
                    systemImage: permanently ? "flame.fill" : "trash.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .tint(permanently ? .red : nil)
            .disabled(ready.isEmpty || model.isScanning)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(14)
    }

    // MARK: Working & result

    private var working: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().controlSize(.large)
            if let status = model.status { ScanProgressView(status: status) }
            Button("Stop") { model.cancelScan() }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    private func result(_ report: CleanReport) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: report.failures.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(report.failures.isEmpty ? .green : .orange)
                    .symbolEffect(.bounce, value: Motion.reduced ? 0 : report.freed)
                    .padding(.top, 24)
                Text(report.freed > 0 ? "Freed \(report.freed.bytes)" : "Done")
                    .font(.title.weight(.bold))
                let cleaned = report.outcomes.filter(\.succeeded).count
                Text("\(cleaned) of \(report.outcomes.count) items cleaned")
                    .foregroundStyle(.secondary)

                if report.movedToTrash > 0 {
                    VStack(spacing: 8) {
                        Text("\(report.movedToTrash.bytes) is in the Trash and still uses space until you empty it.")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Empty Trash Now", role: .destructive) {
                            cleaning = true
                            Task {
                                await model.emptyTrash()
                                cleaning = false
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                let notes = report.outcomes.compactMap(\.note)
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(notes, id: \.self) { note in
                            Label(note, systemImage: "shield.lefthalf.filled")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !report.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not cleaned").font(.headline)
                        ForEach(report.failures) { failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.item.name).font(.callout.weight(.medium))
                                Text(failure.error ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("Done") { model.dismissCleanReport() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 6)
            }
            .padding(16)
        }
    }
}

private struct ListItemRow: View {
    let model: AppModel
    let item: PlanItem
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .frame(width: 30, height: 30)
                .opacity(item.isReady ? 1 : 0.6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(item.bytes.bytes)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(item.isReady ? .primary : .secondary)
                }
                Text(item.path.replacingOccurrences(of: Catalog.home, with: "~"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Label {
                    Text(item.safety.reason).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: item.safety.level.symbol).foregroundStyle(item.safety.level.color)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                switch item.safety.level {
                case .quitFirst:
                    if let app = item.safety.app {
                        Button("Quit \(app.name)") { model.quit(app) }
                            .controlSize(.small)
                    }
                case .caution:
                    Toggle("Clean this anyway", isOn: Binding(
                        get: { item.included },
                        set: { model.setIncluded(item, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                default:
                    EmptyView()
                }
            }

            Button {
                withAnimation(Motion.animation(.default)) { model.removeFromPlan(item) }
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .opacity(hovered ? 1 : 0)
            .help("Remove from list")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Reveal in Finder") { Finder.reveal(item.path) }
            Button("Remove from List") { model.removeFromPlan(item) }
        }
    }
}
