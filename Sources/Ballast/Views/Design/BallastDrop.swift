import SwiftUI

/// The signature moment, "drop ballast", as a tiny coordinator that owes
/// nothing to AppModel. RootView fires it when a cleanup report arrives
/// with space freed; the Overview reads it:
///
///     @Environment(\.ballastDrop) private var drop
///     DepthBar(segments: …, free: …, total: …, drain: drop.latest)
///     panel.lightSweep(trigger: drop.token)
///
/// `token` only ever grows, so a view that appears later never replays an
/// old drop: animations run on a *change* of token, not on its value.
@MainActor
@Observable
final class BallastDrop {
    /// The one the app uses; previews make their own.
    nonisolated static let shared = BallastDrop()

    /// Bumped once per drop.
    private(set) var token = 0
    /// Measured bytes the last cleanup freed.
    private(set) var freed: Int64 = 0
    /// The band they came out of.
    private(set) var category: DepthBar.Category = .caches
    /// When it happened, so a screen opened much later can skip the moment.
    private(set) var date: Date?

    nonisolated init() {}

    /// The last drop as DepthBar takes it; nil before the first one.
    var latest: DepthBar.Drain? {
        token > 0 ? DepthBar.Drain(bytes: freed, category: category, token: token) : nil
    }

    /// Plays the moment wherever it's read. Does nothing for nothing freed:
    /// the bar only drains what the disk measurably got back.
    func fire(freed: Int64, category: DepthBar.Category = .caches) {
        guard freed > 0 else { return }
        self.freed = freed
        self.category = category
        date = .now
        token &+= 1
    }
}

extension EnvironmentValues {
    /// The app's drop coordinator; RootView fires it, screens read it.
    @Entry var ballastDrop: BallastDrop = .shared
}

// MARK: Light sweep

extension View {
    /// One soft band of light crossing the view, once each time `trigger`
    /// changes (never on appear, never idle). Clipped to `shape`, so it
    /// follows a glass panel's corners. Nothing under Reduce Motion.
    func lightSweep<Trigger: Equatable, S: Shape>(trigger: Trigger, in shape: S) -> some View {
        modifier(LightSweep(trigger: trigger, shape: shape))
    }

    /// The sweep clipped to a `chartGlass()` panel's corners.
    func lightSweep<Trigger: Equatable>(trigger: Trigger) -> some View {
        lightSweep(trigger: trigger, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }
}

private struct LightSweep<Trigger: Equatable, S: Shape>: ViewModifier {
    let trigger: Trigger
    let shape: S
    /// Counts trigger changes: the keyframes play on each one.
    @State private var runs = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        let width = geo.size.width
                        LinearGradient(colors: [.clear, .white.opacity(colorScheme == .dark ? 0.18 : 0.5), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(width * 0.35, 40))
                            .keyframeAnimator(initialValue: 0.0, trigger: runs) { band, t in
                                band
                                    .offset(x: -width * 0.4 + width * 1.45 * t)
                                    .opacity(t > 0 && t < 1 ? 1 : 0)
                            } keyframes: { _ in
                                KeyframeTrack {
                                    MoveKeyframe(0.001)
                                    CubicKeyframe(1, duration: Motion.sweepDuration)
                                    MoveKeyframe(0)
                                }
                            }
                    }
                    .clipShape(shape)
                    .blendMode(colorScheme == .dark ? .plusLighter : .softLight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onChange(of: trigger) {
                if !reduceMotion { runs &+= 1 }
            }
    }
}

// MARK: Preview

private struct SweepPreview: View {
    @State private var drop = BallastDrop()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DepthBar(segments: [.init(category: .applications, bytes: 80_000_000_000),
                                .init(category: .yourFiles, bytes: 240_000_000_000),
                                .init(category: .caches, bytes: 60_000_000_000),
                                .init(category: .system, bytes: 110_000_000_000)],
                     free: 504_000_000_000, total: 994_000_000_000, drain: drop.latest)
            HStack {
                VStack(alignment: .leading) {
                    Text("Can be cleaned safely").font(.headline)
                    Sounding(bytes: drop.freed)
                }
                Spacer()
                Button("Drop 18 GB") { drop.fire(freed: 18_000_000_000) }
            }
            .padding(Theme.Space.inset)
            .chartGlass()
            .lightSweep(trigger: drop.token)
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.water)
    }
}

#Preview("Drop + sweep · light") { SweepPreview().preferredColorScheme(.light) }
#Preview("Drop + sweep · dark") { SweepPreview().preferredColorScheme(.dark) }
