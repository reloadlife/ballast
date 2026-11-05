import BallastCore
import SwiftUI

/// The storage bar drawn as depth bands: the heavier a category weighs on
/// the disk, the deeper its blue. System is land (it can't be moved), free
/// space is open water outlined by one contour hairline. Each band shows
/// its name and size on hover, and VoiceOver reads the whole bar as one
/// summary.
///
/// The drop moment: pass `BallastDrop.latest` as `drain`. Each time its
/// token changes, a piece the size of the freed bytes slides out of its
/// band into the open water and dissolves (Motion.drop). Band widths
/// animate to new values on their own. Nothing plays under Reduce Motion.
struct DepthBar: View {
    /// What a band holds, and so how deep it is drawn.
    enum Category: String, CaseIterable, Hashable, Sendable {
        case applications, yourFiles, caches, build, other, system, free

        var color: Color {
            switch self {
            case .applications: Theme.depth[4]
            case .yourFiles: Theme.depth[3]
            case .caches: Theme.depth[2]
            case .build: Theme.depth[1]
            case .other: Theme.depth[0]
            case .system: Theme.land
            case .free: Theme.water
            }
        }

        var title: String {
            switch self {
            case .applications: "Applications"
            case .yourFiles: "Your files"
            case .caches: "Caches"
            case .build: "Build files"
            case .other: "Other"
            case .system: "System Data"
            case .free: "Available"
            }
        }
    }

    struct Segment: Identifiable, Hashable, Sendable {
        let category: Category
        var name: String
        let bytes: Int64
        var id: String { name }

        init(category: Category, name: String? = nil, bytes: Int64) {
            self.category = category
            self.name = name ?? category.title
            self.bytes = bytes
        }
    }

    /// Bytes leaving the bar: `token` changes once per cleanup.
    struct Drain: Hashable, Sendable {
        var bytes: Int64
        var category: Category = .caches
        var token: Int
    }

    let segments: [Segment]
    let free: Int64
    let total: Int64
    var drain: Drain?
    var height: CGFloat = 18

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let gap: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let bands = layout(width: geo.size.width)
            ZStack(alignment: .leading) {
                Theme.water
                HStack(spacing: Self.gap) {
                    ForEach(bands, id: \.segment.id) { band in
                        Rectangle()
                            .fill(band.segment.category.color)
                            .frame(width: band.width)
                            .help(band.segment.name + ": " + band.segment.bytes.bytes)
                    }
                    Spacer(minLength: 0)
                }
                if !reduceMotion {
                    ghost(bands: bands, width: geo.size.width)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.contour, lineWidth: 1 / max(displayScale, 1)))
            .help(Category.free.title + ": " + max(free, 0).bytes)
        }
        .frame(height: height)
        .animation(Motion.animation(drain == nil ? Motion.figure : Motion.drop), value: segments.map(\.bytes))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage")
        .accessibilityValue(summary)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(Theme.Radius.bar, height / 2), style: .continuous)
    }

    /// The freed piece: always in the tree, so even the first drop has a
    /// trigger change to play on. Visible only while the keyframes run.
    private func ghost(bands: [Band], width: CGFloat) -> some View {
        let bytes = max(drain?.bytes ?? 0, 0)
        let pieceWidth = max(width * CGFloat(bytes) / CGFloat(max(total, 1)), bytes > 0 ? 3 : 0)
        let category = drain?.category ?? .caches
        // Out of the end of its band (or of the used area), into open water.
        let used = bands.reduce(0) { $0 + $1.width + Self.gap }
        let bandEnd = bands.first(where: { $0.segment.category == category }).map { band in
            bands.prefix { $0.segment.id != band.segment.id }.reduce(0) { $0 + $1.width + Self.gap } + band.width
        } ?? used
        let start = max(bandEnd - pieceWidth, 0)
        let end = min(max(used, bandEnd) + pieceWidth * 0.6, max(width - pieceWidth, 0))
        return Rectangle()
            .fill(category.color)
            .frame(width: pieceWidth)
            .keyframeAnimator(initialValue: 0.0, trigger: drain?.token ?? 0) { piece, t in
                piece
                    .offset(x: start + (end - start) * t)
                    .scaleEffect(x: 1 - 0.5 * t, anchor: .leading)
                    .blur(radius: 3 * t)
                    .opacity(t > 0 && t < 1 ? 1 - t : 0)
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(0.001)
                    CubicKeyframe(1, duration: Motion.dropDuration)
                    MoveKeyframe(0)
                }
            }
            .allowsHitTesting(false)
    }

    private struct Band {
        let segment: Segment
        let width: CGFloat
    }

    /// Proportional widths, at least 2 pt for anything that's there, scaled
    /// down together if those minimums would overflow the bar.
    private func layout(width: CGFloat) -> [Band] {
        let shown = segments.filter { $0.bytes > 0 && $0.category != .free }
        guard width > 0, !shown.isEmpty else { return [] }
        let denominator = CGFloat(max(total, 1))
        var widths = shown.map { max(width * CGFloat($0.bytes) / denominator - Self.gap, 2) }
        let room = width - Self.gap * CGFloat(shown.count - 1)
        let sum = widths.reduce(0, +)
        if sum > room, sum > 0 {
            let scale = max(room, 0) / sum
            widths = widths.map { $0 * scale }
        }
        return zip(shown, widths).map { Band(segment: $0, width: $1) }
    }

    private var summary: String {
        let parts = segments.filter { $0.bytes > 0 }.map { $0.name + " " + $0.bytes.bytes }
        return (parts + [max(free, 0).bytes + " available"]).joined(separator: ", ")
    }
}

