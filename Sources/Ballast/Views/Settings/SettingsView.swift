import AppKit
import SwiftUI

enum SettingsTab: String {
    case general, scanning, safety, notifications, permissions, data, autoClean, privacy, about

    /// Remembers the open tab; other screens set it before `openSettings()`
    /// to land on the right one.
    static let key = "settingsTab"

    static func select(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: key)
    }
}

struct SettingsView: View {
    let model: AppModel
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettingsView(model: model)
            }
            Tab("Scanning", systemImage: "internaldrive", value: .scanning) {
                ScanningSettingsView(model: model)
            }
            Tab("Safety", systemImage: "checkmark.shield", value: .safety) {
                SafetySettingsView(model: model)
            }
            Tab("Notifications", systemImage: "bell.badge", value: .notifications) {
                NotificationsSettingsView(model: model)
            }
            Tab("Permissions", systemImage: "hand.raised", value: .permissions) {
                PermissionsSettingsView(model: model)
            }
            Tab("Data", systemImage: "cylinder.split.1x2", value: .data) {
                DataSettingsView(model: model)
            }
            Tab("Auto-Clean", systemImage: "clock.arrow.circlepath", value: .autoClean) {
                AutoCleanSettingsView(model: model)
            }
            Tab("Privacy", systemImage: "lock.shield", value: .privacy) {
                PrivacySettingsView(model: model)
            }
            Tab("About", systemImage: "info.circle", value: .about) {
                AboutSettingsView()
            }
        }
        // Settings can open before the main window has loaded anything.
        .task { await model.start() }
    }
}

extension View {
    /// A settings tab: a grouped form, as tall as its content. Tabs that can
    /// grow past a screen (long folder lists) pass `scrolls` instead.
    @ViewBuilder
    func settingsPane(scrolls: Bool = false) -> some View {
        if scrolls {
            formStyle(.grouped)
                .frame(width: 600)
                .frame(minHeight: 560, maxHeight: .infinity)
        } else {
            formStyle(.grouped)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 600)
        }
    }
}

/// Folders the user picked, with Add and Remove. Stored as display paths.
struct FolderList: View {
    @Binding var folders: [String]
    let empty: String
    /// Open panel button title, e.g. "Exclude".
    let prompt: String

    var body: some View {
        if folders.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        }
        ForEach(folders, id: \.self) { path in
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent)
                    Text(path.replacingOccurrences(of: Catalog.home, with: "~"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Remove", systemImage: "minus.circle") {
                    folders.removeAll { $0 == path }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove \((path as NSString).lastPathComponent) from this list")
            }
            .contextMenu {
                Button("Show in Finder") { Finder.reveal(path) }
            }
        }
        HStack {
            Spacer()
            Button("Add Folder…") { choose() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return }
        // One assignment, so the change is saved (and acted on) once.
        var updated = folders
        for url in panel.urls {
            let path = Preferences.normalized(url.path)
            if path != "/", !updated.contains(path) { updated.append(path) }
        }
        folders = updated.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
