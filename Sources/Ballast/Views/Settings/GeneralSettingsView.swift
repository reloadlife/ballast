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

    var telemetryChoice: SettingChoice {
        switch self {
        case .system: .system
        case .light: .light
        case .dark: .dark
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
    private let updater = AppUpdater.shared
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

            Section {
                Toggle(isOn: $model.preferences.showMenuBarItem) {
                    Text("Show in menu bar")
                    Text("Free space and quick actions at a glance. Ballast keeps running there when you close its window.")
                }
                Toggle("Show free space in menu bar", isOn: $model.preferences.menuBarShowsFreeSpace)
                    .disabled(!model.preferences.showMenuBarItem)
            }

            UpdatesSection(updater: updater)
        }
        .settingsPane()
        .onChange(of: appearance) {
            appearance.apply()
            model.noteSetting(.appearance, .choice(appearance.telemetryChoice))
        }
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

/// Sparkle's two settings, when it last checked, and Check Now. A build
/// that can't update (no signing key, or `swift run`) says so instead.
private struct UpdatesSection: View {
    let updater: AppUpdater

    var body: some View {
        Section("Updates") {
            switch updater.support {
            case .available:
                Toggle(isOn: automaticallyChecks) {
                    Text("Check for updates automatically")
                    Text("Once a day. Ballast only goes online to check for updates.")
                }
                Toggle("Download and install automatically", isOn: automaticallyDownloads)
                    .disabled(!updater.automaticallyChecks)
                LabeledContent("Last checked") {
                    Text(updater.lastChecked?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                        .monospacedDigit()
                }
                HStack {
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            case .unavailable(let reason):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updates aren't set up in this build")
                    Text(Self.explanation(reason))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Link("Releases on GitHub", destination: URL(string: "https://github.com/reloadlife/ballast/releases")!)
                }
            }
        }
        .onAppear { updater.refresh() }
    }

    static func explanation(_ reason: UpdateSupport.Reason) -> String {
        switch reason {
        case .notBundled: "Only available when Ballast runs as an app. Build it with scripts/bundle.sh."
        case .noFeed, .noPublicKey: "It has no key to verify updates with, so it doesn't look for them. New versions are on GitHub."
        }
    }

    // Written only when the user flips them: Sparkle takes either as their
    // answer and stops asking.
    private var automaticallyChecks: Binding<Bool> {
        Binding { updater.automaticallyChecks } set: { updater.setAutomaticallyChecks($0) }
    }

    private var automaticallyDownloads: Binding<Bool> {
        Binding { updater.automaticallyDownloads } set: { updater.setAutomaticallyDownloads($0) }
    }
}
