import BallastCore
import SwiftUI

/// The storage bar drawn as depth bands: the heavier a category weighs on
/// the disk, the deeper its blue. System is land (it can't be moved), what
/// waits in the Trash is a hatched buff-grey band beside the water (it
/// still takes space, but it's on its way out), and free space is open
/// water outlined by one contour hairline. Each band shows its name and
/// size on hover, and VoiceOver reads the whole bar as one summary.
///
/// The drop moment, in two truthful stages: pass `BallastDrop.latest` as
/// `drain`. Each time its token changes, a piece the size of the moved
/// bytes leaves its band (`from`) and either settles into the Trash band
/// (`to: .trash`, a cleanup that moved items to the Trash: no space came
/// back yet) or dissolves into open water (`to: .free`, space actually
/// freed). Band widths animate to their new values in the same spring
/// when the change arrives with the drop's transaction, otherwise with
/// Motion.figure. Under Reduce Motion the bar crossfades to its new state.
struct DepthBar: View {
    /// What a band holds, and so how deep it is drawn.
    enum Category: String, CaseIterable, Hashable, Sendable {
        case applications, yourFiles, caches, build, other, system, trash, free

        /// A flat color for the band. The Trash band is drawn hatched over
        /// this (see `DepthSwatch`); this is its base and the ghost's fill.
        var color: Color {
            switch self {
            case .applications: Theme.depth[4]
            case .yourFiles: Theme.depth[3]
            case .caches: Theme.depth[2]
            case .build: Theme.depth[1]
            case .other: Theme.depth[0]
            case .system: Theme.land
            case .trash: DepthBar.trashBase
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
            case .trash: "In Trash"
            case .free: "Available"
            }
        }

        /// Hover text for a band: what it is, and for the Trash what to do.
        func help(bytes: Int64, name: String) -> String {
            switch self {
            case .trash: "\(name): \(bytes.bytes). Still takes up space until the Trash is emptied."
            default: "\(name): \(bytes.bytes)"
            }
        }

