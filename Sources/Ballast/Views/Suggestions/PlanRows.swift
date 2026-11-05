import AppKit
import SwiftUI

// The Cleanup List's pieces, as views that take plain values so they
// render in previews and snapshot tests without AppModel.

// MARK: Groups

/// The list grouped for reading: what needs a decision first, then by
/// what kind of thing it is. Worked out when the list changes, never in
/// a body, and from the items alone, so rows don't regroup later.
struct PlanGroup: Identifiable, Equatable {
    enum Kind: Int, CaseIterable, Comparable {
        case needsYou, caches, build, apps, trash, files

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .caches: "Caches"
            case .build: "Build files"
            case .apps: "Apps"
            case .trash: "Trash"
            case .files: "Files and folders"
            }
        }

        var symbol: String {
            switch self {
            case .needsYou: "hand.raised.fill"
            case .caches: "archivebox"
            case .build: "shippingbox"
            case .apps: "xmark.app"
            case .trash: "trash"
            case .files: "folder"
            }
        }
    }

    let kind: Kind
    let items: [PlanItem]
    let bytes: Int64
    /// Items here that still wait on the user (Needs you only).
    let waiting: Int
    var id: Kind { kind }

    /// Anything that isn't plainly safe sits in Needs you, ticked or not,
    /// so ticking "I've reviewed this item" doesn't move the row.
    static func kind(of item: PlanItem) -> Kind {
        if item.safety.level != .safe { return .needsYou }
        switch item.action {
        case .uninstall: return .apps
        case .emptyTrash: return .trash
        case .command, .contents: return .caches
        case .remove:
            let name = (item.path as NSString).lastPathComponent
            if ArtifactKind.allFolderNames.contains(name) || name == "DerivedData" { return .build }
            if item.path.hasSuffix("/Caches") || item.path.contains("/Caches/") { return .caches }
            return .files
        }
    }

    /// Groups in reading order, items in the order they were added.
    static func make(_ plan: [PlanItem]) -> [PlanGroup] {
        let grouped = Dictionary(grouping: plan, by: kind(of:))
        return Kind.allCases.compactMap { kind in
            guard let items = grouped[kind], !items.isEmpty else { return nil }
            return PlanGroup(kind: kind, items: items, bytes: items.reduce(0) { $0 + $1.bytes },
                             waiting: items.filter { !$0.isReady }.count)
        }
    }
}

// MARK: Row

/// What a list row can do; each is optional so previews pass nothing.
struct PlanRowActions: Sendable {
    var quit: @MainActor @Sendable (RunningApp) -> Void = { _ in }
    var setIncluded: @MainActor @Sendable (Bool) -> Void = { _ in }
    var remove: @MainActor @Sendable () -> Void = {}
    var showInExplorer: @MainActor @Sendable () -> Void = {}
}

/// One item on the Cleanup List: what it is, its verdict as a shape, and
/// the one thing to do about it when it needs you.
struct PlanRow: View {
    let item: PlanItem
    var actions = PlanRowActions()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: Icons.icon(for: item.path))
                .resizable()
                .frame(width: 26, height: 26)
                .opacity(item.isReady ? 1 : 0.7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(homeRelative(item.path))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .uninstall(_, let data) = item.action {
                    Text(data.isEmpty ? "Always moved to the Trash."
                         : "With \(data.count) data item\(data.count == 1 ? "" : "s"). Always moved to the Trash.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    SafetyMark(level: item.safety.level)
                    Text(item.safety.reason)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                decision
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The figure ends on the list's one byte edge, the same edge
            // as the group totals; the row's tools sit under it.
            VStack(alignment: .trailing, spacing: 6) {
                ByteColumn(bytes: item.bytes, width: 70, font: Theme.soundingSmall, dimmed: !item.isReady)
                HStack(spacing: 6) {
                    WhatIsThisButton(path: item.path, level: item.safety.level)
                    Button(action: actions.remove) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from list")
                    .accessibilityLabel("Remove \(item.name) from Cleanup List")
                }
            }
        }
        .padding(.vertical, Theme.Space.rowY)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("Show in Explorer", action: actions.showInExplorer)
            Button("Show in Finder") { Finder.reveal(item.path) }
            Button("Quick Look") { QuickLook.toggle(item.path) }
            Divider()
            Button("Remove from List", action: actions.remove)
        }
    }

    /// The one decision this item waits on, if any.
    @ViewBuilder
    private var decision: some View {
        switch item.safety.level {
        case .quitFirst:
            if let app = item.safety.app {
                Button("Quit \(app.name)") { actions.quit(app) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
                    .help("Asks \(app.name) to quit; it can still ask you to save documents")
            }
        case .caution:
            Toggle("I’ve reviewed this item", isOn: Binding(get: { [included = item.included] in included }, set: { [actions] value in actions.setIncluded(value) }))
                .toggleStyle(.checkbox)
                .font(.subheadline)
                .padding(.top, 2)
                .accessibilityHint("Only reviewed items are cleaned")
        case .safe, .blocked:
            EmptyView()
        }
    }
}

