import AppKit
import SwiftUI

// Small pieces Suggestions and the Cleanup List share. Local variants of
// the shared kit where it didn't fit: a share bar without a GeometryReader
// per row, an age label without warning colors, an add control that can
// show an add still being checked.

/// A divider drawn once, one device pixel high, in the contour color.
struct Hairline: View {
    var leading: CGFloat = 0
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Theme.contour)
            .frame(height: 1 / max(displayScale, 1))
            .padding(.leading, leading)
            .accessibilityHidden(true)
    }
}

/// A row's share of its section's largest item, in the chart's blues.
/// Fixed size and no GeometryReader, so long lists stay cheap.
struct ShareBar: View {
    let fraction: Double
    var width: CGFloat = 56

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        Capsule()
            .fill(Theme.depth[0])
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Theme.sea)
                    .frame(width: max(width * clamped, clamped > 0 ? 3 : 0))
            }
            .frame(width: width, height: 4)
            .accessibilityHidden(true)
    }
}

/// The byte column: every figure in a list ends on this edge.
struct ByteColumn: View {
    let bytes: Int64
    var width: CGFloat = 78
    var font: Font = Theme.sounding
    var dimmed = false

    var body: some View {
        Sounding(bytes: bytes, font: font, style: dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}

/// "3 mo. ago": when something last changed, without warning colors
/// (age is information here, not a hazard).
struct AgeLabel: View {
    let newest: Int64

    var body: some View {
        Text(Age.relative(newest))
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .help(newest > 0 ? "Last changed \(Age.relative(newest))" : "When it last changed isn't known")
    }
}

/// Where an add to the Cleanup List stands.
enum AddState: Equatable {
    /// Not on the list: the button adds it.
    case add
    /// Being checked off the main thread; it lands on the list shortly.
    case pending
    /// On the list; the button takes it off.
    case added
    /// On the list because something bigger there cleans it too.
    case covered
    /// Can't go on the list (protected, or guidance only).
    case unavailable
}

/// The leading ⊕ / progress / ✓ control of a suggestion row.
struct AddButton: View {
    let state: AddState
    /// What the button adds, for VoiceOver and the tooltip.
    let name: String
    var coveredBy: String?
    let action: () -> Void

    var body: some View {
        Group {
            switch state {
            case .unavailable:
                Color.clear
            case .pending:
                ProgressView()
                    .controlSize(.small)
                    .help("Checking \(name) before adding it")
                    .accessibilityLabel("Adding \(name) to the Cleanup List")
            case .add, .added, .covered:
                Button(action: action) {
                    Image(systemName: state == .add ? "plus.circle" : "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(state == .add ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.sea))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .disabled(state == .covered)
                .help(help)
                .accessibilityLabel(accessibilityLabel)
            }
        }
        .frame(width: 22, height: 22)
        .animation(Motion.animation(Motion.feedback), value: state)
    }

    private var help: String {
        switch state {
        case .add: "Add to Cleanup List"
        case .added: "Remove from Cleanup List"
        case .covered: "Already cleaned by \(coveredBy ?? "something on the Cleanup List")"
        case .pending, .unavailable: ""
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .add: "Add \(name) to Cleanup List"
        case .added: "Remove \(name) from Cleanup List"
        case .covered: "\(name) is already on the Cleanup List"
        case .pending, .unavailable: name
        }
    }
}

extension AddState {
    init(_ membership: PlanMembership, pending: Bool) {
        switch membership {
        case .all(let removable): self = removable ? .added : .covered
        case .none, .partial: self = pending ? .pending : .add
        }
    }
}

/// A chevron that turns when its group opens.
struct DisclosureChevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(Motion.animation(Motion.feedback), value: expanded)
            .frame(width: 14)
            .accessibilityHidden(true)
    }
}

/// A row that tints a little under the pointer (feedback, no layout change).
struct RowHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .fill(Theme.depth[0].opacity(hovering ? 0.45 : 0))
                    .padding(.horizontal, -8)
            }
            .onHover { inside in
                withAnimation(Motion.animation(Motion.feedback)) { hovering = inside }
            }
    }
}

extension View {
    func rowHover() -> some View { modifier(RowHover()) }
}

/// Rows entering and leaving a list: a short fade and settle in, a
/// quicker fade out, so a cleaned row never lingers.
extension AnyTransition {
    static var row: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                    removal: .opacity.animation(Motion.exit))
    }
}

/// "~/Library/Caches" for a display path.
func homeRelative(_ path: String) -> String {
    let home = Catalog.home
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// Opens an app by its name from the standard folders, looked up off the
/// main thread when the button is pressed.
enum AppOpener {
    static func candidates(for name: String) -> [String] {
        let file = name.hasSuffix(".app") ? name : name + ".app"
        return ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications",
                "/Applications/Utilities", "/System/Applications/Utilities"].map { $0 + "/" + file }
    }

    @MainActor
    static func open(_ name: String, fallback: String) {
        let paths = candidates(for: name)
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                paths.first { FileManager.default.fileExists(atPath: $0) }
            }.value
            if let found {
                _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: found), configuration: .init())
            } else {
                Finder.reveal(fallback)
            }
        }
    }
}
