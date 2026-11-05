import SwiftUI

/// A check's outcome as a shape, the way SafetyMark shows a verdict: passed
/// is a checkmark in a circle, needs attention a triangle, unavailable a
/// question mark, information an "i", a problem an exclamation mark. Color is only the second cue, so it
/// reads under Increase Contrast, Reduce Transparency and in grayscale.
/// Only "needs attention" is chart magenta: it's the one the user can act
/// on. Not for safety verdicts (those are SafetyMark).
struct StatusMark: View {
    enum State: String, Sendable, Hashable, CaseIterable {
        case passed, attention, unavailable, information
        /// Something went wrong that the user can't fix from here: an
        /// exclamation mark, not magenta.
        case problem

        var symbol: String {
            switch self {
            case .passed: "checkmark.circle.fill"
            case .attention: "exclamationmark.triangle.fill"
            case .unavailable: "questionmark.circle"
            case .information: "info.circle"
            case .problem: "exclamationmark.circle"
            }
        }

        var color: Color {
            switch self {
            case .passed: Theme.verdictSafe
            case .attention: Theme.hazard
            case .unavailable, .information, .problem: .secondary
            }
        }

        /// What VoiceOver reads when no title is shown.
        var spoken: String {
            switch self {
            case .passed: "Passed"
            case .attention: "Needs attention"
            case .unavailable: "Unavailable"
            case .information: "Information"
            case .problem: "Problem"
            }
        }
    }

    let state: State
    /// Shown beside the mark; nil shows the mark alone.
    var title: String?

    var body: some View {
        if let title {
            Label {
                Text(title)
            } icon: {
                mark
            }
            .accessibilityElement(children: .combine)
        } else {
            mark
                .help(state.spoken)
                .accessibilityLabel(state.spoken)
        }
    }

    private var mark: some View {
        // Monochrome, not hierarchical: a pale filled shape loses the
        // contrast the shape is there to carry.
        Image(systemName: state.symbol)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(state.color)
            .imageScale(.medium)
    }
}

extension StatusMark.State {
    init(_ state: HealthFinding.State) {
        switch state {
        case .passed: self = .passed
        case .attention: self = .attention
        case .unavailable: self = .unavailable
        case .information: self = .information
        }
    }
}
