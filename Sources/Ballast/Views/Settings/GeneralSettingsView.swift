import AppKit
import ServiceManagement
import SwiftUI

/// Light, dark or follow the system. Kept in UserDefaults under the key the
/// old hidden override used, so `defaults write dev.mamad.Ballast
/// AppearanceOverride dark` (or `-AppearanceOverride dark` at launch) still
/// works for checking both themes.
enum Appearance: String, CaseIterable, Identifiable {
    case system = "", light, dark

    static let key = "AppearanceOverride"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static var saved: Appearance {
        Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    @MainActor
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct GeneralSettingsView: View {
    @Bindable var model: AppModel
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    /// Login items need a real app bundle, not a bare `swift run` binary.
    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: launchAtLogin) {
                    Text("Open Ballast at login")
                    if !isBundled {
                        Text("Only available when Ballast runs as an app. Build it with scripts/bundle.sh.")
                    } else if loginStatus == .requiresApproval {
                        Text("Waiting for your approval in System Settings › General › Login Items.")
                    } else if let loginError {
                        Text(loginError).foregroundStyle(.red)
                    }
                }
                .disabled(!isBundled)
                if loginStatus == .requiresApproval {
                    HStack {
                        Spacer()
                        Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }

            Section {
                Picker("When cleaning", selection: $model.preferences.deletePermanentlyByDefault) {
                    Text("Move to Trash").tag(false)
                    Text("Delete Permanently").tag(true)
                }
            } footer: {
                Text("The Cleanup List starts with this choice. You can still change it before each cleanup, and Ballast always asks before removing anything.")
            }

            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            // Menu bar item: added in a later step
        }
        .settingsPane()
        .onChange(of: appearance) { appearance.apply() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    /// Mirrors what macOS actually has registered, not what was last clicked.
    private var launchAtLogin: Binding<Bool> {
        Binding {
            loginStatus == .enabled || loginStatus == .requiresApproval
        } set: { on in
            loginError = nil
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                loginError = error.localizedDescription
            }
            loginStatus = SMAppService.mainApp.status
        }
    }
}
