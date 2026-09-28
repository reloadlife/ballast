import BallastCore
import SwiftUI
import WidgetKit

extension Int64 {
    var bytes: String { formatted(.byteCount(style: .file)) }
}

/// What the views show, resolved from an entry: the snapshot with a fresh
/// free-space reading, or just the reading when Ballast hasn't run yet.
struct Disk {
    let name: String
    let free: Int64
    let total: Int64
    let segments: [StatusSnapshot.Segment]
    let safeToClean: Int64
    let freedLastWeek: Int64
    let scannedAt: Date?
    /// When free space was read, if it isn't fresh.
    let staleSince: Date?

    init(_ entry: StatusEntry) {
        let snapshot = entry.snapshot
        name = snapshot?.volumeName ?? DiskCapacity.volumeName
        free = snapshot?.freeBytes ?? entry.volume?.free ?? 0
        total = snapshot?.totalBytes ?? entry.volume?.total ?? 0
        segments = snapshot?.segments ?? []
        safeToClean = snapshot?.safeToClean ?? 0
        freedLastWeek = snapshot?.freedLastWeek ?? 0
        scannedAt = snapshot?.scannedAt
        staleSince = entry.isLive ? nil : snapshot?.date
    }

    var used: Int64 { max(total - free, 0) }
    /// Whether the disk has been scanned, so there's a breakdown to show.
    var isMeasured: Bool { !segments.isEmpty }
}

struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let disk = Disk(entry)
        Group {
            switch family {
            case .systemSmall: SmallStatus(disk: disk)
            case .systemMedium: MediumStatus(disk: disk)
            default: LargeStatus(disk: disk)
            }
        }
        .widgetURL(DeepLink.overview)
    }
}

// MARK: Families