        /// Where a cleaned path sat in the bar, by location alone (no disk
        /// access): the Trash, a suggestion's band when one is known
        /// (`suggested`), Applications, the rest of home, or System Data.
        /// Matches `StatusSnapshot.segments`: caches and build files only
        /// count as their own bands inside the home folder.
        static func of(path: String, home: String, suggested: Category? = nil) -> Category {
            let homePrefix = home.hasSuffix("/") ? home : home + "/"
            if path == homePrefix + ".Trash" || path.hasPrefix(homePrefix + ".Trash/") { return .trash }
            let inHome = path.hasPrefix(homePrefix)
            if inHome, let suggested, suggested == .caches || suggested == .build { return suggested }
            if path == "/Applications" || path.hasPrefix("/Applications/") { return .applications }
            return inHome ? .yourFiles : .system
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

    /// Bytes leaving a band: `token` changes once per drop.
    struct Drain: Hashable, Sendable {
        /// Where the piece goes: the Trash band (moved, not freed yet) or
        /// open water (space came back).
        enum Destination: Hashable, Sendable {
            case trash, free
        }

        var bytes: Int64
        /// The band the piece leaves.
        var from: Category
        var to: Destination
        var token: Int

        init(bytes: Int64, from: Category = .caches, to: Destination = .free, token: Int) {
            self.bytes = bytes
            self.from = from
            self.to = to
            self.token = token
        }
    }

    let segments: [Segment]
    let free: Int64
    let total: Int64
    var drain: Drain?
    var height: CGFloat = 18

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let gap: CGFloat = 1.5
    /// The Trash band's base: buff land washed toward grey. Theme has no
    /// token for it; it's composed from land and the blocked verdict grey.
    nonisolated static var trashBase: Color { Theme.land.opacity(0.75) }

    var body: some View {
        GeometryReader { geo in
            let bands = Self.layout(segments, total: total, width: geo.size.width)
            ZStack(alignment: .leading) {
                Theme.water
                bandRow(bands)
                    // Reduce Motion: the bar crossfades to its new state on
                    // a drop instead of draining.
                    .id(reduceMotion ? drain?.token ?? 0 : 0)
                    .transition(.opacity)
                if !reduceMotion {
                    ghost(bands: bands, width: geo.size.width)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.contour, lineWidth: 1 / max(displayScale, 1)))
            .help(Category.free.title + ": " + max(free, 0).bytes)
        }
        .frame(height: height)
        // A change that comes with the drop's transaction keeps its spring;
        // any other change (an update, a rescan) eases with Motion.figure.
        .transaction(value: segments.map(\.bytes)) { transaction in
            if transaction.animation == nil { transaction.animation = Motion.animation(Motion.figure) }
        }
        .animation(reduceMotion ? Motion.pane(reduceMotion: true) : nil, value: drain?.token)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage")
        .accessibilityValue(summary)
    }

    private func bandRow(_ bands: [Band]) -> some View {
        HStack(spacing: Self.gap) {
            ForEach(bands, id: \.segment.id) { band in
                DepthSwatch(category: band.segment.category, corner: 0)
                    .frame(width: band.width)
                    .help(band.segment.category.help(bytes: band.segment.bytes, name: band.segment.name))
            }
            Spacer(minLength: 0)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(Theme.Radius.bar, height / 2), style: .continuous)
    }

    /// The moving piece: always in the tree, so even the first drop has a
    /// trigger change to play on. Visible only while the keyframes run.
    private func ghost(bands: [Band], width: CGFloat) -> some View {
        let path = Self.ghostPath(drain: drain, bands: bands, total: total, width: width)
        let toTrash = drain?.to == .trash
        return DepthSwatch(category: drain?.from ?? .caches, corner: 0)
            .frame(width: path.width)
            .keyframeAnimator(initialValue: 0.0, trigger: drain?.token ?? 0) { piece, t in
                piece
                    .offset(x: path.start + (path.end - path.start) * t)
                    // Into the Trash it keeps its size and settles; into open
                    // water it shrinks and dissolves.
                    .scaleEffect(x: toTrash ? 1 : 1 - 0.5 * t, anchor: .leading)
                    .blur(radius: toTrash ? 0 : 3 * t)
                    .opacity(t > 0 && t < 1 ? (toTrash ? 1 - 0.6 * t : 1 - t) : 0)
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(0.001)
                    CubicKeyframe(1, duration: Motion.dropDuration)
                    MoveKeyframe(0)
                }
            }
            .allowsHitTesting(false)
    }

    struct Band: Equatable {
        let segment: Segment
        /// Leading edge in the bar.
        let x: CGFloat
        let width: CGFloat
        var end: CGFloat { x + width }
    }

    /// Proportional widths, at least 2 pt for anything that's there, scaled
    /// down together if those minimums would overflow the bar. The Trash
    /// band always sits last, against the open water.
    nonisolated static func layout(_ segments: [Segment], total: Int64, width: CGFloat) -> [Band] {
        let present = segments.filter { $0.bytes > 0 && $0.category != .free }
        let shown = present.filter { $0.category != .trash } + present.filter { $0.category == .trash }
        guard width > 0, !shown.isEmpty else { return [] }
        let denominator = CGFloat(max(total, 1))
        var widths = shown.map { max(width * CGFloat($0.bytes) / denominator - gap, 2) }
        let room = width - gap * CGFloat(shown.count - 1)
        let sum = widths.reduce(0, +)
        if sum > room, sum > 0 {
            let scale = max(room, 0) / sum
            widths = widths.map { $0 * scale }
        }
        var x: CGFloat = 0
        return zip(shown, widths).map { segment, width in
            defer { x += width + gap }
            return Band(segment: segment, x: x, width: width)
        }
    }

