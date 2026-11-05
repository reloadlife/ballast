import SwiftUI

/// When the Overview holds the figures it shows, so the drop moment plays
/// as one: free space counting up, the bands moving and the piece
/// draining all start in the same frame.
///
/// Why it's needed: a cleanup ends its run, reads free space (the hero
/// would count up), reloads the index (the bands would move) and only then
/// posts its report (which fires the drop). On a large index that's a
/// second or more apart. So from the moment a cleanup starts, the Overview
/// keeps showing the figures from just before it, and lets go when:
/// - the report arrives (with the drop, or quietly when nothing moved),
/// - another run (an update, a scan) starts, so it never shows old figures
///   while something else changes the disk, or
/// - `grace` passes after the run ended without a report (it was stopped
///   before the first item, or failed).
/// Nothing changes on the disk meanwhile that the index would show: during
/// a run the figures only change once it ends. A plain value, for tests.
struct DropHold: Equatable, Sendable {
    enum Release: Equatable, Sendable {
        /// A drop came with the report: release in its spring.
        case drop
        /// Nothing to drain: ease to the current figures.
        case quiet
    }

    static let grace: Duration = .seconds(6)

    private(set) var isHolding = false
    /// The drop token when the hold began; a different one at the report
    /// means the report drained something.
    private(set) var startToken = 0
    private(set) var runEnded = false

    /// Waiting on the grace period, for a report that may never come.
    var waitsForTimeout: Bool { isHolding && runEnded }

    /// A cleanup (Clean Up, Empty Trash) started moving files.
    mutating func cleanupStarted(token: Int) {
        if !isHolding {
            isHolding = true
            startToken = token
        }
        runEnded = false
    }

    /// A run started. Only another cleanup keeps the hold.
    mutating func runStarted(isCleanup: Bool) -> Release? {
        guard isHolding, !isCleanup else { return nil }
        return end(.quiet)
    }

    mutating func runFinished() {
        if isHolding { runEnded = true }
    }

    /// A cleanup report arrived; `token` is the drop token after it.
    mutating func reported(token: Int) -> Release? {
        guard isHolding else { return nil }
        return end(token != startToken ? .drop : .quiet)
    }

    mutating func timedOut() -> Release? {
        guard waitsForTimeout else { return nil }
        return end(.quiet)
    }

    private mutating func end(_ release: Release) -> Release {
        isHolding = false
        runEnded = false
        return release
    }
}

/// Runs DropHold against the model and the drop coordinator. A modifier,
/// so the status changing during a run redraws only this, not the screen.
struct DropHoldWatcher: ViewModifier {
    let model: AppModel
    @Binding var held: StorageFigures?
    /// What the screen shows right now, captured when a hold starts.
    let live: StorageFigures

    @State private var hold = DropHold()
    @Environment(\.ballastDrop) private var drop

    func body(content: Content) -> some View {
        content
            .onChange(of: model.isDroppingBallast) { _, dropping in
                guard dropping else { return }
                if !hold.isHolding { held = live }
                hold.cleanupStarted(token: drop.token)
            }
            .onChange(of: model.isScanning) { _, scanning in
                if scanning {
                    release(hold.runStarted(isCleanup: model.isDroppingBallast))
                } else {
                    hold.runFinished()
                }
            }
            .onChange(of: drop.reports) {
                release(hold.reported(token: drop.token))
            }
            .task(id: hold.waitsForTimeout) {
                guard hold.waitsForTimeout else { return }
                guard (try? await Task.sleep(for: DropHold.grace)) != nil else { return }
                release(hold.timedOut())
            }
    }

    private func release(_ release: DropHold.Release?) {
        guard let release else { return }
        Motion.with(release == .drop ? Motion.drop : Motion.state) { held = nil }
    }
}