extension StatusSnapshot.Kind {
    /// The depth band each storage category is drawn in.
    var depthCategory: DepthBar.Category {
        switch self {
        case .applications: .applications
        case .yourFiles: .yourFiles
        case .caches: .caches
        case .buildFiles: .build
        case .system: .system
        }
    }
}

extension DepthBar.Segment {
    init(_ segment: StatusSnapshot.Segment) {
        self.init(category: segment.kind.depthCategory, name: segment.kind.title, bytes: segment.bytes)
    }
}

extension DepthBar {
    /// The Overview's categories, as `StatusSnapshot.segments(...)` gives them.
    init(snapshot segments: [StatusSnapshot.Segment], free: Int64, total: Int64, drain: Drain? = nil,
         height: CGFloat = 18) {
        self.init(segments: segments.map(Segment.init), free: free, total: total, drain: drain, height: height)
    }
}

// MARK: Progress

/// A thin progress line in the chart's blues: determinate when `fraction`
/// is known, the system's indeterminate bar (tinted) when it isn't. Its
/// only motion is the work itself.
struct DepthProgress: View {
    let fraction: Double?
    var height: CGFloat = 3

    var body: some View {
        if let fraction {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.depth[0])
                    Capsule()
                        .fill(Theme.sea)
                        .frame(width: max(geo.size.width * min(max(fraction, 0), 1), height))
                }
            }
            .frame(height: height)
            .animation(Motion.animation(Motion.state), value: fraction)
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue("\(Int((min(max(fraction, 0), 1) * 100).rounded())) percent")
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Theme.sea)
                .controlSize(.small)
                .accessibilityLabel("In progress")
        }
    }
}

// MARK: Previews

private enum DepthPreview {
    static let total: Int64 = 994_000_000_000
    static let segments: [DepthBar.Segment] = [
        .init(category: .applications, bytes: 92_000_000_000),
        .init(category: .yourFiles, bytes: 310_000_000_000),
        .init(category: .caches, bytes: 48_000_000_000),
        .init(category: .build, bytes: 71_000_000_000),
        .init(category: .other, bytes: 30_000_000_000),
        .init(category: .system, bytes: 118_000_000_000),
    ]
    static var free: Int64 { total - segments.reduce(0) { $0 + $1.bytes } }

    struct Demo: View {
        @State private var token = 0
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                DepthBar(segments: segments, free: free, total: total,
                         drain: token > 0 ? .init(bytes: 40_000_000_000, token: token) : nil)
                Button("Drop 40 GB") { token += 1 }
                DepthProgress(fraction: 0.42)
                DepthProgress(fraction: nil)
            }
            .padding(24)
            .frame(width: 520)
            .background(Theme.water)
        }
    }
}

#Preview("DepthBar · light") { DepthPreview.Demo().preferredColorScheme(.light) }
#Preview("DepthBar · dark") { DepthPreview.Demo().preferredColorScheme(.dark) }