/// A group's heading: its name, how many still need you, its total.
struct PlanGroupHeader: View {
    let group: PlanGroup
    /// How far rows sit inside their surface.
    static let rowInset: CGFloat = 12

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if group.kind == .needsYou {
                Label(group.kind.title, systemImage: group.kind.symbol)
                    .font(.headline)
                    .foregroundStyle(group.waiting > 0 ? AnyShapeStyle(Theme.hazard) : AnyShapeStyle(.primary))
                if group.waiting > 0 {
                    Text("\(group.waiting) waiting")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Label(group.kind.title, systemImage: group.kind.symbol)
                    .font(.headline)
                    .labelStyle(GroupLabelStyle())
            }
            Spacer(minLength: 6)
            ByteColumn(bytes: group.bytes, width: 74, font: Theme.soundingSmall.weight(.semibold))
        }
        // The rows' inset inside their surface, so totals and row figures
        // share one right edge.
        .padding(.leading, 4)
        .padding(.trailing, PlanGroupHeader.rowInset)
        .accessibilityElement(children: .combine)
    }
}

/// A heading label with a quiet icon.
private struct GroupLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(.secondary)
            configuration.title
        }
    }
}

// MARK: Working

/// What a cleanup is doing: its status, a thin progress line, and each
/// item ticking off as it's done. Value-taking; `CleaningProgress` feeds
/// it from the run's live progress.
struct CleaningProgressContent: View {
    let title: String
    /// The item being cleaned now; nil before the first and after the
    /// last (then the freed space is being measured).
    let current: Int?
    /// Every item is done and the folders are being remeasured.
    let measuring: Bool
    let items: [PlanItem]
    var stop: (() -> Void)?
    /// Off for snapshots, which can't draw a scroll view's content.
    var scrolls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .contentTransition(.opacity)
                DepthProgress(fraction: fraction)
            }
            if !items.isEmpty {
                if scrolls {
                    ScrollView { itemList }
                        .scrollBounceBehavior(.basedOnSize)
                } else {
                    itemList
                }
            } else {
                Spacer(minLength: 0)
            }
            if let stop {
                Button("Stop After This Item", action: stop)
                    .buttonStyle(.bordered)
                    .help("Finishes the item being cleaned, then stops. Everything already in the Trash can be put back.")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var itemList: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Hairline(leading: 30) }
                row(item, state: state(at: index))
            }
        }
        .padding(.horizontal, 12)
        .chartSurface(radius: Theme.Radius.row)
    }

    private enum RowState { case done, now, waiting }

    private func state(at index: Int) -> RowState {
        if measuring { return .done }
        guard let current else { return .waiting }
        return index < current ? .done : index == current ? .now : .waiting
    }

    private var fraction: Double? {
        if measuring || items.isEmpty { return nil }
        guard let current else { return nil }
        return Double(current) / Double(items.count)
    }

    private func row(_ item: PlanItem, state: RowState) -> some View {
        HStack(spacing: 10) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.sea)
                case .now:
                    ProgressView().controlSize(.small)
                case .waiting:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18, height: 18)
            Text(item.name)
                .font(.callout)
                .foregroundStyle(state == .waiting ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            ByteColumn(bytes: item.bytes, width: 70, font: Theme.soundingSmall, dimmed: state == .waiting)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .done ? "Done" : state == .now ? "Cleaning" : "Waiting")
    }
}

/// The live feed for `CleaningProgressContent`: the only view that reads
/// every progress report, so the rest of the inspector stays still.
struct CleaningProgress: View {
    let progress: ScanProgressModel
    let items: [PlanItem]
    /// Show `items` only when the run's title says it's a cleanup (for a
    /// panel reopened mid-run, which doesn't know what it started).
    var itemsFromTitle = false
    let fallbackTitle: String
    var stop: (() -> Void)?

    /// Only a cleanup or auto-clean stops after its item; Put Back,
    /// emptying the Trash and remeasuring run to the end, so a panel
    /// reopened during one of those (started from Cleanup History, say)
    /// offers no Stop that wouldn't do anything.
    nonisolated static func canStop(_ title: String?) -> Bool {
        guard let title else { return false }
        return title.hasPrefix("Cleaning") || title.hasPrefix("Auto-cleaning")
    }

    /// The furthest item seen, so remeasuring (whose paths aren't items)
    /// reads as "all done", not "back to the start".
    @State private var furthest: Int?

    var body: some View {
        let status = progress.status
        let path = status?.walk?.path
        let index = path.flatMap { path in items.firstIndex { $0.path == path } }
        let measuring = index == nil && furthest != nil
        let shows = !itemsFromTitle || (status?.title.hasPrefix("Cleaning") ?? false)
        CleaningProgressContent(title: measuring ? "Measuring the space freed" : (status?.title ?? fallbackTitle),
                                current: index ?? furthest, measuring: measuring, items: shows ? items : [],
                                stop: measuring || !Self.canStop(status?.title) ? nil : stop)
            .onChange(of: index) { _, new in
                if let new, new > (furthest ?? -1) { furthest = new }
            }
    }
}

// MARK: Result

