import AppKit
import SwiftUI
import UserNotifications

struct BallastApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        @Bindable var model = model

        WindowGroup("Ballast", id: MainWindow.id) {
            RootView(model: model).frame(minWidth: 860, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CleanupCommands(model: model)
            FolderCommands()
        }

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra(isInserted: $model.preferences.showMenuBarItem) {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Edit › Put Back Last Cleanup and Cleanup History…. No ⌘Z: that stays
/// with text fields' own undo.
struct CleanupCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .undoRedo) {
            Divider()
            Button("Put Back Last Cleanup") {
                MainWindow.show()
                model.isHistoryShown = true
                Task { await model.putBackLast() }
            }
            .disabled(model.lastRestorable == nil || model.isScanning)
            Button("Cleanup History…") {
                MainWindow.show()
                model.isHistoryShown = true
            }
        }
    }
}

/// File › Export… and Edit › Find Folder…, acting on the frontmost window.
struct FolderCommands: Commands {
    @FocusedValue(\.exportAction) private var export
    @FocusedValue(\.findAction) private var find

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button(export?.title ?? "Export…") { export?.perform() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(export == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find Folder…") { find?.perform() }
                .keyboardShortcut("f")
                .disabled(find == nil)
        }
    }
}

/// The main window, reachable from places that aren't inside it: the menu
/// bar item and notification clicks.
@MainActor
enum MainWindow {
    static let id = "main"

    /// Captured from the first view that has one, so AppKit code can open
    /// a window after the last one was closed.
    static var openWindow: OpenWindowAction?

    /// Brings the main window forward, or opens one if none is left. The
    /// Dock icon comes back first so the window doesn't land behind others.
    static func show() {
        NSApp.setActivationPolicy(.regular)
        if let window = NSApp.windows.first(where: isMain) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: id)
        }
        NSApp.activate()
    }

    /// SwiftUI names WindowGroup windows after the scene id ("main-AppWindow-1").
    private static func isMain(_ window: NSWindow) -> Bool {
        (window.identifier?.rawValue.hasPrefix(id) ?? false) && (window.isVisible || window.isMiniaturized)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let model = AppModel.shared

    /// Whether Ballast stays open with no windows: while the menu bar item
    /// is shown. Without it, closing the last window (main or Settings) quits.
    var keepsRunningWithoutWindows: Bool { model.preferences.showMenuBarItem }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Settings › General, or `defaults write dev.mamad.Ballast AppearanceOverride dark|light`.
        Appearance.saved.apply()
        // Needed when launched via `swift run` (no .app bundle): otherwise the
        // window opens behind the terminal with no Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if Notify.isAvailable { UNUserNotificationCenter.current().delegate = self }
        watchWindows()
        // The menu bar item needs data even if no window ever opens.
        Task { await model.start() }
    }

    // Settings counts as a window: closing the main window while Settings is
    // open leaves Settings up, and quitting waits until it's closed too.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !keepsRunningWithoutWindows
    }

    /// Opening Ballast again (Finder, Spotlight, a login item) while it runs
    /// windowless from the menu bar brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.show() }
        return false
    }

    // MARK: Dock icon

    /// With the menu bar item on, Ballast leaves the Dock when its last
    /// window closes and comes back when one opens.
    private func watchWindows() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowWillClose(window) }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, Self.isAppWindow(window), NSApp.activationPolicy() != .regular else { return }
                NSApp.setActivationPolicy(.regular)
            }
        }
    }

    private func windowWillClose(_ closing: NSWindow?) {
        guard keepsRunningWithoutWindows, let closing, Self.isAppWindow(closing) else { return }
        let others = NSApp.windows.filter { $0 !== closing && Self.isAppWindow($0) }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    /// Main and Settings windows; not the menu bar item's panel.
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && (window.isVisible || window.isMiniaturized)
    }

    // MARK: Notifications

    /// Shown even while Ballast is in front, e.g. from the in-app check.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// A click opens the main window, even when Ballast runs with none.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { MainWindow.show() }
    }
}
