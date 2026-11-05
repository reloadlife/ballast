import SwiftUI

/// The signature moment, "drop ballast", as a tiny coordinator that owes
/// nothing to AppModel. It plays in two truthful stages:
///
/// 1. Clean Up moved items to the Trash: `fire(moved:to: .trash, from:)`.
///    The bytes drain out of their band into the Trash band. Free space
///    didn't change, so nothing counts up and no light sweeps.
/// 2. Empty Trash, or a permanent clean: `fire(moved:to: .free, from:)`.
///    The bytes drain into open water, free space counts up, and one light
///    sweep crosses the glass panel (`freedToken`).
///
/// RootView's DropRelay fires it from each cleanup report; screens read it:
///
///     @Environment(\.ballastDrop) private var drop
///     DepthBar(segments: …, free: …, total: …, drain: drop.latest)
///     panel.lightSweep(trigger: drop.freedToken)
///
/// Every token only ever grows, so a view that appears later never replays
/// an old drop: animations run on a *change* of token, not on its value.
@MainActor
@Observable
final class BallastDrop {
    /// The one the app uses; previews and tests make their own.
    nonisolated static let shared = BallastDrop()

    /// Bumped once per drop, either stage.
    private(set) var token = 0
    /// Bumped once per stage-2 drop (space came back): drives the sweep.
    private(set) var freedToken = 0
    /// Bumped for every cleanup report, whether or not it drained anything,
    /// so a screen holding its figures for the moment knows to let go.
    private(set) var reports = 0
    /// Bytes the last drop moved.
    private(set) var moved: Int64 = 0
    /// Measured bytes the last stage-2 drop freed.
    private(set) var freed: Int64 = 0
    /// The band they came out of.
    private(set) var category: DepthBar.Category = .caches
    /// Where they went.
    private(set) var destination: DepthBar.Drain.Destination = .free
    /// When it happened, so a screen opened much later can skip the moment.
    private(set) var date: Date?

    nonisolated init() {}

    /// The last drop as DepthBar takes it; nil before the first one.
    var latest: DepthBar.Drain? {
        token > 0 ? DepthBar.Drain(bytes: moved, from: category, to: destination, token: token) : nil
    }

    /// Plays one stage wherever it's read. Nothing moved, nothing plays:
    /// the bar only drains what was measurably moved or freed. Counts as a
    /// report either way.
    func fire(moved bytes: Int64, to destination: DepthBar.Drain.Destination, from category: DepthBar.Category = .caches) {
        reports &+= 1
        guard bytes > 0 else { return }
        moved = bytes
        self.category = category
        self.destination = destination
        date = .now
        token &+= 1
        if destination == .free {
            freed = bytes
            freedToken &+= 1
        }
    }

    /// Space freed: stage 2.
    func fire(freed: Int64, category: DepthBar.Category = .caches) {
        fire(moved: freed, to: .free, from: category)
    }

    /// A cleanup report with nothing to drain (it failed, or moved nothing).
    func settle() {
        reports &+= 1
    }

    /// Plays what a report says happened. See `Stage.decide`.
    func play(_ stage: Stage?) {
        if let stage {
            fire(moved: stage.bytes, to: stage.to, from: stage.from)
        } else {
            settle()
        }
    }

    /// Which stage a cleanup report plays, from its figures alone.
    struct Stage: Equatable, Sendable {
        let bytes: Int64
        let from: DepthBar.Category
        let to: DepthBar.Drain.Destination

        /// Items moved to the Trash play stage 1, even if free space moved
        /// a little meanwhile (other apps write too). Otherwise measured
        /// free space plays stage 2: out of the Trash band when the report
        /// emptied the Trash, else out of the cleaned items' main band.
        nonisolated static func decide(movedToTrash: Int64, freed: Int64, emptiedTrash: Bool,
                                       dominant: DepthBar.Category?) -> Stage? {
            if movedToTrash > 0 {
                return Stage(bytes: movedToTrash, from: dominant ?? .caches, to: .trash)
            }
            if freed > 0 {
                return Stage(bytes: freed, from: emptiedTrash ? .trash : dominant ?? .caches, to: .free)
            }
            return nil
        }

        /// The band holding most of the bytes; ties go to the deeper band
        /// first in `DepthBar.Category.allCases`, so it's deterministic.
        nonisolated static func dominant(_ bytes: [DepthBar.Category: Int64]) -> DepthBar.Category? {
            DepthBar.Category.allCases
                .filter { (bytes[$0] ?? 0) > 0 }
                .max { (bytes[$0] ?? 0) < (bytes[$1] ?? 0) }
        }
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
    @State private var caches: Int64 = 60_000_000_000
    @State private var trash: Int64 = 0
    @State private var free: Int64 = 504_000_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DepthBar(segments: [.init(category: .applications, bytes: 80_000_000_000),
                                .init(category: .yourFiles, bytes: 240_000_000_000),
                                .init(category: .caches, bytes: caches),
                                .init(category: .system, bytes: 110_000_000_000),
                                .init(category: .trash, bytes: trash)],
                     free: free, total: 994_000_000_000, drain: drop.latest)
            HStack {
                VStack(alignment: .leading) {
                    Text("Available").font(.headline)
                    Sounding(bytes: free)
                }
                Spacer()
                Button("Clean Up 18 GB") {
                    Motion.with(Motion.drop) {
                        caches -= 18_000_000_000
                        trash += 18_000_000_000
                        drop.fire(moved: 18_000_000_000, to: .trash, from: .caches)
                    }
                }
                .disabled(caches < 18_000_000_000)
                Button("Empty Trash") {
                    Motion.with(Motion.drop) {
                        free += trash
                        drop.fire(moved: trash, to: .free, from: .trash)
                        trash = 0
                    }
                }
                .disabled(trash == 0)
            }
            .padding(Theme.Space.inset)
            .chartGlass()
            .lightSweep(trigger: drop.freedToken)
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.water)
    }
}

#Preview("Drop + sweep · light") { SweepPreview().preferredColorScheme(.light) }
#Preview("Drop + sweep · dark") { SweepPreview().preferredColorScheme(.dark) }
