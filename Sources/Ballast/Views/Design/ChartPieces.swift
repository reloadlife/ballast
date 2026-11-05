import SwiftUI

// MARK: Section

/// A group of rows on the chart: a ChartHeader on the water, the rows on
/// one shoal surface below it. No border, and never put one inside
/// another: nest with space and headers instead.
struct ChartSection<Trailing: View, Content: View>: View {
    let title: String
    var note: String?
    var total: Int64?
    /// Pads the rows inside the surface; lists that draw their own row
    /// insets turn it off.
    var padded = true
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChartHeader(title: title, note: note, total: total) { trailing }
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(padded ? Theme.Space.inset : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .chartSurface()
        }
        .accessibilityElement(children: .contain)
    }
}

extension ChartSection where Trailing == EmptyView {
    init(title: String, note: String? = nil, total: Int64? = nil, padded: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, note: note, total: total, padded: padded, trailing: { EmptyView() }, content: content)
    }
}

// MARK: Empty and all-clear

/// An empty or all-clear state on open water: a symbol inside a few still
/// contour rings, a plain title, one sentence that teaches what to do
/// next, and an optional action. "Nothing to clean right now".
struct EmptyChart<Action: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ContourRings()
                    .frame(width: 132, height: 96)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Theme.sea)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action
        }
        .padding(Theme.Space.section)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyChart where Action == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// A few nested, slightly irregular contour loops, like a sounding on a
/// chart. Static: drawn once per size.
private struct ContourRings: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let hairline = 1 / max(displayScale, 1)
            for ring in 1...3 {
                let scale = CGFloat(ring) / 3
                var path = Path()
                let steps = 72
                for step in 0...steps {
                    let angle = Double(step) / Double(steps) * 2 * .pi
                    let wobble = 1 + 0.06 * sin(angle * 3 + Double(ring)) + 0.03 * cos(angle * 5)
                    let point = CGPoint(x: center.x + cos(angle) * size.width / 2 * scale * wobble,
                                        y: center.y + sin(angle) * size.height / 2 * scale * wobble)
                    step == 0 ? path.move(to: point) : path.addLine(to: point)
                }
                path.closeSubpath()
                context.stroke(path, with: .color(Theme.contour), lineWidth: ring == 3 ? hairline : hairline * 1.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: Background contours

/// Soft depth contours for a screen's background (Overview, Welcome):
/// a handful of long, gently curving hairlines in Theme.contour. Drawn
/// once per size, no animation, no timers; deterministic for a seed so
/// the chart doesn't change between launches. Hidden under Increase
/// Contrast, where it would only compete with text.
struct ContourField: View {
    var lines = 6
    var seed: UInt64 = 0xBA11A57

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if contrast == .increased {
            Color.clear.accessibilityHidden(true)
        } else {
            Canvas(rendersAsynchronously: true) { context, size in
                var random = SeededRandom(seed: seed)
                let hairline = 1 / max(displayScale, 1)
                for line in 0..<lines {
                    let base = size.height * (0.15 + 0.75 * CGFloat(line) / CGFloat(max(lines - 1, 1)))
                    let amplitude = size.height * (0.02 + 0.04 * random.next())
                    let frequency = 1.2 + 1.6 * random.next()
                    let phase = random.next() * 2 * .pi
                    let tilt = (random.next() - 0.5) * size.height * 0.12
                    var path = Path()
                    let steps = max(Int(size.width / 8), 16)
                    for step in 0...steps {
                        let x = size.width * CGFloat(step) / CGFloat(steps)
                        let u = Double(step) / Double(steps)
                        let y = base + tilt * u
                            + amplitude * sin(u * frequency * 2 * .pi + phase)
                            + amplitude * 0.4 * sin(u * frequency * 5.3 * .pi + phase * 1.7)
                        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                    }
                    context.stroke(path, with: .color(Theme.contour.opacity(line.isMultiple(of: 3) ? 0.9 : 0.55)),
                                   lineWidth: hairline)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// A tiny deterministic generator (SplitMix64) so contours are stable.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    /// 0..<1
    mutating func next() -> CGFloat {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return CGFloat(z >> 11) / CGFloat(1 << 53)
    }
}

// MARK: Loading

/// Placeholder rows shaped like the list that's coming (icon, name, path,
/// size at the trailing edge), with the loading shimmer. Show only while
/// data is actually loading; swap for the rows or an EmptyChart after.
struct SkeletonRows: View {
    var count = 5
    var showsIcon = true

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<max(count, 0), id: \.self) { index in
                HStack(spacing: 10) {
                    if showsIcon {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .frame(width: 18, height: 18)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().frame(width: nameWidth(index), height: 9)
                        Capsule().frame(width: nameWidth(index) * 1.4, height: 7).opacity(0.6)
                    }
                    Spacer(minLength: 12)
                    Capsule().frame(width: 52, height: 9)
                }
                .foregroundStyle(Theme.depth[0])
                .padding(.vertical, Theme.Space.rowY)
            }
        }
        .loadingShimmer(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }

    /// Varied but stable widths, so the skeleton doesn't read as a grid.
    private func nameWidth(_ index: Int) -> CGFloat {
        [120, 168, 96, 140, 110, 150][index % 6]
    }
}

// MARK: Previews

private struct ChartPiecesPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                ChartSection(title: "Largest folders", note: "Measured at the last update.", total: 214_000_000_000) {
                    Button("Show All") {}.buttonStyle(.link)
                } content: {
                    ForEach(["Library", "Developer", "Movies"], id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            Sounding(bytes: Int64(name.count) * 9_000_000_000)
                        }
                        .padding(.vertical, Theme.Space.rowY)
                    }
                }
                ChartSection(title: "Loading") { SkeletonRows(count: 3) }
                EmptyChart(symbol: "checkmark.circle", title: "Nothing to clean right now",
                           message: "Caches and build files will show up here as apps and tools make them.") {
                    Button("Check Again") {}
                }
            }
            .padding(Theme.Space.pageX)
        }
        .frame(width: 620, height: 760)
        .background { ContourField() }
        .background(Theme.water)
    }
}

#Preview("Chart pieces · light") { ChartPiecesPreview().preferredColorScheme(.light) }
#Preview("Chart pieces · dark") { ChartPiecesPreview().preferredColorScheme(.dark) }