    /// Where the drop's piece starts and ends, in the bar's new layout.
    /// It starts where the bytes left: right after its (shrunk) band, or at
    /// the end of the used area when that band is gone (an emptied Trash).
    /// Into the Trash it lands on the Trash band's growing end; into open
    /// water it travels a little past the used area.
    nonisolated static func ghostPath(drain: Drain?, bands: [Band], total: Int64, width: CGFloat)
        -> (start: CGFloat, end: CGFloat, width: CGFloat) {
        let bytes = max(drain?.bytes ?? 0, 0)
        let piece = max(width * CGFloat(bytes) / CGFloat(max(total, 1)), bytes > 0 ? 3 : 0)
        let used = bands.last?.end ?? 0
        let source = bands.first { $0.segment.category == (drain?.from ?? .caches) }
        let start = min(max(source?.end ?? used, 0), max(width - piece, 0))
        let end: CGFloat
        switch drain?.to ?? .free {
        case .trash:
            let trashEnd = bands.first { $0.segment.category == .trash }?.end ?? used
            end = max(trashEnd - piece, 0)
        case .free:
            end = min(max(used, start) + piece * 0.6, max(width - piece, 0))
        }
        return (start, end, piece)
    }

    private var summary: String {
        let parts = segments.filter { $0.bytes > 0 }.map { $0.name + " " + $0.bytes.bytes }
        return (parts + [max(free, 0).bytes + " available"]).joined(separator: ", ")
    }
}

// MARK: Swatch

/// A band's fill, for the bar and its legend: a flat depth color, land,
/// open water with its contour, or the Trash's hatching.
struct DepthSwatch: View {
    let category: DepthBar.Category
    var corner: CGFloat = 3

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        switch category {
        case .trash:
            ZStack {
                shape.fill(DepthBar.trashBase)
                TrashHatch().clipShape(shape)
            }
        case .free:
            shape.fill(Theme.water)
                .overlay(shape.strokeBorder(Theme.contour, lineWidth: 1 / max(displayScale, 1)))
        default:
            shape.fill(category.color)
        }
    }
}

/// Diagonal hatching, drawn once per size: the Trash band reads as "on its
/// way out" by line, not hue, so it survives grayscale and Increase Contrast.
private struct TrashHatch: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 4
            let line = max(1 / max(displayScale, 1), 0.75)
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(Theme.verdictBlocked.opacity(0.7)), lineWidth: line)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: Snapshot categories

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

    /// The startup disk's bands: the snapshot's categories with what sits
    /// in the Trash carved out of Your files (the Trash is in the home
    /// folder, so the snapshot counts it there). Sums stay the same.
    nonisolated static func segments(_ snapshot: [StatusSnapshot.Segment], trash: Int64) -> [Segment] {
        var segments = snapshot.map(Segment.init)
        let trash = max(trash, 0)
        guard trash > 0, let index = segments.firstIndex(where: { $0.category == .yourFiles }) else { return segments }
        let yours = segments[index]
        let carved = min(trash, yours.bytes)
        segments[index] = Segment(category: .yourFiles, name: yours.name, bytes: yours.bytes - carved)
        segments.append(Segment(category: .trash, bytes: carved))
        return segments.filter { $0.bytes > 0 }
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

    struct Demo: View {
        @State private var caches: Int64 = 48_000_000_000
        @State private var trash: Int64 = 0
        @State private var token = 0
        @State private var drain: DepthBar.Drain?

        private var segments: [DepthBar.Segment] {
            [.init(category: .applications, bytes: 92_000_000_000),
             .init(category: .yourFiles, bytes: 310_000_000_000),
             .init(category: .caches, bytes: caches),
             .init(category: .build, bytes: 71_000_000_000),
             .init(category: .system, bytes: 118_000_000_000),
             .init(category: .trash, bytes: trash)]
        }
        private var free: Int64 { total - segments.reduce(0) { $0 + $1.bytes } }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                DepthBar(segments: segments, free: free, total: total, drain: drain)
                HStack {
                    Button("Move 30 GB to Trash") {
                        token += 1
                        Motion.with(Motion.drop) {
                            caches -= 30_000_000_000
                            trash += 30_000_000_000
                            drain = .init(bytes: 30_000_000_000, from: .caches, to: .trash, token: token)
                        }
                    }
                    .disabled(caches < 30_000_000_000)
                    Button("Empty Trash") {
                        token += 1
                        Motion.with(Motion.drop) {
                            drain = .init(bytes: trash, from: .trash, to: .free, token: token)
                            trash = 0
                        }
                    }
                    .disabled(trash == 0)
                }
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