/// The free-space figure, a thin storage bar and what's safe to clean.
struct SmallStatus: View {
    let disk: Disk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FreeSummary(disk: disk)
            Group {
                if !disk.isMeasured {
                    Text("Open Ballast once to measure your disk.")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if disk.safeToClean > 0, disk.staleSince == nil {
                    SafeToClean(bytes: disk.safeToClean, style: .plain)
                } else {
                    Age(disk: disk)
                }
            }
            .font(.caption)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The small widget on the left; on the right, what fills the disk, every
/// category with its size, and how old that breakdown is.
struct MediumStatus: View {
    let disk: Disk

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                FreeSummary(disk: disk)
                if disk.isMeasured, disk.safeToClean > 0 {
                    SafeToClean(bytes: disk.safeToClean, style: .link)
                        .font(.caption)
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                if disk.isMeasured {
                    VStack(spacing: 4) {
                        ForEach(disk.segments, id: \.kind) { segment in
                            LegendRow(segment: segment)
                        }
                    }
                    Spacer(minLength: 4)
                    Age(disk: disk)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Spacer(minLength: 0)
                    Text("Open Ballast once to measure your disk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

/// The Overview's first screen: the headline, the storage bar, each
/// category with its size, and the week's cleanups.
struct LargeStatus: View {
    let disk: Disk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Headline(disk: disk)
            WidgetStorageBar(disk: disk, height: 16)
                .padding(.top, 12)
            if disk.isMeasured {
                VStack(spacing: 0) {
                    ForEach(Array(disk.segments.enumerated()), id: \.element.kind) { index, segment in
                        if index > 0 { Divider().padding(.leading, 16) }
                        CategoryRow(segment: segment)
                    }
                }
                .padding(.top, 8)
                Spacer(minLength: 8)
                if disk.freedLastWeek > 0 {
                    HStack {
                        Label("Freed this week", systemImage: "arrow.uturn.up")
                        Spacer()
                        Text(disk.freedLastWeek.bytes).monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                }
                Footer(disk: disk)
            } else {
                Spacer(minLength: 8)
                VStack(spacing: 4) {
                    Text("Open Ballast once to measure your disk.")
                        .font(.callout)
                    Text("Then this shows what fills it and what's safe to clean.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                Spacer(minLength: 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: Parts

/// The volume, its free space as the one big figure, "of 494 GB" and a
/// thin storage bar: the small widget, and the medium one's left half.
private struct FreeSummary: View {
    let disk: Disk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(disk.name, systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            FreeFigure(bytes: disk.free, size: 30)
            Text("free of \(disk.total.compactBytes)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            WidgetStorageBar(disk: disk, height: 6)
                .padding(.top, 9)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Macintosh HD / 410 GB of 494 GB used" on the left, the free-space figure
/// on the right, like the Overview.
private struct Headline: View {
    let disk: Disk

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(disk.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(disk.used.bytes) of \(disk.total.bytes) used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                FreeFigure(bytes: disk.free, size: 28)
                Text("available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The one rounded figure, as on the Overview.
private struct FreeFigure: View {
    let bytes: Int64
    let size: CGFloat

    var body: some View {
        Text(bytes.bytes)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText(value: Double(bytes)))
            .widgetAccentable()
    }
}

/// The Overview's storage bar: a segment per category, free space as the
/// empty track. Before a scan it shows used space as one segment.
private struct WidgetStorageBar: View {
    let disk: Disk
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 2) {
                if disk.isMeasured {
                    ForEach(disk.segments, id: \.kind) { segment in
                        Rectangle()
                            .fill(CategoryStyle(kind: segment.kind))
                            .frame(width: segmentWidth(segment.bytes, in: width))
                    }
                } else {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: segmentWidth(disk.used, in: width))
                }
                Spacer(minLength: 0)
            }
            .widgetAccentable()
            .frame(width: width, alignment: .leading)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: min(6, height / 2), style: .continuous))
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage")
        .accessibilityValue(summary)
    }

    private func segmentWidth(_ bytes: Int64, in width: CGFloat) -> CGFloat {
        let share = Double(bytes) / Double(max(disk.total, 1))
        return max(width * share - 2, 2)
    }

    private var summary: String {
        let parts = disk.segments.map { $0.kind.title + " " + $0.bytes.bytes }
        return (parts + [disk.free.bytes + " free"]).joined(separator: ", ")
    }
}

/// A category's color in full color. When the system renders the widget
/// tinted or desaturated, the categories become steps of one tone, still
/// told apart by the bar's gaps and their order.
private struct CategoryStyle: ShapeStyle {
    let kind: StatusSnapshot.Kind

    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        if environment.widgetRenderingMode == .fullColor { return AnyShapeStyle(kind.color) }
        let index = StatusSnapshot.Kind.allCases.firstIndex(of: kind) ?? 0
        return AnyShapeStyle(Color.primary.opacity([1, 0.75, 0.55, 0.4, 0.28][index]))
    }
}

private struct Dot: View {
    let kind: StatusSnapshot.Kind

    var body: some View {
        Circle().fill(CategoryStyle(kind: kind)).frame(width: 8, height: 8).widgetAccentable()
    }
}

/// A category with its rounded size, compact enough for the medium widget.
private struct LegendRow: View {
    let segment: StatusSnapshot.Segment

    var body: some View {
        HStack(spacing: 6) {
            Dot(kind: segment.kind)
            Text(segment.kind.title)
            Spacer(minLength: 6)
            Text(segment.bytes.compactBytes)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption)
        .lineLimit(1)
    }
}

private struct CategoryRow: View {
    let segment: StatusSnapshot.Segment

    var body: some View {
        HStack(spacing: 8) {
            Dot(kind: segment.kind)
            Text(segment.kind.title)
            Spacer()
            Text(segment.bytes.bytes)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.vertical, 5)
    }
}

/// "32 GB safe to clean", opening Suggestions where the widget is big
/// enough to have more than one place to tap.
private struct SafeToClean: View {
    enum Style { case plain, link }
    let bytes: Int64
    let style: Style

    var body: some View {
        switch style {
        case .plain:
            label
        case .link:
            Link(destination: DeepLink.cleanup) {
                HStack(spacing: 3) {
                    label
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var label: some View {
        Label {
            Text("\(bytes.compactBytes) safe to clean").monospacedDigit().lineLimit(1)
        } icon: {
            Image(systemName: "checkmark.shield").foregroundStyle(.tint).widgetAccentable()
        }
    }
}

/// Safe to clean on the left, how old the figures are on the right.
private struct Footer: View {
    let disk: Disk

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if disk.safeToClean > 0 {
                SafeToClean(bytes: disk.safeToClean, style: .link)
            }
            Spacer(minLength: 8)
            Age(disk: disk)
        }
        .font(.caption)
    }
}

/// "Scanned 2 days ago", kept current by the system between refreshes. If
/// free space couldn't be read just now, the figures' own age instead.
private struct Age: View {
    let disk: Disk

    var body: some View {
        Group {
            if let stale = disk.staleSince {
                Text("Updated \(relative(stale))")
            } else if let scanned = disk.scannedAt {
                Text("Scanned \(relative(scanned))")
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// "5 minutes ago", "3 hours ago", "12 days ago". Days, not weeks or
    /// months: with those allowed the style prints the week of the month
    /// ("Scanned 4") or the month's name instead.
    private func relative(_ date: Date) -> Text {
        Text(.currentDate, format: .reference(to: date, allowedFields: [.day, .hour, .minute], maxFieldCount: 1))
    }
}
