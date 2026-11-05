import SwiftUI

// Shared pieces for the tool screens (Health, Homebrew, Git worktrees).
// They take plain values, so the snapshot tests can render them.

/// A one-device-pixel contour line between rows on a chart surface.
struct ToolHairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Theme.contour)
            .frame(height: 1 / max(displayScale, 1))
            .accessibilityHidden(true)
    }
}

/// A tool screen's page: content up to the chart's reading width, centred,
/// with the page margins, on open water.
struct ToolPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                content
            }
            .frame(maxWidth: Theme.Space.contentMax, alignment: .leading)
            .padding(.horizontal, Theme.Space.pageX)
            .padding(.top, 24)
            .padding(.bottom, Theme.Space.section)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

/// What a tool is doing in the background: one quiet line of text, a thin
/// depth-tinted progress line under it, and Cancel when it can stop. Rows
/// stay usable while it shows; nothing here blocks them.
struct ToolActivityLine: View {
    let activity: String
    var fraction: Double?
    var canCancel = false
    var cancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(activity)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if canCancel {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .help("Stop this")
                }
            }
            DepthProgress(fraction: fraction)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(activity)
    }
}

/// A tool's last outcome: what happened, a command to run in Terminal when
/// Ballast can't do it itself, and a close button. A failure is magenta
/// only when there's something to do about it (a command to run).
struct ToolOutcomeLine: View {
    var message: String?
    var failure: String?
    var command: String?
    var dismiss: (() -> Void)?

    var body: some View {
        if failure != nil || message != nil || command != nil {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    if let failure {
                        StatusMark(state: command == nil ? .problem : .attention, title: failure)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let message {
                        StatusMark(state: .passed, title: message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let command {
                        HStack(spacing: 8) {
                            Text(command)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Button("Copy") { Finder.copy(command) }
                                .buttonStyle(.borderless)
                                .font(.callout)
                                .help("Copy this command to run it in Terminal")
                        }
                    }
                }
                Spacer(minLength: 8)
                if let dismiss {
                    Button("Dismiss", systemImage: "xmark", action: dismiss)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Dismiss")
                }
            }
            .transition(.opacity)
        }
    }
}

/// A small capsule tag beside a row's name ("Main", "Pinned", "1.2 → 1.3").
struct ToolTag: View {
    let text: String
    var symbol: String?
    /// Sea-tinted for something worth noticing (an update); quiet otherwise.
    var prominent = false

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.subheadline.weight(prominent ? .medium : .regular))
        .monospacedDigit()
        .foregroundStyle(prominent ? AnyShapeStyle(Theme.sea) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 7)
        .padding(.vertical, 1)
        .background(prominent ? Theme.depth[0] : Theme.water, in: .capsule)
    }
}
