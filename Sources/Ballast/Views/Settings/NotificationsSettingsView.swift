import AppKit
import SwiftUI
import UserNotifications

struct NotificationsSettingsView: View {
    @Bindable var model: AppModel
    @State private var permission: UNAuthorizationStatus?

    var body: some View {
        let threshold = model.preferences.lowSpaceThreshold
        Form {
            Section {
                Toggle(isOn: $model.preferences.lowSpaceAlert) {
                    Text("Warn when free space runs low")
                    Text("Checked every hour, even when Ballast is closed. At most once a day, unless space keeps dropping.")
                }
                Picker("Warn below", selection: $model.preferences.lowSpaceThresholdGB) {
                    ForEach(Preferences.lowSpaceChoices, id: \.self) { Text("\($0) GB").tag($0) }
                }
                .disabled(!model.preferences.lowSpaceAlert)
                LabeledContent("Free now") {
                    Text(model.freeBytes.bytes)
                        .monospacedDigit()
                        .foregroundStyle(model.preferences.lowSpaceAlert && model.freeBytes < threshold ? .orange : .secondary)
                }
            } header: {
                Text("Low free space")
            }

            Section {
                LabeledContent {
                    permissionStatus
                } label: {
                    Text("Notifications")
                    if permission == .denied || permission == .notDetermined {
                        Text("Ballast can't warn you until notifications are allowed.")
                    }
                }
                if permission == .notDetermined {
                    HStack {
                        Spacer()
                        Button("Allow Notifications…") {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                                Task { @MainActor in await refreshPermission() }
                            }
                        }
                    }
                } else if permission == .denied {
                    HStack {
                        Spacer()
                        Button("Open Notification Settings…") { Self.openNotificationSettings() }
                    }
                }
            } footer: {
                Text("Auto-clean notifications are set up in the Auto-Clean tab.")
            }
        }
        .settingsPane()
        .task { await refreshPermission() }
        // Coming back from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshPermission() }
        }
    }

    @ViewBuilder
    private var permissionStatus: some View {
        switch permission {
        case nil:
            Text(Notify.isAvailable ? "Checking…" : "Needs the app bundle").foregroundStyle(.secondary)
        case .denied:
            status(false, "Off")
        case .notDetermined:
            status(false, "Not asked yet")
        default:
            status(true, "Allowed")
        }
    }

    private func status(_ good: Bool, _ title: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(good ? .green : .orange)
        }
    }

    private func refreshPermission() async {
        guard Notify.isAvailable else { return }
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func openNotificationSettings() {
        var url = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let id = Bundle.main.bundleIdentifier { url += "?id=\(id)" }
        NSWorkspace.shared.open(URL(string: url)!)
    }
}
