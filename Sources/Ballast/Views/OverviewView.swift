import BallastCore
import Charts
import SwiftUI

/// A calm storage summary: how full the disk is, what fills it, what can go.
struct OverviewView: View {
    let model: AppModel
    let open: (Pane, Int64?) -> Void
    let explore: (String) -> Void
    @State private var showingSystemData = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                StorageSummary(model: model) { showingSystemData = true }

                if model.reclaimable > 0 {
                    ReadyToClean(bytes: model.reclaimable) { open(.cleanup, nil) }
                }

                AccessNotes(model: model)

                if !model.hotspots.isEmpty {
                    LargestFolders(model: model, spots: model.hotspots) { open(.explorer, $0) }
                }

                LargestFiles(model: model, list: model.largeFiles,
                             locked: (model.overview?.lockedByPermissions ?? 0) + (model.overview?.lockedByPrivacy ?? 0),
                             rescan: model.isScanning ? nil : { Task { await model.fullScan() } })

                WhatGrew(model: model, explore: explore)

                if model.history.count >= 2 {
                    FreeSpaceHistory(points: model.history)
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingSystemData) {
            SystemDataSheet(model: model) { action in
                showingSystemData = false
                switch action {
                case .explore(let path): explore(path)
                case .adminScan: Task { await model.rescanLockedAsAdmin() }
                case .none: break
                }
            }
        }
    }
}

// MARK: Storage

/// What fills the disk, in plain categories that add up to its capacity.
struct StorageSegment: Identifiable {
    let name: String
    let bytes: Int64
    let color: Color
    var id: String { name }
}

extension StatusSnapshot.Segment {
    var storageSegment: StorageSegment {
        StorageSegment(name: kind.title, bytes: bytes, color: kind.color)
    }
}

extension AppModel {
    var storageSegments: [StorageSegment] {
        guard let overview else { return [] }
        return StatusSnapshot.segments(overview: overview, cleanup: startupCleanup, used: usedBytes).map(\.storageSegment)
    }
}

private struct StorageSummary: View {
    let model: AppModel
    let showSystemData: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Side by side like System Settings; stacked when the column is
            // too narrow for both on one line.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .lastTextBaseline) {
                    volume
                    Spacer()
                    available(alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 10) {
                    volume
                    available(alignment: .leading)
                }
            }

            StorageBar(segments: model.storageSegments, free: model.freeBytes, total: model.totalBytes)
                .frame(height: 20)

            // Items wrap whole, never one letter per line.
            FlowLayout(spacing: 18, lineSpacing: 6) {
                ForEach(model.storageSegments) { segment in
                    if segment.name == "System Data" {
                        // The opaque part gets a way in.
                        Button(action: showSystemData) {
                            legendItem(segment)
                            Image(systemName: "info.circle").foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                        .help("See what System Data is made of")
                    } else {
                        legendItem(segment)
                    }
                }
            }
            .font(.callout)
        }
    }

    private var volume: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Paths.volumeName)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Text("\(model.usedBytes.bytes) of \(model.totalBytes.bytes) used")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .fixedSize()
    }

    private func available(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(model.freeBytes.bytes)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(model.freeBytes)))
            Text("available")
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .animation(Motion.animation(.smooth(duration: 0.6)), value: model.freeBytes)
    }
}

func legendItem(_ segment: StorageSegment) -> some View {
    HStack(spacing: 6) {
        Circle().fill(segment.color).frame(width: 8, height: 8)
        Text(segment.name)
        Text(segment.bytes.bytes).foregroundStyle(.secondary).monospacedDigit()
    }
    .lineLimit(1)
    .fixedSize()
}

/// One rounded bar, like System Settings › Storage: a segment per category,
/// free space as the empty track.
struct StorageBar: View {
    let segments: [StorageSegment]
    let free: Int64
    let total: Int64

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: segmentWidth(segment, in: width))
                        .help(segment.name + ": " + segment.bytes.bytes)
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, alignment: .leading)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .animation(Motion.animation(.smooth(duration: 0.6)), value: segments.map(\.bytes))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage")
        .accessibilityValue(summary)
    }

    private func segmentWidth(_ segment: StorageSegment, in width: CGFloat) -> CGFloat {
        let share = Double(segment.bytes) / Double(max(total, 1))
        return max(width * share - 2, 2)
    }

    private var summary: String {
        let parts = segments.map { $0.name + " " + $0.bytes.bytes }
        return parts.joined(separator: ", ") + ", " + free.bytes + " free"
    }
}

// MARK: Ready to clean

struct ReadyToClean: View {
    let bytes: Int64
    var title: String?
    var detail = "Caches and build files that apps and tools recreate on their own."
    let review: () -> Void

