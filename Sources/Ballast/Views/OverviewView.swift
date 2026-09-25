import Charts
import SwiftUI

/// A calm storage summary: how full the disk is, what fills it, what can go.
struct OverviewView: View {
    let model: AppModel
    let open: (Pane, Int64?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                StorageSummary(model: model)

                if model.reclaimable > 0 {
                    ReadyToClean(bytes: model.reclaimable) { open(.cleanup, nil) }
                }

                AccessNotes(model: model)

                if !model.hotspots.isEmpty {
                    LargestFolders(model: model) { open(.explorer, $0) }
                }

                if model.history.count >= 2 {
                    FreeSpaceHistory(points: model.history)
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
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

extension AppModel {
    var storageSegments: [StorageSegment] {
        guard let overview else { return [] }
        let apps = overview.top.first { $0.name == "Applications" }?.total ?? 0
        let caches = total(in: .caches)
        let builds = total(in: .artifacts)
        let home = max((overview.home?.total ?? 0) - caches - builds, 0)
        let system = max(usedBytes - apps - caches - builds - home, 0)
        return [
            StorageSegment(name: "Applications", bytes: apps, color: .indigo),
            StorageSegment(name: "Your files", bytes: home, color: .blue),
            StorageSegment(name: "Caches", bytes: caches, color: .orange),
            StorageSegment(name: "Build files", bytes: builds, color: .yellow),
            StorageSegment(name: "System & other", bytes: system, color: .gray),
        ].filter { $0.bytes > 0 }
    }
}

private struct StorageSummary: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Paths.volumeName)
                        .font(.title2.weight(.semibold))
                    Text("\(model.usedBytes.bytes) of \(model.totalBytes.bytes) used")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(model.freeBytes.bytes)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(model.freeBytes)))
                    Text("available")
                        .foregroundStyle(.secondary)
                }
                .animation(.smooth(duration: 0.6), value: model.freeBytes)
            }

            StorageBar(segments: model.storageSegments, free: model.freeBytes, total: model.totalBytes)
                .frame(height: 20)

            HStack(spacing: 18) {
                ForEach(model.storageSegments) { segment in
                    HStack(spacing: 6) {
                        Circle().fill(segment.color).frame(width: 8, height: 8)
                        Text(segment.name)
                        Text(segment.bytes.bytes).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .font(.callout)
        }
    }
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
                        .frame(width: max(width * Double(segment.bytes) / Double(max(total, 1)) - 2, 2))
                        .help("\(segment.name): \(segment.bytes.bytes)")
                }
                Spacer(minLength: 0)
            }
            .frame(width: width, alignment: .leading)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .animation(.smooth(duration: 0.6), value: segments.map(\.bytes))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage")
        .accessibilityValue(segments.map { "\($0.name) \($0.bytes.bytes)" }.joined(separator: ", ") + ", \(free.bytes) free")
    }
}

// MARK: Ready to clean

private struct ReadyToClean: View {
    let bytes: Int64
    let review: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(bytes.bytes) can be cleaned safely")
                    .font(.headline)
                Text("Caches and build files that apps and tools recreate on their own.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Review", action: review)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(18)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(action, action: perform)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: Largest folders

private struct LargestFolders: View {
    let model: AppModel
    let open: (Int64) -> Void

    var body: some View {
        let spots = Array(model.hotspots.prefix(6))
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

    private var location: String {
        let parent = (spot.path as NSString).deletingLastPathComponent
        return parent == "/" ? Paths.volumeName : parent.replacingOccurrences(of: Catalog.home, with: "~")
    }

    var body: some View {
        let item = Cleaner.canRemove(spot.path) ? model.listItem(for: spot) : nil
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spot.row.name).lineLimit(1)
                Text(location)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            SizeBar(fraction: Double(spot.row.total) / Double(max(largest, 1)))
                .frame(width: 90, height: 5)
            Text(spot.row.total.bytes)
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
            ListToggle(item: item, isOn: model.isPlanned(spot.path)) {
                if let item { withAnimation(.snappy) { model.toggle(item) } }
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(hovered ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: open)
        .draggable(URL(fileURLWithPath: spot.path))
        .help("Open in Explorer · last changed \(Age.relative(spot.row.newest))")
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
                        if let bytes = value.as(Double.self) { Text(Int64(bytes).bytes) }
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
            .frame(height: 140)
        }
    }
}