/// What a cleanup did: the space freed as the screen's one figure, what
/// went to the Trash and what was deleted, what failed and why, and the
/// ways back (Put Back, Cleanup History).
struct CleanResultView: View {
    let report: CleanReport
    /// Whether this cleanup's items are still in the Trash; nil while
    /// that's being checked.
    let canPutBack: Bool?
    let putBackReport: PutBackReport?
    /// Another user run holds the gate: Put Back and Empty Trash wait.
    var busy = false
    var putBack: () -> Void = {}
    var emptyTrash: () -> Void = {}
    var done: () -> Void = {}
    var history: () -> Void = {}
    /// Off for snapshots, which can't draw a scroll view's content.
    var scrolls = true

    /// Counts up from zero to what was freed, once.
    @State private var shownFreed: Int64 = 0

    private var cleaned: [CleanOutcome] { report.outcomes.filter(\.succeeded) }
    private var deleted: Int64 { cleaned.filter { $0.moves.isEmpty }.reduce(0) { $0 + $1.item.bytes } }
    private var notes: [CleanOutcome] { report.outcomes.filter { $0.note != nil } }

    var body: some View {
        Group {
            if scrolls {
                ScrollView { content }
            } else {
                content
            }
        }
        .onAppear {
            Motion.with(Motion.figure) { shownFreed = report.freed }
        }
        .onChange(of: report.freed) { _, freed in
            Motion.with(Motion.figure) { shownFreed = freed }
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: Theme.Space.gap + 6) {
                hero
                tally
                if let putBackReport, putBackReport.recordID == report.record?.id {
                    PutBackSummary(report: putBackReport)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .chartSurface(radius: Theme.Radius.row)
                } else if report.movedToTrash > 0 {
                    trashActions
                }
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(notes) { outcome in
                            Label(outcome.note ?? "", systemImage: "info.circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !report.failures.isEmpty {
                    failures
                }
                VStack(spacing: 8) {
                    Button(action: done) {
                        Text("Done").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.inkLarge)
                    .keyboardShortcut(.defaultAction)
                    Button("Cleanup History", action: history)
                        .buttonStyle(.link)
                        .tint(Theme.control)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
            .padding(16)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(report.failures.isEmpty ? "Cleaned" : "Cleaned, with problems",
                  systemImage: report.failures.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(report.failures.isEmpty ? AnyShapeStyle(Theme.sea) : AnyShapeStyle(.secondary))
            if report.freed > 0 {
                Sounding(bytes: shownFreed, font: Theme.hero(40))
                Text("of space back on the disk")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No space came back yet")
                    .font(.title2.weight(.semibold))
                Text(report.movedToTrash > 0 ? "It's in the Trash until you empty it." : "The disk measured the same as before.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var tally: some View {
        VStack(spacing: 0) {
            tallyRow("Cleaned", value: "\(cleaned.count) of \(report.outcomes.count) item\(report.outcomes.count == 1 ? "" : "s")",
                     bytes: nil)
            if report.movedToTrash > 0 {
                Hairline()
                tallyRow("Moved to the Trash", value: nil, bytes: report.movedToTrash)
            }
            if deleted > 0 {
                Hairline()
                tallyRow("Deleted", value: nil, bytes: deleted)
            }
        }
        .padding(.horizontal, 12)
        .chartSurface(radius: Theme.Radius.row)
    }

    private func tallyRow(_ title: String, value: String?, bytes: Int64?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.callout)
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            if let bytes {
                ByteColumn(bytes: bytes, width: 80, font: Theme.soundingSmall)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var trashActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(report.movedToTrash.bytes) is in the Trash and still uses space until you empty it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if canPutBack == true {
                    Button("Put Back", systemImage: "arrow.uturn.backward", action: putBack)
                        .help("Move everything this cleanup put in the Trash back where it was")
                }
                Button("Empty Trash…", role: .destructive, action: emptyTrash)
                    .help("Permanently delete everything in the Trash")
            }
            .buttonStyle(.bordered)
            .disabled(busy)
        }
    }

    private var failures: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not cleaned").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(report.failures.enumerated()), id: \.element.id) { index, failure in
                    if index > 0 { Hairline(leading: 26) }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.item.name).font(.callout.weight(.medium))
                            Text(failure.error ?? "It couldn't be cleaned. Try again, or remove it in Finder.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 6)
                        ByteColumn(bytes: failure.item.bytes, width: 70, font: Theme.soundingSmall, dimmed: true)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 12)
            .chartSurface(radius: Theme.Radius.row)
            // Emptying the Trash isn't a list item, so only list items
            // that failed are still there to try again.
            if report.failures.contains(where: { $0.item.action != .emptyTrash }) {
                Text("They stay on the Cleanup List, so you can try again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// What Put Back did: how much came back, and what stayed in the Trash.
/// Draws no surface of its own; the caller places it.
struct PutBackSummary: View {
    let report: PutBackReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(report.restored > 0 ? "Put back \(report.restored) item\(report.restored == 1 ? "" : "s")" : "Nothing was put back",
                  systemImage: "arrow.uturn.backward.circle")
                .font(.callout.weight(.medium))
            ForEach(Array(report.problems.enumerated()), id: \.offset) { _, problem in
                Text(problem)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
