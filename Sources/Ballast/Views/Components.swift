import AppKit
import SwiftUI

extension Int64 {
    var bytes: String { formatted(.byteCount(style: .file)) }
}

struct SizeBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), fraction > 0 ? 3 : 0))
            }
        }
    }
}

struct ScanProgressView: View {
    let status: ScanStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status.title).font(.callout.weight(.medium))
            }
            if let walk = status.walk {
                if walk.dirs > 0 || walk.bytes > 0 {
                    Text("\(walk.dirs.formatted()) folders · \(walk.files.formatted()) files · \(walk.bytes.bytes)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if !walk.path.isEmpty {
                    Text(Paths.display(walk.path))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

enum Finder {
    @MainActor
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Quick Look for any file or folder, from any screen: RootView presents
/// the panel for `AppModel.quickLookURL`. Asking again for the same path
/// closes it, like pressing Space in Finder.
@MainActor
enum QuickLook {
    static func toggle(_ path: String) {
        let model = AppModel.shared
        model.quickLookURL = model.quickLookURL?.path == path ? nil : URL(fileURLWithPath: path)
    }
}

// MARK: Layout

/// Places items left to right and starts a new line when the next one
/// doesn't fit, so an item always wraps whole ("Applications 25 GB" moves
/// down as one) and never breaks mid-word in a narrow window. Its size
/// comes only from what it's offered, so it adds no minimum width to the
/// split view.
struct FlowLayout: Layout {
    var spacing: CGFloat = 18
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let size = arrange(subviews, width: width).size
        return CGSize(width: min(size.width, width), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(subviews, width: bounds.width).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: widest, height: y + lineHeight), origins)
    }
}

// MARK: Age

/// Buckets "newest modification" into bands that read at a glance.
enum Age: Int, CaseIterable, Identifiable {
    case week, month, quarter, halfYear, year, older, unknown

    var id: Int { rawValue }

    init(newest: Int64) {
        guard newest > 0 else { self = .unknown; return }
        let days = Date.now.timeIntervalSince1970 / 86_400 - Double(newest) / 86_400
        switch days {
        case ..<7: self = .week
        case ..<30: self = .month
        case ..<90: self = .quarter
        case ..<182: self = .halfYear
        case ..<365: self = .year
        default: self = .older
        }
    }

    var label: String {
        switch self {
        case .week: "This week"
        case .month: "This month"
        case .quarter: "1–3 months"
        case .halfYear: "3–6 months"
        case .year: "6–12 months"
        case .older: "Over a year"
        case .unknown: "Unknown"
        }
    }

    /// Color only where age is worth noticing: long-untouched is the signal.
    var color: Color {
        switch self {
        case .week, .month, .quarter, .unknown: .secondary
        case .halfYear: .orange
        case .year, .older: .red
        }
    }

    static func relative(_ newest: Int64) -> String {
        guard newest > 0 else { return "–" }
        return Date(timeIntervalSince1970: TimeInterval(newest))
            .formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}

/// Small colored "last modified" capsule.
struct AgeBadge: View {
    let newest: Int64
    /// Rows the user can't act on (protected, locked, empty) never get the
    /// "stale" warning color: it would be alarm with nothing to do.
    var muted = false

    var body: some View {
        let age = Age(newest: newest)
        Text(Age.relative(newest))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(muted ? Color.secondary : age.color)
            .help("Last modified \(Age.relative(newest)) (\(age.label.lowercased()))")
    }
}

// MARK: Cleanup list

extension Safety.Level {
    var color: Color {
        switch self {
        case .safe: .green
        case .quitFirst: .orange
        case .caution: .yellow
        case .blocked: .red
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .quitFirst: "pause.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .blocked: "nosign"
        }
    }

    var title: String {
        switch self {
        case .safe: "Safe to clean"
        case .quitFirst: "Quit the app first"
        case .caution: "Check before cleaning"
        case .blocked: "Protected"
        }
    }
}

/// ⊕ / ✓ / ⛔ button that adds an item to the Cleanup List.
struct ListToggle: View {
    let item: PlanItem?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        if let item, item.safety.level != .blocked {
            Button(action: action) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help(isOn ? "Remove from Cleanup List" : "Add to Cleanup List")
            .accessibilityLabel(isOn ? "Remove \(item.name) from Cleanup List" : "Add \(item.name) to Cleanup List")
        } else {
            // Protected or not removable: no control. The reason is in the
            // row's context menu.
            Color.clear.frame(width: 20, height: 20)
        }
    }
}

// MARK: Motion

/// Every animation goes through here so Reduce Motion turns them all off.
enum Motion {
    @MainActor static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    @MainActor static func animation(_ animation: Animation) -> Animation? {
        reduced ? nil : animation
    }
}

// MARK: Icons

/// File and app icons, read once per path: NSWorkspace goes to disk, and
/// rows redraw often.
@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}
