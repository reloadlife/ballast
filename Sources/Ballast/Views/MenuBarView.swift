import AppKit
import SwiftUI

/// The menu bar icon, with free space next to it if the user asked for it.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        if model.preferences.menuBarShowsFreeSpace && model.totalBytes > 0 {
            Label(Self.compact(model.freeBytes), systemImage: "internaldrive")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "internaldrive")
                .accessibilityLabel("Ballast")
        }
    }

    /// "412 GB", "8.4 GB", "1.2 TB": short enough for the menu bar.
    static func compact(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1e9
        if gb >= 1000 { return (gb / 1000).formatted(.number.precision(.fractionLength(1))) + " TB" }
        return gb.formatted(.number.precision(.fractionLength(gb < 10 ? 1 : 0))) + " GB"
    }
}

/// The menu bar item's panel: the Overview's first line, then actions.
struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider().padding(.horizontal, 14)

            VStack(spacing: 0) {
                MenuRow("Open Ballast", shortcut: "O") { MainWindow.show() }
                MenuRow("Refresh", shortcut: "R") { Task { await model.update() } }
                    .disabled(model.isScanning || !model.hasIndex)
                MenuRow("Review Cleanup…") {
                    model.requestedPane = .cleanup
                    MainWindow.show()
                }
                .disabled(!model.hasIndex)
            }
            .padding(5)

            Divider().padding(.horizontal, 14)

            VStack(spacing: 0) {
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
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(model.freeBytes.bytes) free of \(model.totalBytes.bytes)")
                .font(.headline)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(model.freeBytes)))
                .accessibilityLabel("\(model.freeBytes.bytes) free of \(model.totalBytes.bytes) on \(Paths.volumeName)")

            StorageBar(segments: model.storageSegments, free: model.freeBytes, total: model.totalBytes)
                .frame(height: 8)

            VStack(alignment: .leading, spacing: 3) {
                if model.reclaimable > 0 {
                    Text("\(model.reclaimable.bytes) safe to clean")
                        .monospacedDigit()
                }
                status
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .animation(Motion.animation(.smooth(duration: 0.6)), value: model.freeBytes)
    }

    @ViewBuilder
    private var status: some View {
        if let status = model.status {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
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
