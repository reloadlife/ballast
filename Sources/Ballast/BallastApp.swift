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
    // Needed when launched via `swift run` (no .app bundle): otherwise the
    // window opens behind the terminal with no Dock icon.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `defaults write dev.mamad.Ballast AppearanceOverride dark|light` pins
        // the appearance, e.g. to check both themes without changing the system.
        switch UserDefaults.standard.string(forKey: "AppearanceOverride") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
