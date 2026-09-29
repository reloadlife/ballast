import SwiftUI

struct ScanningSettingsView: View {
    @Bindable var model: AppModel
    @State private var forgetting: Disk?

    var body: some View {
        Form {
            Section {
                FolderList(
                    folders: $model.preferences.excludedFolders,
                    empty: "Ballast measures every folder on your disk.",
                    prompt: "Exclude"
                )
            } header: {
                Text("Excluded folders")
            } footer: {
                Text("Ballast doesn't look inside these folders, so their space isn't counted in any folder or suggestion. The index updates as soon as you change this list.")
            }

            Section {
                Picker("Suggest folders untouched for", selection: $model.preferences.staleMonths) {
                    ForEach(Preferences.staleChoices, id: \.self) { months in
                        Text(Self.label(months)).tag(months)
                    }
                }
            } footer: {
                Text("Big folders where nothing has changed for this long appear in Suggestions for you to review. They're never added to the Cleanup List on their own.")
            }

            Section {
                Toggle("Show removable drives in the sidebar", isOn: $model.preferences.showRemovableDrives)
                let scanned = model.disks.filter(\.isScanned)
                if scanned.isEmpty {
                    Text("No other drive has been scanned yet.").foregroundStyle(.secondary)
                }
                ForEach(scanned) { disk in
                    HStack(spacing: 10) {
                        Image(systemName: disk.isRemovable ? "externaldrive" : "internaldrive")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(disk.name)
                            Text(detail(disk))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget…") { forgetting = disk }
                            .disabled(model.isScanning)
                    }
                }
                ForEach(model.unsupportedDisks) { volume in
                    HStack(spacing: 10) {
                        Image(systemName: "network")
                            .foregroundStyle(.tertiary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(volume.name).foregroundStyle(.secondary)
                            Text(volume.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Other drives")
            } footer: {
                Text("Ballast scans other drives only when you ask, and keeps one index for each. Excluded and protected folders apply to them too. Forgetting a drive deletes its index, never anything on the drive.")
            }
        }
        .settingsPane(scrolls: model.preferences.excludedFolders.count + model.disks.count > 6)
        .confirmationDialog("Forget \(forgetting?.name ?? "")?", isPresented: Binding(
            get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            if let disk = forgetting {
                Button("Forget \(disk.name)", role: .destructive) { Task { await model.forgetDisk(disk.uuid) } }
            }
        } message: {
            Text("Ballast deletes its index of this drive. Nothing on the drive is touched.")
        }
    }

    /// "APFS · connected · scanned 3 days ago"
    private func detail(_ disk: Disk) -> String {
        let scanned = disk.scannedAt.map { "scanned \($0.formatted(.relative(presentation: .named)))" } ?? "not scanned"
        return [disk.format, disk.isConnected ? "connected" : "not connected", scanned]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func label(_ months: Int) -> String {
        switch months {
        case 12: "1 year"
        case 24: "2 years"
        default: "\(months) months"
        }
    }
}
