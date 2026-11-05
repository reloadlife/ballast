import SwiftUI

/// "What is System Data?": every part, its size, what it is, and what (if
/// anything) you can do about it. Every load ends: the breakdown, an
/// all-clear, "scan first", or a timeout with Try Again.
struct SystemDataSheet: View {
    let model: AppModel
    let perform: (SystemDataItem.Action) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingThin = false
    @State private var phase: SystemDataPhase = .loading
    /// Bumped by Try Again, so the load runs again.
    @State private var attempt = 0
    @State private var knowledge: [String: KnowledgeExplanation] = [:]

    /// How long the layout may take before the sheet says it didn't come.
    private static let timeout: Duration = .seconds(20)

    var body: some View {
        VStack(spacing: 0) {
            SystemDataHeader(total: phase == .loaded ? model.systemData?.total : nil)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(width: 640, height: 620)
        .background(Theme.water)
        .animation(Motion.animation(Motion.state), value: phase)
        .task(id: attempt) { await load() }
        .task(id: knowledgePaths) {
            guard !knowledgePaths.isEmpty else { return }
            knowledge = await Knowledge.explainAsync(paths: knowledgePaths)
        }
        .confirmationDialog(thinTitle, isPresented: $confirmingThin) {
            Button("Delete Local Snapshots", role: .destructive) {
                Task { await model.thinLocalSnapshots() }
            }
        } message: {
            Text("These are copies of your files Time Machine keeps on this Mac between backups. Backups on your backup disk aren't affected. macOS removes as many as it can.")
        }
    }

    /// Shows what's known at once, then refreshes; gives up after a while
    /// so the sheet never waits forever.
    private func load() async {
        phase = model.systemData == nil ? .loading : model.systemDataPhase
        guard model.hasIndex else {
            phase = .notScanned
            return
        }
        let started = attempt
        Task {
            await model.loadSystemData()
            guard attempt == started else { return }
            Motion.with(Motion.state) { phase = model.systemDataPhase }
        }
        guard (try? await Task.sleep(for: Self.timeout)) != nil else { return }
        if phase == .loading { phase = .timedOut }
    }

    private var knowledgePaths: [String] {
        guard let report = model.systemData else { return [] }
        return (report.onDisk + report.hidden).compactMap(SystemDataAdvice.path(of:))
    }

    private var thinTitle: String {
        let count = (model.systemData?.snapshots ?? []).count(where: LocalSnapshots.isTimeMachine)
        return "Delete \(count) Time Machine local snapshot\(count == 1 ? "" : "s")?"
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    ChartSection(title: "On your data volume", note: "Reading the disk layout…") {
                        SkeletonRows(count: 5, showsIcon: false)
                    }
                    ChartSection(title: "Hidden macOS volumes") {
                        SkeletonRows(count: 3, showsIcon: false)
                    }
                }
                .padding(24)
            }
            .scrollDisabled(true)
            .transition(.opacity)
        case .notScanned:
            EmptyChart(symbol: "internaldrive", title: "System Data needs a scan first",
                       message: "Ballast breaks System Data down from its map of the disk. Scan this Mac from the Overview, then open this again.")
        case .timedOut:
            VStack(spacing: 0) {
                EmptyChart(symbol: "exclamationmark.circle", title: "The disk layout didn't arrive",
                           message: "macOS didn't report its volume sizes in time, usually because the disk is busy. Try again in a moment.") {
                    Button("Try Again") { attempt += 1 }
                        .buttonStyle(.glass)
                }
                accessNote.padding(.horizontal, 24)
            }
        case .empty:
            VStack(spacing: 0) {
                EmptyChart(symbol: "checkmark.circle", title: "Nothing large in System Data",
                           message: "No part of it is over 100 MB right now. It grows with caches, logs and updates; check again later.")
                accessNote.padding(.horizontal, 24)
            }
        case .loaded:
            if let report = model.systemData {
                loaded(report)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var accessNote: some View {
        if !model.hasFullDiskAccess {
            FullDiskAccessCallout()
        }
    }

    private func loaded(_ report: SystemDataReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                accessNote
                if !report.onDisk.isEmpty {
                    SystemDataGroup(title: "On your data volume",
                                    note: "Folders Ballast measured outside your home folder and Applications.",
                                    items: report.onDisk, total: report.total, knowledge: knowledge,
                                    isBusy: model.isBusyWithUserWork, perform: perform)
                }
                if !report.hidden.isEmpty {
                    SystemDataGroup(title: "Hidden macOS volumes",
                                    note: "Separate volumes macOS keeps next to your data. They count as used space but aren't folders you can open.",
                                    items: report.hidden, total: report.total, knowledge: knowledge,
                                    isBusy: model.isBusyWithUserWork, perform: perform)
                }
                if !report.snapshots.isEmpty || model.snapshotResult != nil {
                    snapshots(report.snapshots)
                }
                if report.purgeable > 1 << 30 {
                    SectionNote(symbol: "arrow.3.trianglepath",
                                text: "\(report.purgeable.bytes) is purgeable: caches macOS frees on its own when space runs low. It's already counted as available.")
                        .font(.callout)
                }
            }
            .padding(24)
        }
    }

    private func snapshots(_ names: [String]) -> some View {
        let updates = names.filter { $0.hasPrefix("com.apple.os.update") }
        let timeMachine = names.filter(LocalSnapshots.isTimeMachine)
        let dates = timeMachine.compactMap(LocalSnapshots.date).sorted(by: >)
        return ChartSection(title: "Snapshots",
                            note: "macOS doesn't report snapshot sizes; the space they hold is part of the volumes above.") {
            VStack(alignment: .leading, spacing: 10) {
                if !updates.isEmpty {
                    Label("\(updates.count) macOS update snapshot\(updates.count == 1 ? "" : "s"): kept so an update can roll back. macOS removes them itself.",
                          systemImage: "arrow.uturn.backward.circle")
                }
                if !timeMachine.isEmpty {
                    Label("\(timeMachine.count) Time Machine local snapshot\(timeMachine.count == 1 ? "" : "s"): macOS deletes them automatically when space is needed.",
                          systemImage: "clock.arrow.circlepath")
                    if !dates.isEmpty {
                        Text(dates.map { $0.formatted(date: .abbreviated, time: .shortened) }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 28)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !timeMachine.isEmpty || model.isThinningSnapshots {
                    HStack(spacing: 8) {
                        Button("Delete Local Snapshots…") { confirmingThin = true }
                            .buttonStyle(.glass)
                            .disabled(model.isThinningSnapshots)
                        if model.isThinningSnapshots {
                            DepthProgress(fraction: nil)
                                .frame(width: 80)
                            Text("Asking Time Machine…").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
                if let result = model.snapshotResult {
                    Label(result, systemImage: "info.circle")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
        }
    }
}

/// The sheet's title, one line on what it is, and the total as the one
/// figure that owns it.
struct SystemDataHeader: View {
    let total: Int64?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("System Data").font(.title2.weight(.semibold))
                Text("What macOS counts as System Data, and what you can do about it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let total {
                Sounding(bytes: total, font: Theme.hero(32))
                    .accessibilityLabel("System Data takes \(total.bytes)")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }
}
