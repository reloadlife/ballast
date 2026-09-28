import AppKit
import SwiftUI

struct PermissionsSettingsView: View {
    let model: AppModel

    var body: some View {
        let privacy = model.overview?.lockedByPrivacy ?? 0
        let admin = model.overview?.lockedByPermissions ?? 0
        Form {
            Section {
                LabeledContent {
                    status(model.hasFullDiskAccess, on: "Allowed", off: "Not allowed")
                } label: {
                    Text("Full Disk Access")
                    Text("macOS hides Photos, Mail, iOS backups and some app data from every app until you allow this. Without it, those folders show as locked.")
                }
                if !model.hasFullDiskAccess {
                    HStack {
                        Spacer()
                        Button("Open Privacy Settings…") { Access.openFullDiskAccessSettings() }
                    }
                } else if privacy > 0 {
                    LabeledContent {
                        Button("Rescan Them") { Task { await model.rescanLocked() } }
                            .disabled(model.isScanning)
                    } label: {
                        Text("\(privacy) folder\(privacy == 1 ? " was" : "s were") skipped before access was granted")
                    }
                }
            } footer: {
                if !model.hasFullDiskAccess {
                    Text("After allowing it in System Settings, quit and reopen Ballast.")
                }
            }

            Section {
                LabeledContent {
                    status(admin == 0, on: "None", off: "\(admin) folder\(admin == 1 ? "" : "s")")
                        .monospacedDigit()
                } label: {
                    Text("Folders that need an administrator")
                    Text("A few system folders, such as /private/var, can only be read by an administrator. An admin scan asks for your password once, measures only those folders and changes nothing.")
                }
                HStack {
                    Spacer()
                    Button("Scan as Admin…") { Task { await model.rescanLockedAsAdmin() } }
                        .disabled(admin == 0 || model.isScanning)
                }
            } header: {
                Text("Administrator scan")
            }
        }
        .settingsPane()
        .onAppear { model.refreshAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAccess()
        }
    }

    private func status(_ good: Bool, on: String, off: String) -> some View {
        Label {
            Text(good ? on : off)
        } icon: {
            Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(good ? .green : .orange)
        }
    }
}
