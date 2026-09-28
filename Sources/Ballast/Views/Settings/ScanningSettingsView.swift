import SwiftUI

struct ScanningSettingsView: View {
    @Bindable var model: AppModel

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
        }
        .settingsPane(scrolls: model.preferences.excludedFolders.count > 6)
    }

    static func label(_ months: Int) -> String {
        switch months {
        case 12: "1 year"
        case 24: "2 years"
        default: "\(months) months"
        }
    }
}
