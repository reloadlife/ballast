import SwiftUI

/// The Ballast dock: the Cleanup List gathered at the bottom of the detail
/// column as a few Liquid Glass capsules that merge into one shape. A new
/// capsule grows out of the group as the list gains a size, or items that
/// need a decision; the whole dock collapses away when the list empties.
/// One button: it opens the list (the inspector). It takes plain values so
/// it previews without AppModel; RootView places and feeds it.
struct BallastDock: View {
    let count: Int
    let bytes: Int64
    /// Items that need a decision before they can be cleaned (quit first,
    /// unticked caution): a hazard the user can act on, so magenta.
    var needsYou = 0
    /// Items still being measured after a drop from Finder.
    var measuring = 0
    let review: () -> Void

    @Namespace private var glass

    var body: some View {
        Button(action: review) {
            // Wide enough: every capsule. Narrow: count and Review only.
            ViewThatFits(in: .horizontal) {
                capsules(compact: false)
                capsules(compact: true)
            }
        }
        .buttonStyle(DockButtonStyle())
        .help("Review the Cleanup List")
        .accessibilityLabel("Review Cleanup List")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens the Cleanup List")
        .animation(Motion.animation(Motion.layout), value: shape)
    }

    /// What changes the dock's shape; animating on this, not the plan array.
    private var shape: [Int64] { [Int64(count), bytes, Int64(needsYou), Int64(measuring)] }

    private func capsules(compact: Bool) -> some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full.fill")
                        .foregroundStyle(Theme.sea)
                    Text(count.formatted())
                        .font(.body.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText(value: Double(count)))
                    if !compact {
                        Text(count == 1 ? "item" : "items").foregroundStyle(.secondary)
                    }
                    if measuring > 0 {
                        ProgressView().controlSize(.mini)
                    }
                }
                .dockCapsule()
                .glassEffectID("count", in: glass)

                if !compact && bytes > 0 {
                    Sounding(bytes: bytes, font: Theme.sounding.weight(.semibold))
                        .dockCapsule()
                        .glassEffectID("bytes", in: glass)
                }

                if !compact && needsYou > 0 {
                    Label("\(needsYou) need\(needsYou == 1 ? "s" : "") you", systemImage: "hand.raised.fill")
                        .foregroundStyle(Theme.hazard)
                        .contentTransition(.numericText(value: Double(needsYou)))
                        .dockCapsule()
                        .glassEffectID("needs", in: glass)
                }

                Text("Review")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.sea)
                    .dockCapsule(tint: Theme.sea.opacity(0.12))
                    .glassEffectID("review", in: glass)
            }
            .lineLimit(1)
        }
    }

    private var accessibilityValue: String {
        var parts = ["\(count) \(count == 1 ? "item" : "items")"]
        if bytes > 0 { parts.append(bytes.bytes) }
        if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") a decision") }
        if measuring > 0 { parts.append("measuring \(measuring)") }
        return parts.joined(separator: ", ")
    }
}

private extension View {
    func dockCapsule(tint: Color? = nil) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive(), in: .capsule)
    }
}

/// The dock is all glass: pressing it dips it a touch (feedback motion).
private struct DockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.animation(Motion.feedback), value: configuration.isPressed)
            .contentShape(.capsule)
    }
}

// MARK: Preview

private struct DockPreview: View {
    @State private var count = 3
    @State private var bytes: Int64 = 14_600_000_000
    @State private var needsYou = 1

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Button("Add") { count += 1; bytes += 2_300_000_000 }
                Button("Needs you") { needsYou += 1 }
                Button("Clear") { count = 0; bytes = 0; needsYou = 0 }
            }
            Spacer()
            if count > 0 {
                BallastDock(count: count, bytes: bytes, needsYou: needsYou) {}
                    .transition(.opacity)
            }
            BallastDock(count: 1, bytes: 0, measuring: 1) {}
                .frame(width: 220)
        }
        .padding(24)
        .frame(width: 560, height: 300)
        .background { ContourField() }
        .background(Theme.water)
    }
}

#Preview("Dock · light") { DockPreview().preferredColorScheme(.light) }
#Preview("Dock · dark") { DockPreview().preferredColorScheme(.dark) }
