import Charts
import SwiftUI

/// Rows join and leave a list with a short fade and a touch of scale;
/// leaving is quicker than arriving.
extension AnyTransition {
    static var chartRow: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                    removal: .opacity.animation(Motion.exit))
    }
}

// MARK: Largest folders

/// The folders where space really sits (no subfolder holds most of it),
/// on the startup disk or another drive.
struct LargestFoldersSection: View {
    let model: AppModel
    let spots: [Hotspot]
    let open: (Int64) -> Void
    @State private var verdicts = RowItems()

    private static let shown = 6

    var body: some View {
        let shown = Array(spots.prefix(Self.shown))
        let largest = max(shown.first?.row.total ?? 1, 1)
        ChartSection(title: "Largest folders", note: "Where the space sits: no folder inside holds most of it.",
                     padded: false) {
            VStack(spacing: 0) {
                ForEach(shown) { spot in
                    row(spot, largest: largest)
                        .transition(.chartRow)
                }
            }
            .padding(6)
            .animation(Motion.animation(Motion.state), value: shown.map(\.id))
        }
        .task(id: shown.map { RowRequest(name: $0.row.name, path: $0.path, bytes: $0.row.total, isDirectory: true) }) {
            let requests = shown.map { RowRequest(name: $0.row.name, path: $0.path, bytes: $0.row.total, isDirectory: true) }
            verdicts = await model.resolve(requests)
        }
    }

    private func row(_ spot: Hotspot, largest: Int64) -> some View {
        let location = model.location(of: spot.path)
        return ChartRow(name: spot.row.name, path: spot.path, level: verdicts.level(spot.path),
                        add: verdicts.state(spot.path, isPlanned: model.isPlanned(spot.path)),
                        action: { open(spot.row.id) },
                        toggle: { toggle(spot.path) }) {
            ChartRowText(name: spot.row.name, detail: location,
                         fraction: Double(spot.row.total) / Double(largest), bytes: spot.row.total)
        } menu: {
            Button("Open in Explorer") { open(spot.row.id) }
            Button("Show in Finder") { Finder.reveal(spot.path) }
            Button("Quick Look") { QuickLook.toggle(spot.path) }
            ProtectionNote(item: verdicts.item(spot.path), resolved: verdicts.state(spot.path, isPlanned: false))
        }
        .help("Open in Explorer · last changed \(Age.relative(spot.row.newest))")
    }

    private func toggle(_ path: String) {
        guard let item = verdicts.item(path) else { return }
        Motion.with(Motion.feedback) { model.toggle(item) }
    }
}

/// Why a row has no ⊕, in its context menu.
private struct ProtectionNote: View {
    let item: PlanItem?
    let resolved: RowAddState

    var body: some View {
        if let item, item.safety.level == .blocked {
            Divider()
            Text("Protected: \(item.safety.reason)")
        } else if item == nil, resolved == .unavailable {
            Divider()
            Text("Ballast doesn't clean this location")
        }
    }
}

// MARK: Largest files

/// The largest files of at least `LargeFiles.threshold`, with a kind
/// filter and the whole list a click away.
struct LargestFilesSection: View {
    let model: AppModel
    let list: LargeFileList
    /// Unreadable folders: their files can't be listed.
    let locked: Int
    /// Runs the full scan that fills the list, when the index predates it.
    let rescan: (() -> Void)?
    /// False while work the user started runs.
    var canRescan = true

    @State private var kind: FileKind?
    @State private var showingAll = false
    @State private var filtered: Filtered?
    @State private var verdicts = RowItems()

    private static let shown = 10

    /// The list as shown, worked out when the list or the filter changes
    /// rather than on every redraw: a full disk lists hundreds of files.
    private struct Filtered: Equatable {
        var shown: [LargeFile]
        var count: Int
        var kinds: [FileKind]
    }

    private struct Key: Equatable {
        let count: Int
        let first: Int64?
        let last: Int64?
        let isComplete: Bool
        let kind: FileKind?
    }

    private var key: Key {
        Key(count: list.files.count, first: list.files.first?.id, last: list.files.last?.id,
            isComplete: list.isComplete, kind: kind)
    }

