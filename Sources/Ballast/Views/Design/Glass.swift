import SwiftUI

// MARK: - Component guide (Chart Under Glass)
//
// Use these instead of rebuilding a look per screen. Tokens are in
// Theme.swift (water, shoal, land, contour, depth[0...4], sea, ink, onInk,
// hazard, verdict*, sounding fonts, Radius, Space).
//
// Motion (Components.swift + below)
//   Motion.feedback / .state / .layout / .exit / .drop / .figure
//       The only animation values. Wrap with Motion.animation(_:) or
//       Motion.with(_:_:) so Reduce Motion turns them off.
//   Motion.pane(reduceMotion:) + AnyTransition.pane(reduceMotion:)
//       Pane and large content swaps: blur-crossfade, plain crossfade under
//       Reduce Motion (the one motion Reduce Motion keeps).
//   .lightSweep(trigger:)          One gradient sweep across a glass panel
//       each time `trigger` changes (BallastDrop.token after a cleanup).
//       Never idle; nothing under Reduce Motion.
//
// Surfaces (this file)
//   .chartGlass()                  Floating content tools: callouts, filter
//       bars, the "can be cleaned safely" panel. Never on stock chrome
//       (sidebar, toolbar, inspector) and never glass on glass.
//   .chartCapsule()                Small floating glass chips and controls.
//   .chartSurface()                Grouped rows sitting on the water. No
//       border, never nested. ChartSection wraps it with a ChartHeader.
//   ChartHeader(title:note:total:) Section title, one-line note, trailing
//       controls, the section's total as a Sounding.
//   ChartSection(title:note:total:trailing:content:)  (ChartPieces.swift)
//       Header on the water, rows on a chartSurface below it.
//
// Actions
//   .buttonStyle(.ink / .inkLarge) The one opaque plate per screen: that
//       screen's primary action only. Everything else is glass or plain;
//       inside a glass panel, secondary buttons are .bordered (never glass
//       on glass). While the Cleanup List holds the window's primary
//       action, RootView sets \.inkYields and detail plates step down.
//   .tint(Theme.control)           Set once per scene: system controls
//       take the chart's blue, never the system accent.
//
// Figures and data
//   Sounding(bytes:)               Every byte figure: italic, tabular,
//       right-aligned to one column edge per list, counts to new values.
//   DepthBar(segments:free:total:drain:)  (DepthBar.swift) The storage
//       bar as depth bands; System is land, free space is open water.
//       Pass BallastDrop.latest as `drain` to play the drop moment.
//   DepthProgress(fraction:)       (DepthBar.swift) Thin depth-tinted
//       progress line; nil fraction = indeterminate.
//   SizeBar(fraction:tint:)        (Components.swift) A row's share bar.
//   ScanProgressView(status:fraction:showsBar:)  (Components.swift) Quiet
//       scan status: title, optional thin bar, counts, current path.
//
// Safety
//   SafetyMark(level:)             (SafetyMark.swift) A verdict as a shape:
//       safe = checkmark circle, quit first = pause rectangle, caution =
//       triangle, protected = lock. Color is only the second cue, never
//       magenta. Safety.Level.symbol / .color / .title use the same shapes.
//   WhatIsThisButton(path:)        (WhatIsThis.swift) Info button with a
//       popover explaining a location from the knowledge base.
//   Theme.hazard (magenta)         Only hazards the user can act on (low
//       space, items that need a decision). Never decoration, never safety.
//
// States
//   SkeletonRows(count:)           (ChartPieces.swift) Placeholder rows
//       with the loading shimmer, only while data is actually loading.
//   .loadingShimmer(_:)            The shimmer itself, for custom skeletons.
//   EmptyChart(symbol:title:message:action:)  (ChartPieces.swift) All
//       clear / empty states on open water with a static contour motif.
//   ContourField()                 (ChartPieces.swift) Static, very quiet
//       contour lines for a screen background (Overview, Welcome). Drawn
//       once; hidden under Increase Contrast.
//
// Shell (RootView.swift + BallastDock.swift + BallastDrop.swift)
//   BallastDock                    The floating glass dock showing the
//       Cleanup List; RootView places it, screens don't.
//   BallastDrop / @Environment(\.ballastDrop)  Fires after a cleanup frees
//       space: `latest` (a DepthBar.Drain) feeds DepthBar, `token` feeds
//       .lightSweep(trigger:). RootView fires it; screens only read it.
//   AnyTransition.surface          Blur-crossfade for pane switches.

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
    /// The loading shimmer's pass across a placeholder, repeated only
    /// while the data is actually loading.
    static let shimmer = Animation.linear(duration: 1.3).repeatForever(autoreverses: false)

    /// How long the drop moment and the light sweep take, for keyframes
    /// (which take durations, not `Animation`s).
    static let dropDuration: Double = 0.75
    static let sweepDuration: Double = 0.8

    /// Pane switches and other whole-content swaps. Reduce Motion keeps a
    /// short crossfade: the one motion it allows, since nothing moves.
    static func pane(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : layout
    }

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

extension EnvironmentValues {
    /// True while another column holds the window's primary action (the
    /// Cleanup List's Clean Up, with items ready): ink plates here step
    /// down to a quiet shoal capsule, so the window shows one plate.
    @Entry var inkYields = false
}

/// The one opaque plate per screen: the primary action, in ink. Steps
/// down to a shoal capsule under `\.inkYields`.
struct InkButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.inkYields) private var yields

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .title3.weight(.semibold) : .body.weight(.semibold))
            .foregroundStyle(yields ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.onInk))
            .padding(.horizontal, large ? 22 : 16)
            .padding(.vertical, large ? 11 : 7)
            .background(yields ? Theme.depth[0] : Theme.ink.opacity(isEnabled ? 1 : 0.35), in: .capsule)
            .opacity(yields && !isEnabled ? 0.5 : 1)
            .animation(Motion.animation(Motion.state), value: yields)
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
                        Motion.with(Motion.shimmer) { phase = 1.2 }
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

extension AnyTransition {
    /// The pane transition: `.surface`, or a plain crossfade under Reduce
    /// Motion. Pair with `Motion.pane(reduceMotion:)`.
    static func pane(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .surface
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

    /// One row when the title, controls and total fit side by side; in a
    /// narrow window the controls drop below the title instead of
    /// squeezing the note into a column one word wide.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.gap) {
                heading.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                trailing
                figure
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.gap) {
                    heading
                    Spacer(minLength: 8)
                    figure
                }
                trailing
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    @ViewBuilder private var figure: some View {
        if let total, total > 0 {
            Sounding(bytes: total, font: Theme.sounding.weight(.semibold))
        }
    }
}

extension ChartHeader where Trailing == EmptyView {
    init(title: String, note: String? = nil, total: Int64? = nil) {
        self.init(title: title, note: note, total: total) { EmptyView() }
    }
}
