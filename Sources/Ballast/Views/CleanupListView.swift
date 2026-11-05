import AppKit
import SwiftUI

/// The right-hand panel: the ballast gathered from every screen, grouped,
/// each item with its verdict and the one decision it waits on, and the
/// screen's one primary action, Clean Up. While a cleanup runs it shows
/// each item ticking off; afterwards, what came back and the way back.
struct CleanupListView: View {
    let model: AppModel
    /// This cleanup's choice; starts at the default from Settings › General.
    @State private var permanently = false
    @State private var confirming = false
    @State private var confirmingEmptyTrash = false
    @State private var dropTargeted = false
    /// The list, grouped once per change of the list.
    @State private var groups: [PlanGroup] = []
    /// What this panel started and is still waiting on. The model's run
    /// state (`isCleaning`) is the source of truth; this only covers the
    /// moments around a run the model doesn't flag: stopping a background
    /// update first, and the reload after the run before its report lands.
    @State private var started: StartedRun?
    /// Whether the last report's items are still in the Trash; checked
    /// off the main thread (it looks at the disk).
    @State private var canPutBack: Bool?

    private enum StartedRun { case clean, putBack, emptyTrash }

    var body: some View {
        let phase = phase
        VStack(spacing: 0) {
            header(phase)
            Hairline()
            Group {
                switch phase {
                case .working: working
                case .result: if let report = model.lastClean { result(report) }
                case .empty: emptyState
                case .list:
                    list
                    Hairline()
                    footer
                }
            }
            .transition(.opacity.animation(Motion.animation(Motion.state)))
        }
        .animation(Motion.animation(Motion.state), value: phase)
        .background {
            if dropTargeted { Theme.sea.opacity(0.06) }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(Theme.sea, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { await model.add(urls: urls) }
            return true
        } isTargeted: { targeted in
            withAnimation(Motion.animation(Motion.feedback)) { dropTargeted = targeted }
        }
        .onAppear { permanently = model.preferences.deletePermanentlyByDefault }
        .onChange(of: model.preferences.deletePermanentlyByDefault) { permanently = $1 }
        .onChange(of: model.plan, initial: true) { _, plan in
            let next = PlanGroup.make(plan)
            guard next != groups else { return }
            if groups.isEmpty {
                groups = next
            } else {
                Motion.with(Motion.layout) { groups = next }
            }
        }
        .task(id: model.lastClean?.record?.id) {
            canPutBack = nil
            guard let record = model.lastClean?.record else { return }
            canPutBack = await Task.detached(priority: .userInitiated) { record.canPutBack }.value
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button(permanently ? "Delete Permanently" : "Move to Trash", role: permanently ? .destructive : nil) {
                start(.clean) { await model.cleanPlan(permanently: permanently) }
            }
        } message: {
            Text(permanently
                 ? "This can't be undone.\(hasUninstalls ? " Apps still go to the Trash, with their data." : "")"
                 : "You can put things back from Cleanup History until you empty the Trash.")
        }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmingEmptyTrash) {
            Button("Empty Trash", role: .destructive) {
                start(.emptyTrash) { await model.emptyTrash() }
            }
        } message: {
            Text("Everything in the Trash is deleted permanently, including what you put there yourself. This can't be undone.")
        }
    }

    private var phase: CleanupPhase {
        if model.isCleaningObserved || started != nil { return .working }
        if model.lastClean != nil { return .result }
        if model.plan.isEmpty && model.measuring == 0 { return .empty }
        return .list
    }

    /// Runs `work` and covers the moments around it (see `started`).
    private func start(_ run: StartedRun, _ work: @escaping @MainActor () async -> Void) {
        started = run
        Task {
            await work()
            started = nil
            if run == .clean { permanently = model.preferences.deletePermanentlyByDefault }
        }
    }

    private var hasUninstalls: Bool { model.readyItems.contains { $0.action.isAlwaysTrashed } }

    /// Where the choice is made, what it means for getting things back.
    private var undoNote: String {
        if permanently {
            return "Deleting permanently can't be undone.\(hasUninstalls ? " Apps still go to the Trash." : "")"
        }
        let commands = model.readyItems.contains { if case .command = $0.action { true } else { false } }
        return commands
            ? "Put Back returns everything but what tool commands clean, until you empty the Trash."
            : "Put Back returns everything until you empty the Trash."
    }

    private var confirmTitle: String {
        let count = model.readyItems.count
        let noun = count == 1 ? "item" : "items"
        return permanently
            ? "Delete \(count) \(noun) (\(model.readyBytes.bytes)) permanently?"
            : "Move \(count) \(noun) (\(model.readyBytes.bytes)) to the Trash?"
    }

    // MARK: Header

    private func header(_ phase: CleanupPhase) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cleanup List").font(.title3.weight(.semibold))
                    Text(summaryLine)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button("Add…", systemImage: "plus") { choose() }
                    .buttonStyle(.bordered)
                    .disabled(phase == .working)
                    .help("Choose files or folders to add")
                if !model.plan.isEmpty && phase == .list {
                    Menu {
                        Button("Remove Everything from List", role: .destructive) {
                            Motion.with(Motion.exit) { model.clearPlan() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More")
                }
            }
            if phase == .list && model.readyBytes > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    Sounding(bytes: model.readyBytes, font: Theme.hero(34))
                    Text("ready to clean")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
        }
        .padding(14)
    }