    var body: some View {
        ChartSection(title: "Largest files", note: list.isComplete ? Self.caption(locked: locked) : nil, padded: false) {
            if list.isComplete, let filtered, !filtered.kinds.isEmpty {
                Picker("Kind", selection: $kind) {
                    Text("All Kinds").tag(FileKind?.none)
                    ForEach(filtered.kinds) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                if filtered.count > Self.shown {
                    Button("Show All") { showingAll = true }
                        .buttonStyle(.link)
                        .tint(Theme.control)
                }
            }
        } content: {
            VStack(spacing: 0) {
                if !list.isComplete {
                    ChartNote(symbol: "doc.text.magnifyingglass", text: "Largest files appear after the next full scan.",
                              action: rescan.map { ("Full Rescan", $0) }, isEnabled: canRescan)
                } else if let filtered {
                    if filtered.shown.isEmpty {
                        ChartNote(symbol: "checkmark.circle", text: Self.none(kind))
                    } else {
                        let largest = max(filtered.shown[0].bytes, 1)
                        ForEach(filtered.shown) { file in
                            row(file, largest: largest)
                                .transition(.chartRow)
                        }
                    }
                } else {
                    SkeletonRows(count: 4)
                        .padding(.horizontal, 12)
                }
            }
            .padding(6)
            .animation(Motion.animation(Motion.state), value: filtered?.shown.map(\.id))
        }
        .onChange(of: key, initial: true) { refilter() }
        .task(id: filtered?.shown.map(\.path)) {
            guard let shown = filtered?.shown, !shown.isEmpty else { return }
            verdicts = await model.resolve(shown.map {
                RowRequest(name: $0.name, path: $0.path, bytes: $0.bytes, isDirectory: false)
            })
        }
        .sheet(isPresented: $showingAll) {
            LargeFilesSheet(model: model, list: list, locked: locked, kind: kind)
        }
    }

    private func refilter() {
        let all = list.files
        let matching = kind.map { kind in all.filter { $0.kind == kind } } ?? all
        let present = Set(all.map(\.kind))
        filtered = Filtered(shown: Array(matching.prefix(Self.shown)), count: matching.count,
                            kinds: FileKind.allCases.filter(present.contains))
    }

    private func row(_ file: LargeFile, largest: Int64) -> some View {
        let detail = "\(model.location(of: file.path)) · \(Age.relative(file.modified))"
        return ChartRow(name: file.name, path: file.path, level: verdicts.level(file.path),
                        add: verdicts.state(file.path, isPlanned: model.isPlanned(file.path)),
                        showsChevron: false, accessibilityHint: "Shows a preview",
                        action: { QuickLook.toggle(file.path) },
                        toggle: { toggle(file.path) }) {
            ChartRowText(name: file.name, detail: detail,
                         fraction: Double(file.bytes) / Double(largest), bytes: file.bytes) {
                Image(nsImage: Icons.icon(for: file.path))
                    .resizable()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            }
        } menu: {
            Button("Quick Look") { QuickLook.toggle(file.path) }
            Button("Show in Finder") { Finder.reveal(file.path) }
            Button("Show in Explorer") {
                // Lands in its folder with large files shown, so it's there.
                UserDefaults.standard.set(true, forKey: "explorerShowsFiles")
                model.showInExplorer(file.path)
            }
            ProtectionNote(item: verdicts.item(file.path), resolved: verdicts.state(file.path, isPlanned: false))
        }
        .help("Quick Look · \(file.size.bytes) of data")
    }

    private func toggle(_ path: String) {
        guard let item = verdicts.item(path) else { return }
        Motion.with(Motion.feedback) { model.toggle(item) }
    }

    static var threshold: String { LargeFiles.threshold.formatted(.byteCount(style: .file)) }

    /// What's listed and, honestly, what can't be.
    static func caption(locked: Int) -> String {
        let listed = "Files of \(threshold) or more"
        guard locked > 0 else { return listed }
        return "\(listed). Files in \(locked.formatted()) locked folder\(locked == 1 ? "" : "s") aren't listed."
    }

    static func none(_ kind: FileKind?) -> String {
        guard let kind else { return "No file is \(threshold) or more." }
        return "No \(kind.title.lowercased()) of \(threshold) or more."
    }
}

// MARK: What grew

/// "My disk was fine yesterday": the folders that grew since an earlier
/// day, from the daily record of folder sizes.
struct GrowthSection: View {
    let model: AppModel
    let explore: (String) -> Void
    @State private var verdicts = RowItems()

