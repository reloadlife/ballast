import SwiftUI

// MARK: Motion vocabulary

/// The motion grammar for Chart Under Glass. Every value is interruptible
/// (springs), exits are faster than entrances, and `Motion.animation(_:)`
/// still turns all of it off under Reduce Motion.
extension Motion {
    /// Acknowledges a click: a toggle, a badge, a count (≈150 ms).
    static let feedback = Animation.snappy(duration: 0.16)
    /// A status or value change in place (≈260 ms).
    static let state = Animation.smooth(duration: 0.26)
    /// Layout changes, glass merging and pane switches (≈360 ms).
    static let layout = Animation.spring(duration: 0.36, bounce: 0.1)
    /// Something leaving: always quicker than it arrived.
    static let exit = Animation.easeOut(duration: 0.14)
    /// The one authored moment: ballast dropping out of the storage bar.
    static let drop = Animation.spring(duration: 0.75, bounce: 0.16)
    /// Byte figures counting to a new value.
    static let figure = Animation.smooth(duration: 0.6)

    /// Runs `body` with `animation` unless Reduce Motion is on.
    @MainActor static func with<Result>(_ animation: Animation, _ body: () throws -> Result) rethrows -> Result {
        try withAnimation(Motion.animation(animation), body)
    }
}

// MARK: Glass surfaces

extension View {
    /// A Liquid Glass panel floating over the chart: callouts, the dock,
    /// filter bars, headers. Tinted a breath toward the sea so it belongs
    /// to the chart; the system supplies the Reduce Transparency fallback.
    func chartGlass(radius: CGFloat = Theme.Radius.panel, interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.tint(Theme.sea.opacity(0.06)).interactive()
                                : .regular.tint(Theme.sea.opacity(0.06)),
                    in: .rect(cornerRadius: radius, style: .continuous))
    }

    /// A glass capsule (chips, dock items, small floating controls).
    func chartCapsule(interactive: Bool = true) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
    }

    /// Grouped content sitting on the chart (lists of rows): a shoal-tinted
    /// surface, no border, continuous corners. Never nested.
    func chartSurface(radius: CGFloat = Theme.Radius.card) -> some View {
        background(Theme.shoal, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: Buttons

/// The one opaque plate per screen: the primary action, in ink.
struct InkButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .title3.weight(.semibold) : .body.weight(.semibold))
            .foregroundStyle(Theme.onInk)
            .padding(.horizontal, large ? 22 : 16)
            .padding(.vertical, large ? 11 : 7)
            .background(Theme.ink.opacity(isEnabled ? 1 : 0.35), in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.animation(Motion.feedback), value: configuration.isPressed)
            .contentShape(.capsule)
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
    static var inkLarge: InkButtonStyle { InkButtonStyle(large: true) }
}

// MARK: Figures

/// A byte figure set as a sounding: italic, tabular, counting to new values.
struct Sounding: View {
    let bytes: Int64
    var font: Font = Theme.sounding
    var style: AnyShapeStyle = AnyShapeStyle(.primary)

    var body: some View {
        Text(bytes.bytes)
            .font(font)
            .foregroundStyle(style)
            .contentTransition(.numericText(value: Double(bytes)))
            .animation(Motion.animation(Motion.figure), value: bytes)
    }
}

// MARK: Loading

/// A calm shimmer for placeholder rows, running only while `active`
/// (loading is the one time motion without input is feedback). Reduce
/// Motion shows a static dimmed placeholder.
struct LoadingShimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .redacted(reason: active ? .placeholder : [])
            .overlay {
                if active && !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Theme.water.opacity(0.55), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.45)
                            .offset(x: phase * geo.size.width)
                    }
                    .allowsHitTesting(false)
                    .mask(content.redacted(reason: .placeholder))
                    .onAppear {
                        phase = -0.5
                        withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.2 }
                    }
                }
            }
    }
}

extension View {
    func loadingShimmer(_ active: Bool) -> some View { modifier(LoadingShimmer(active: active)) }
}

// MARK: Transitions

extension AnyTransition {
    /// Pane switches: a short blur-crossfade with a little lift, so the
    /// new screen surfaces like something coming up through water.
    static var surface: AnyTransition {
        .asymmetric(insertion: .modifier(active: SurfaceEffect(progress: 1), identity: SurfaceEffect(progress: 0)),
                    removal: .opacity.animation(Motion.exit))
    }
}

private struct SurfaceEffect: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(1 - progress)
            .blur(radius: 6 * progress)
            .offset(y: 8 * progress)
    }
}

// MARK: Section header

/// A section title on the chart: headline, an optional one-line note,
/// trailing controls, and the section's total as a sounding.
struct ChartHeader<Trailing: View>: View {
    let title: String
    var note: String?
    var total: Int64?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.gap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let note {
                    Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing
            if let total, total > 0 {
                Sounding(bytes: total, font: Theme.sounding.weight(.semibold))
            }
        }
    }
}

extension ChartHeader where Trailing == EmptyView {
    init(title: String, note: String? = nil, total: Int64? = nil) {
        self.init(title: title, note: note, total: total) { EmptyView() }
    }
}
