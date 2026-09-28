import SwiftUI

struct SafetySettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                FolderList(
                    folders: $model.preferences.protectedFolders,
                    empty: "No folders protected yet.",
                    prompt: "Protect"
                )
            } header: {
                Text("Protected folders")
            } footer: {
                Text("Ballast never cleans these folders or anything inside them, and won't remove a folder that contains one. It checks again at the moment of cleaning, including background auto-clean runs.")
            }

            Section("Always on") {
                ForEach([Safety.Level.safe, .quitFirst, .caution, .blocked], id: \.self) { level in
                    Label {
                        Text(level.title)
                    } icon: {
                        Image(systemName: level.symbol).foregroundStyle(level.color)
                    }
                }
                Text("Every item gets one of these verdicts with a reason, and Ballast asks for confirmation before each cleanup. Deleting permanently is always a separate choice.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPane(scrolls: model.preferences.protectedFolders.count > 6)
    }
}