    private var summaryLine: String {
        guard !model.plan.isEmpty else {
            return model.measuring > 0 ? "Measuring \(model.measuring) item\(model.measuring == 1 ? "" : "s")…" : "Nothing added yet"
        }
        let count = model.plan.count
        let waiting = count - model.readyItems.count
        let items = "\(count) item\(count == 1 ? "" : "s") · \(model.planBytes.bytes)"
        return waiting > 0 ? "\(items) · \(waiting) need\(waiting == 1 ? "s" : "") you" : items
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
        ScrollView {
            VStack(spacing: 8) {
                EmptyChart(symbol: "tray.and.arrow.down", title: "Drop files or folders here",
                           message: "Or press the plus button next to anything in Explorer, Suggestions or Largest folders.") {
                    Button("Choose Files…") { choose() }
                        .buttonStyle(.bordered)
                }
                VerdictLegend()
                    .padding(.horizontal, 16)
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.gap + 6) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        PlanGroupHeader(group: group)
                        VStack(spacing: 0) {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                VStack(spacing: 0) {
                                    if index > 0 { Hairline(leading: 36) }
                                    PlanRow(item: item, actions: actions(for: item))
                                }
                                .transition(.row)
                            }
                        }
                        .padding(.horizontal, 12)
                        .chartSurface(radius: Theme.Radius.row)
                    }
                    .transition(.row)
                }
                if model.measuring > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Measuring \(model.measuring) item\(model.measuring == 1 ? "" : "s")")
                            .font(.headline)
                            .padding(.horizontal, 4)
                        SkeletonRows(count: min(model.measuring, 4))
                            .padding(.horizontal, 12)
                            .chartSurface(radius: Theme.Radius.row)
                    }
                    .transition(.row)
                }
            }
            .padding(14)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func actions(for item: PlanItem) -> PlanRowActions {
        PlanRowActions(
            quit: { app in model.quit(app) },
            setIncluded: { included in Motion.with(Motion.feedback) { model.setIncluded(item, included) } },
            remove: { Motion.with(Motion.exit) { model.removeFromPlan(item) } },
            showInExplorer: { model.showInExplorer(item.path) }
        )
    }

    // MARK: Footer

    private var footer: some View {
        let ready = model.readyItems
        let waiting = model.plan.count - ready.count
        let busy = model.isBusyWithUserWork
        return VStack(alignment: .leading, spacing: 10) {
            Picker("When cleaning", selection: $permanently) {
                Text("Move to Trash").tag(false)
                Text("Delete Now").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(undoNote)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if waiting > 0 {
                Label("\(waiting) item\(waiting == 1 ? "" : "s") in Needs you won't be cleaned yet.",
                      systemImage: "hand.raised.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.hazard)
            }
            if busy {
                BusyNote(progress: model.scanProgress)
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
            .buttonStyle(.inkLarge)
            .disabled(ready.isEmpty || busy)
            .keyboardShortcut(.return, modifiers: .command)
            .help(permanently ? "Delete the ready items permanently" : "Move the ready items to the Trash")
        }
        .padding(14)
    }

    // MARK: Working & result

    private var working: some View {
        CleaningProgress(
            progress: model.scanProgress,
            items: started == .putBack || started == .emptyTrash ? [] : model.readyItems,
            // Reopened mid-run: the run's own title says whether it's a cleanup.
            itemsFromTitle: started == nil,
            fallbackTitle: fallbackTitle,
            // Put Back and emptying the Trash can't stop halfway.
            stop: started == .putBack || started == .emptyTrash || !model.isCleaningObserved ? nil : { model.cancelScan() }
        )
    }

    private var fallbackTitle: String {
        switch started {
        case .clean?: model.isCleaningObserved ? "Cleaning" : "Getting ready to clean"
        case .putBack?: "Putting back"
        case .emptyTrash?: "Emptying the Trash"
        case nil: "Cleaning"
        }
    }

    private func result(_ report: CleanReport) -> some View {
        CleanResultView(
            report: report,
            canPutBack: canPutBack,
            putBackReport: model.putBackReport,
            busy: model.isBusyWithUserWork,
            putBack: {
                guard let record = report.record else { return }
                start(.putBack) { await model.putBack(record.id) }
            },
            emptyTrash: { confirmingEmptyTrash = true },
            done: { Motion.with(Motion.state) { model.dismissCleanReport() } },
            history: { model.isHistoryShown = true }
        )
    }
}

/// The four verdicts, by shape, for the empty list.
struct VerdictLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ballast checks every item so cleaning never breaks an app:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach([Safety.Level.safe, .quitFirst, .caution, .blocked], id: \.self) { level in
                // A fixed mark column, so the titles line up whatever the
                // symbol's width.
                HStack(spacing: 8) {
                    SafetyMark(level: level)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text(level.title)
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Why Clean Up waits, read from the running job's live progress so only
/// this line redraws as it changes.
private struct BusyNote: View {
    let progress: ScanProgressModel

    var body: some View {
        let title = progress.status.map { $0.title.prefix(1).lowercased() + $0.title.dropFirst() } ?? "the current task"
        Label("Clean Up is available once \(title) finishes.", systemImage: "hourglass")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}
