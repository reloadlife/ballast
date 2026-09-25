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
