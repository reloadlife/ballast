import AppKit
import SwiftUI

struct BallastApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Ballast") {
            RootView(model: model).frame(minWidth: 860, minHeight: 560)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Whether Ballast stays open with no windows. Off for now: closing the
    /// last window (main or Settings) quits. A menu bar item would turn it on.
    var keepsRunningWithoutWindows: Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Settings › General, or `defaults write dev.mamad.Ballast AppearanceOverride dark|light`.
        Appearance.saved.apply()
        // Needed when launched via `swift run` (no .app bundle): otherwise the
        // window opens behind the terminal with no Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    // Settings counts as a window: closing the main window while Settings is
    // open leaves Settings up, and quitting waits until it's closed too.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !keepsRunningWithoutWindows
    }
}
