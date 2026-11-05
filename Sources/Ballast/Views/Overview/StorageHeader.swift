import SwiftUI

/// The figures the storage header and the "can be cleaned" panel show. A
/// plain value, so the Overview can hold them for the drop moment (see
/// DropHold) and previews and snapshots can pass fake ones.
struct StorageFigures: Equatable {
    var segments: [DepthBar.Segment] = []
    var free: Int64 = 0
    var total: Int64 = 0
    var reclaimable: Int64 = 0
    var trash: Int64 = 0

    var used: Int64 { max(total - free, 0) }
}

/// The first line of an Overview: the volume's name and how much of it is
/// used at the left, free space as the screen's one hero sounding at the
/// right, the storage bar as depth bands, and a legend that wraps whole.
/// A static contour field sits behind it, never behind lists.
struct StorageHeader: View {
    let name: String
    /// "412 GB of 994 GB used", plus a format line on other drives.
    let detail: String
    /// Nil for a drive that isn't connected: there's nothing to measure.
    let free: Int64?
    let total: Int64
    let segments: [DepthBar.Segment]
    var drain: DepthBar.Drain?
    var isLow = false
    /// The System Data legend item opens what it's made of.
    var systemData: (() -> Void)?
    /// Hover text for the land band where it means something else
    /// ("Not in folders" on another drive).
    var systemNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Side by side like System Settings; stacked when the column is
            // too narrow for both on one line.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .lastTextBaseline, spacing: Theme.Space.gap) {
                    volume
                    Spacer(minLength: Theme.Space.gap)
                    hero(alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 10) {
                    volume
                    hero(alignment: .leading)
                }
            }

            if let free {
                DepthBar(segments: segments, free: free, total: total, drain: drain, height: 22)
                FlowLayout(spacing: 18, lineSpacing: 6) {
                    ForEach(segments) { segment in
                        LegendItem(segment: segment,
                                   info: segment.category == .system ? systemData : nil,
                                   note: segment.category == .system ? systemNote : nil)
                    }
                }
                .font(.callout)
            }
        }
    }

    private var volume: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Text(detail)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func hero(alignment: HorizontalAlignment) -> some View {
        if let free {
            VStack(alignment: alignment, spacing: 0) {
                Sounding(bytes: free, font: Theme.hero(),
                         style: isLow ? AnyShapeStyle(Theme.hazard) : AnyShapeStyle(.primary))
                HStack(spacing: 4) {
                    if isLow {
                        Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
                    }
                    Text(isLow ? "available, running low" : "available")
                }
                .foregroundStyle(isLow ? AnyShapeStyle(Theme.hazard) : AnyShapeStyle(.secondary))
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
    }
}

/// One band in the legend: its swatch, its name and its size, kept whole
/// when the legend wraps. System Data gets a way in when there is one.
struct LegendItem: View {
    let segment: DepthBar.Segment
    var info: (() -> Void)?
    var note: String?

    var body: some View {
        if let info {
            Button(action: info) {
                HStack(spacing: 6) {
                    content
                    Image(systemName: "info.circle").foregroundStyle(Theme.sea)
                }
            }
            .buttonStyle(.plain)
            .help("See what System Data is made of")
            .accessibilityHint("Shows what System Data is made of")
        } else {
            content
                .help(note ?? segment.category.help(bytes: segment.bytes, name: segment.name))
        }
    }

    private var content: some View {
        HStack(spacing: 6) {
            DepthSwatch(category: segment.category)
                .frame(width: 10, height: 10)
            Text(segment.name)
            Sounding(bytes: segment.bytes, font: Theme.soundingSmall, style: AnyShapeStyle(.secondary))
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// The quiet contour field behind an Overview's header: very low contrast,
/// faded out before the lists start.
struct HeaderContours: View {
    var body: some View {
        ContourField(lines: 5)
            .padding(.horizontal, -Theme.Space.pageX)
            .padding(.top, -Theme.Space.section)
            .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
            .opacity(0.8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
