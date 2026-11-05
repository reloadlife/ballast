import SwiftUI

/// A safety verdict as a symbol whose *shape* carries the meaning, so it
/// survives Increase Contrast, Reduce Transparency, grayscale and color
/// blindness: safe is a checkmark in a circle, quit first a pause in a
/// rectangle, caution a triangle, protected a lock. Color is the second
/// cue and never magenta. VoiceOver reads the verdict's title.
struct SafetyMark: View {
    let level: Safety.Level
    /// Shows the verdict's title beside the mark.
    var showsTitle = false

    var body: some View {
        Group {
            if showsTitle {
                Label {
                    Text(level.title)
                } icon: {
                    mark
                }
            } else {
                mark
                    .help(level.title)
                    .accessibilityLabel(level.title)
            }
        }
    }

    private var mark: some View {
        Image(systemName: level.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(level.color)
            .imageScale(.medium)
    }
}

// MARK: Preview

private struct SafetyMarkPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([Safety.Level.safe, .quitFirst, .caution, .blocked], id: \.self) { level in
                SafetyMark(level: level, showsTitle: true)
            }
            HStack(spacing: 12) {
                ForEach([Safety.Level.safe, .quitFirst, .caution, .blocked], id: \.self) { SafetyMark(level: $0) }
            }
            .grayscale(1)
        }
        .padding(24)
        .background(Theme.water)
    }
}

#Preview("SafetyMark · light") { SafetyMarkPreview().preferredColorScheme(.light) }
#Preview("SafetyMark · dark") { SafetyMarkPreview().preferredColorScheme(.dark) }