    var body: some View {
        let growth = model.growth
        let rows = growth.report?.grew ?? []
        ChartSection(title: "What grew", note: Self.caption(growth), padded: false) {
            if !growth.periods.isEmpty {
                Picker("Period", selection: Binding(get: { model.growth.period }, set: { model.growthPeriod = $0 })) {
                    ForEach(growth.periods) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        } content: {
            VStack(spacing: 0) {
                if let report = growth.report {
                    if report.grew.isEmpty {
                        ChartNote(symbol: "checkmark.circle", text: "No folder grew by more than \(Growth.minimum.bytes).")
                    } else {
                        let largest = max(report.grew.first?.bytes ?? 1, 1)
                        ForEach(report.grew) { row in
                            self.row(row, largest: largest)
                                .transition(.chartRow)
                        }
                    }
                } else {
                    ChartNote(symbol: "calendar",
                              text: "Ballast needs a few days of history to show what grew. It notes folder sizes once a day from now on.")
                }
            }
            .padding(6)
            .animation(Motion.animation(Motion.state), value: rows.map(\.id))
        }
        .task(id: rows.map(\.path)) {
            let requests = rows.compactMap { row in
                row.size.map { RowRequest(name: row.name, path: row.path, bytes: $0, isDirectory: true) }
            }
            verdicts = await model.resolve(requests)
        }
    }

    private func row(_ row: GrowthRow, largest: Int64) -> some View {
        let detail = Self.detail(row)
        return ChartRow(name: row.name, path: row.path, level: verdicts.level(row.path),
                        add: verdicts.state(row.path, isPlanned: model.isPlanned(row.path)),
                        action: { open(row.path) },
                        toggle: { toggle(row.path) }) {
            ChartRowText(name: row.name, detail: detail, fraction: Double(row.bytes) / Double(largest),
                         bytes: row.bytes, sign: "+")
        } menu: {
            Button("Open in Explorer") { open(row.path) }
            Button("Show in Finder") { Finder.reveal(row.path) }
            Button("Quick Look") { QuickLook.toggle(row.path) }
        }
        .help(row.size.map { "Open in Explorer · \($0.bytes) now" } ?? "Open in Explorer")
    }

    private func open(_ path: String) {
        model.noteFeature(.whatGrewViewed)
        explore(path)
    }

    private func toggle(_ path: String) {
        guard let item = verdicts.item(path) else { return }
        Motion.with(Motion.feedback) { model.toggle(item) }
    }

    /// The date actually compared with, whatever the period says, and what
    /// shrinking folders gave back.
    static func caption(_ growth: GrowthSummary) -> String? {
        guard let report = growth.report else { return nil }
        let since = "Since \(report.since.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
        return report.freed >= Growth.minimum ? "\(since) · \(report.freed.bytes) freed" : since
    }

    /// Where it is, and for a folder listed for what's left over, which
    /// listed folders inside it aren't in its figure.
    static func detail(_ row: GrowthRow) -> String {
        let location = row.path == "/" ? "Across the disk"
            : (row.path as NSString).deletingLastPathComponent.replacingOccurrences(of: Catalog.home, with: "~")
        guard !row.inside.isEmpty else { return location }
        let names = row.inside.prefix(2).map { ($0 as NSString).lastPathComponent }
        let shown = names.joined(separator: ", ")
        let rest = row.insideCount > names.count ? " and \(row.insideCount - names.count) more" : ""
        return "\(location) · not counting \(shown)\(rest)"
    }
}

// MARK: Free space over time

/// Free space as a quiet depth chart; points mark cleanups that freed space.
struct HistorySection: View {
    let points: [HistoryPoint]
    @State private var summary = Summary()

    private struct Summary: Equatable {
        var freed: Int64 = 0
        var spansDays = false
    }

    private struct Key: Equatable {
        let count: Int
        let last: Date?
    }

    var body: some View {
        ChartSection(title: "Free space over time",
                     note: summary.freed > 0 ? "\(summary.freed.bytes) freed with Ballast" : nil) {
            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("Date", point.date), y: .value("Free", Double(point.free)))
                        .foregroundStyle(.linearGradient(colors: [Theme.sea.opacity(0.28), Theme.sea.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", point.date), y: .value("Free", Double(point.free)))
                        .foregroundStyle(Theme.sea)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                    if let freed = point.freed, freed > 0 {
                        PointMark(x: .value("Date", point.date), y: .value("Free", Double(point.free)))
                            .foregroundStyle(Theme.ink)
                            .symbolSize(28)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Theme.contour)
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) { Text(bytes <= 0 ? "0 GB" : Int64(bytes).bytes) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    if summary.spansDays {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    } else {
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
            }
            .chartXScale(range: .plotDimension(padding: 18))
            .frame(height: 140)
            .accessibilityLabel("Free space over time")
            .accessibilityValue(accessibilitySummary)
        }
        .onChange(of: Key(count: points.count, last: points.last?.date), initial: true) {
            let first = points.first?.date
            let last = points.last?.date
            summary = Summary(freed: points.compactMap(\.freed).reduce(0, +),
                              spansDays: first.flatMap { first in last.map { $0.timeIntervalSince(first) > 36 * 3600 } } ?? false)
        }
    }

    private var accessibilitySummary: String {
        guard let first = points.first, let last = points.last else { return "" }
        return "\(first.free.bytes) free on \(first.date.formatted(date: .abbreviated, time: .omitted)), \(last.free.bytes) now"
    }
}
