import AppKit
import BallastCore
import SwiftUI

/// The menu bar icon, with free space next to it if the user asked for it.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        if model.preferences.menuBarShowsFreeSpace && model.totalBytes > 0 {
            // "412 GB", "8.4 GB": short enough for the menu bar.
            Label(model.freeBytes.compactBytes, systemImage: "internaldrive")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "internaldrive")
                .accessibilityLabel("Ballast")
        }
    }
}

/// The menu bar item's panel: the Overview's first line (free space as
/// the hero figure, the depth bar), then one primary action in ink and the
/// rest as menu rows.
struct MenuBarContent: View {
    let model: AppModel
    private let updater = AppUpdater.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// Worked out when the index or free space changes, not per redraw.
    @State private var segments: [DepthBar.Segment] = []

    /// Review when there's something safe to clean, else Open Ballast.
    private var reviewIsPrimary: Bool { model.hasIndex && model.reclaimable > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            primary
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            Divider().padding(.horizontal, 14)

            VStack(spacing: 0) {
                if reviewIsPrimary {
                    MenuRow("Open Ballast", shortcut: "O") { MainWindow.show() }
                }
                // A user update: it stops a background one rather than waiting.
                MenuRow("Refresh", shortcut: "R") { Task { await model.update() } }
                    .disabled(model.isBusyWithUserWork || !model.hasIndex)
                if !reviewIsPrimary {
                    MenuRow("Review Cleanup…") { review() }
                        .disabled(!model.hasIndex)
                }
            }
            .padding(5)

            Divider().padding(.horizontal, 14)

            VStack(spacing: 0) {
                if updater.isAvailable {
                    MenuRow("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
                MenuRow("Settings…", shortcut: ",") {
                    NSApp.setActivationPolicy(.regular)
                    openSettings()
                    NSApp.activate()
                }
                MenuRow("Quit Ballast", shortcut: "Q") { NSApp.terminate(nil) }
            }
            .padding(5)
        }
        .frame(width: 300)
        .onAppear {
            MainWindow.openWindow = openWindow
            model.refreshFreeSpace()
        }
        .onChange(of: model.depthKey, initial: true) { segments = model.depthSegments }
    }

    private func review() {
        model.requestedPane = .cleanup
        MainWindow.show()
    }

    /// The panel's one ink plate.
    @ViewBuilder
    private var primary: some View {
        if reviewIsPrimary {
            Button(action: review) {
                Text("Review Cleanup").frame(maxWidth: .infinity)
            }
            .buttonStyle(.ink)
            .help("Open Suggestions in the Ballast window")
        } else {
            Button { MainWindow.show() } label: {
                Text("Open Ballast").frame(maxWidth: .infinity)
            }
            .buttonStyle(.ink)
            .keyboardShortcut("o", modifiers: .command)
        }
    }

    private var summary: some View {
        MenuSummary(free: model.freeBytes, total: model.totalBytes, volume: Paths.volumeName,
                    segments: model.hasIndex ? segments : nil, reclaimable: model.reclaimable,
                    grewToday: model.growth.today.flatMap { $0 >= Growth.minimum ? $0 : nil },
                    isLow: model.isLowOnSpace) {
            MenuStatus(model: model)
        }
    }
}

/// The panel's figures as plain values, so it previews and snapshots
/// without the model.
struct MenuSummary<Status: View>: View {
    let free: Int64
    let total: Int64
    let volume: String
    /// Nil before the first scan: a plain used-space bar instead.
    let segments: [DepthBar.Segment]?
    let reclaimable: Int64
    let grewToday: Int64?
    let isLow: Bool
    @ViewBuilder var status: Status

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Sounding(bytes: free, font: Theme.hero(30),
                             style: isLow ? AnyShapeStyle(Theme.hazard) : AnyShapeStyle(.primary))
                    Text(isLow ? "available, running low" : "available")
                        .foregroundStyle(isLow ? AnyShapeStyle(Theme.hazard) : AnyShapeStyle(.secondary))
                }
                Text("of \(total.bytes) on \(volume)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(free.bytes) available of \(total.bytes) on \(volume)")

            if let segments {
                DepthBar(segments: segments, free: free, total: total, height: 8)
            } else {
                SizeBar(fraction: total > 0 ? Double(max(total - free, 0)) / Double(total) : 0,
                        tint: isLow ? Theme.hazard : Theme.sea)
                    .frame(height: 8)
            }

            VStack(alignment: .leading, spacing: 3) {
                if reclaimable > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Sounding(bytes: reclaimable, font: Theme.soundingSmall)
                        Text("can be cleaned safely")
                    }
                }
                // Net change since yesterday's last reading; quiet unless it's real.
                if let grewToday {
                    Text("Folders grew \(grewToday.bytes) today")
                        .monospacedDigit()
                }
                status
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}

/// What Ballast is doing; a leaf, so progress ticks redraw only this line.
private struct MenuStatus: View {
    let model: AppModel

    var body: some View {
        if let status = model.status {
            HStack(spacing: 6) {
                DepthProgress(fraction: model.progress)
                    .frame(width: 40)
                Text(status.title).lineLimit(1)
            }
        } else if model.overview?.scannedAt != nil {
            // Re-rendered each minute so "5 minutes ago" stays true.
            TimelineView(.everyMinute) { _ in Text(model.statusLine) }
        } else {
            Text(model.statusLine)
        }
    }
}

/// A full-width row like a menu item: title, optional ⌘ shortcut, and a
/// quiet hover fill.
private struct MenuRow: View {
    let title: String
    let shortcut: Character?
    let action: () -> Void

    init(_ title: String, shortcut: Character? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text("⌘\(String(shortcut))").foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(MenuRowStyle())
        .modifier(Shortcut(key: shortcut))
    }

    private struct Shortcut: ViewModifier {
        let key: Character?

        func body(content: Content) -> some View {
            if let key {
                content.keyboardShortcut(KeyEquivalent(Character(key.lowercased())), modifiers: .command)
            } else {
                content
            }
        }
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovered && isEnabled ? 0.07 : 0))
                )
                .onHover { hovered = $0 }
        }
    }
}