    var body: some View {
        // The button moves under the text when they don't fit side by side.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                symbol
                message
                Spacer(minLength: 12)
                button
            }
            HStack(alignment: .top, spacing: 16) {
                symbol
                VStack(alignment: .leading, spacing: 12) {
                    message
                    button
                }
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var symbol: some View {
        Image(systemName: "checkmark.shield")
            .font(.title)
            .foregroundStyle(.tint)
            .frame(width: 36)
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title ?? "\(bytes.bytes) can be cleaned safely")
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }

    private var button: some View {
        Button("Review", action: review)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
    }
}

// MARK: Access

private struct AccessNotes: View {
    let model: AppModel

    var body: some View {
        if let overview = model.overview {
            let privacy = overview.lockedByPrivacy
            let admin = overview.lockedByPermissions
            if privacy > 0 || admin > 0 {
                VStack(spacing: 0) {
                    if privacy > 0 && !model.hasFullDiskAccess {
                        note("hand.raised", "\(privacy) folders are hidden by macOS privacy settings.",
                             "Allow Full Disk Access, then reopen Ballast.", "Open Settings") {
                            Access.openFullDiskAccessSettings()
                        }
                    } else if privacy > 0 {
                        note("arrow.clockwise", "\(privacy) folders were skipped before access was granted.",
                             "Scan them again now.", "Rescan") { Task { await model.rescanLocked() } }
                    }
                    if privacy > 0 && admin > 0 { Divider().padding(.leading, 44) }
                    if admin > 0 {
                        note("lock", "\(admin) system folders need an administrator to measure.",
                             "Ballast asks for your password once and reads only these.", "Scan as Admin…") {
                            Task { await model.rescanLockedAsAdmin() }
                        }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func note(_ symbol: String, _ title: String, _ detail: String, _ action: String,
                      perform: @escaping () -> Void) -> some View {
        let icon = Image(systemName: symbol)
            .foregroundStyle(.secondary)
            .frame(width: 20)
        let text = VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                icon
                text
                Spacer(minLength: 12)
                Button(action, action: perform)
            }
            HStack(alignment: .top, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 8) {
                    text
                    Button(action, action: perform)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: Largest folders

struct LargestFolders: View {
    let model: AppModel
    let spots: [Hotspot]
    let open: (Int64) -> Void

    var body: some View {
        let spots = Array(self.spots.prefix(6))
        let largest = spots.first?.row.total ?? 1
        VStack(alignment: .leading, spacing: 10) {
            Text("Largest folders").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(spots.enumerated()), id: \.element.id) { index, spot in
                    if index > 0 { Divider().padding(.leading, 14) }
                    FolderRow(model: model, spot: spot, largest: largest) { open(spot.row.id) }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct FolderRow: View {
    let model: AppModel
    let spot: Hotspot
    let largest: Int64
    let open: () -> Void
    @State private var hovered = false

    private var location: String { model.location(of: spot.path) }

    var body: some View {
        let item = Cleaner.canRemove(spot.path) ? model.listItem(for: spot) : nil
        HStack(spacing: 12) {
            Button(action: open) {
                FolderRowLayout(name: spot.row.name, detail: location,
                                fraction: Double(spot.row.total) / Double(max(largest, 1))) {
                    Text(spot.row.total.bytes)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(spot.row.name), \(spot.row.total.bytes), in \(location)")
            .accessibilityHint("Opens in Explorer")

            ListToggle(item: item, isOn: model.isPlanned(spot.path)) {
                if let item { withAnimation(Motion.animation(.snappy)) { model.toggle(item) } }
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(hovered ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovered = $0 }
        .draggable(URL(fileURLWithPath: spot.path))
        .help("Open in Explorer · last changed \(Age.relative(spot.row.newest))")
        .contextMenu {
            Button("Open in Explorer", action: open)
            Button("Show in Finder") { Finder.reveal(spot.path) }
            Button("Quick Look") { QuickLook.toggle(spot.path) }
            Button("Copy Path") { Finder.copy(spot.path) }
        }
    }
}

/// A folder row's text and figures: the size bar goes first when the
/// column is narrow, so the name keeps its room.
private struct FolderRowLayout<Figure: View>: View {
    let name: String
    let detail: String
    let fraction: Double
    @ViewBuilder let figure: () -> Figure

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(bar: true)
            row(bar: false)
        }
        .contentShape(Rectangle())
    }

    private func row(bar: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Measured as 160pt wide, so a long path doesn't push the bar out.
            .frame(minWidth: 0, idealWidth: 160, maxWidth: .infinity, alignment: .leading)
            if bar {
                SizeBar(fraction: fraction)
                    .frame(width: 90, height: 5)
            }
            figure()
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
    }
}

// MARK: What grew

/// "My disk was fine yesterday": the folders that grew since an earlier
/// day, from the daily record of folder sizes.
private struct WhatGrew: View {
    let model: AppModel
    let explore: (String) -> Void

    var body: some View {
        let growth = model.growth
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 12) {
                    Text("What grew").font(.headline)
                    Spacer(minLength: 8)
                    if !growth.periods.isEmpty {
                        Picker("Period", selection: Binding(get: { model.growth.period }, set: { model.growthPeriod = $0 })) {
                            ForEach(growth.periods) { Text($0.title).tag(Optional($0)) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                // Under the title, so it keeps the column's full width.
                if let caption = caption(growth) {
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            VStack(spacing: 0) {
                if let report = growth.report {
                    if report.grew.isEmpty {
                        note("checkmark.circle", "No folder grew by more than \(Growth.minimum.bytes).")
                    } else {
                        let largest = report.grew.first?.bytes ?? 1
                        ForEach(Array(report.grew.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider().padding(.leading, 14) }
                            GrowthRowView(model: model, row: row, largest: largest) { explore(row.path) }
                        }
                    }
                } else {
                    note("calendar", "Ballast needs a few days of history to show what grew. It notes folder sizes once a day from now on.")
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// The date actually compared with, whatever the period says, and what
    /// shrinking folders gave back.
    private func caption(_ growth: GrowthSummary) -> String? {
        guard let report = growth.report else { return nil }
        let since = "Since \(report.since.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
        return report.freed >= Growth.minimum ? "\(since) · \(report.freed.bytes) freed" : since
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
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct GrowthRowView: View {
    let model: AppModel
    let row: GrowthRow
    let largest: Int64
    let open: () -> Void
    @State private var hovered = false

    /// Where it is, and for a folder listed for what's left over, which
    /// listed folders inside it aren't in its figure.
    private var detail: String {
        let location = row.path == "/" ? "Across the disk"
            : (row.path as NSString).deletingLastPathComponent.replacingOccurrences(of: Catalog.home, with: "~")
        guard !row.inside.isEmpty else { return location }
        let names = row.inside.prefix(2).map { ($0 as NSString).lastPathComponent }
        let shown = names.joined(separator: ", ")
        let rest = row.insideCount > names.count ? " and \(row.insideCount - names.count) more" : ""
        return "\(location) · not counting \(shown)\(rest)"
    }

    var body: some View {
        let item = row.size.flatMap { size in
            Cleaner.canRemove(row.path) ? model.makeListItem(name: row.name, path: row.path, bytes: size) : nil
        }
        HStack(spacing: 12) {
            Button(action: open) {
                FolderRowLayout(name: row.name, detail: detail, fraction: Double(row.bytes) / Double(max(largest, 1))) {
                    Text("+\(row.bytes.bytes)")
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(row.name) grew \(row.bytes.bytes), \(detail)")
            .accessibilityHint("Opens in Explorer")

            ListToggle(item: item, isOn: model.isPlanned(row.path)) {
                if let item { withAnimation(Motion.animation(.snappy)) { model.toggle(item) } }
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(hovered ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovered = $0 }
        .draggable(URL(fileURLWithPath: row.path))
        .help(row.size.map { "Open in Explorer · \($0.bytes) now" } ?? "Open in Explorer")
        .contextMenu {
            Button("Open in Explorer", action: open)
            Button("Show in Finder") { Finder.reveal(row.path) }
            Button("Quick Look") { QuickLook.toggle(row.path) }
            Button("Copy Path") { Finder.copy(row.path) }
        }
    }
}

// MARK: History

private struct FreeSpaceHistory: View {
    let points: [HistoryPoint]

    private var spansDays: Bool {
        guard let first = points.first?.date, let last = points.last?.date else { return false }
        return last.timeIntervalSince(first) > 36 * 3600
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Free space over time").font(.headline)
                Spacer()
                let freed = points.compactMap(\.freed).reduce(0, +)
                if freed > 0 {
                    Text("\(freed.bytes) freed with Ballast")
                        .foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("Date", point.date), y: .value("Free", Double(point.free)))
                        .foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Date", point.date), y: .value("Free", Double(point.free)))
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.monotone)
                    if let freed = point.freed, freed > 0 {
                        PointMark(x: .value("Date", point.date), y: .value("Free", Double(point.free)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) { Text(bytes <= 0 ? "0 GB" : Int64(bytes).bytes) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    if spansDays {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    } else {
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
            }
            .chartXScale(range: .plotDimension(padding: 18))
            .frame(height: 140)
        }
    }
}
