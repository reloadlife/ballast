import Foundation

/// Cloud sync and the system services behind it. These hold files that
/// may not have reached the server yet, so Ballast never cleans them, and
/// nothing more specific inside them can say otherwise.
enum KnowledgeCloud {
    private static func synced(_ id: String, _ name: String, _ path: String, owners: [String] = [],
                               _ regenerates: String, guidance: String) -> KnowledgeEntry {
        KnowledgeEntry(id: id, name: name, pathPattern: path, owners: owners, kind: .system, verdict: .blocked,
                       regenerates: regenerates, guidance: guidance, neverTouch: true)
    }

    static let entries: [KnowledgeEntry] = [
        synced("cloud.icloud-drive", "iCloud Drive", "Library/Mobile Documents",
               "Your iCloud Drive files and the documents apps keep in iCloud. Removing them here deletes them everywhere.",
               guidance: "Remove files in Finder, or turn on Optimize Mac Storage in System Settings › Apple Account › iCloud › iCloud Drive."),
        synced("cloud.clouddocs", "iCloud Drive's sync data", "Library/Application Support/CloudDocs",
               "What iCloud Drive keeps to track which files are synced. Removing it can make iCloud Drive upload or download everything again, or lose changes.",
               guidance: "Let iCloud Drive manage it."),
        synced("cloud.bird", "iCloud Drive's cache", "Library/Caches/com.apple.bird",
               "Used by iCloud Drive's sync service while it uploads and downloads. It may hold changes that haven't synced yet.",
               guidance: "Let iCloud Drive manage it."),
        synced("cloud.cloudkit", "iCloud app data cache", "Library/Caches/CloudKit",
               "Used by apps that sync through iCloud. It may hold changes that haven't synced yet.",
               guidance: "Let macOS manage it."),
        synced("cloud.nsurlsessiond", "Background downloads", "Library/Caches/com.apple.nsurlsessiond",
               "Downloads and uploads apps have in progress in the background. Removing them breaks those transfers.",
               guidance: "Let macOS manage it."),
        synced("cloud.fileprovider", "Cloud file sync data", "Library/Application Support/FileProvider",
               "What macOS keeps for Dropbox, OneDrive, Google Drive and other cloud folders in Finder. Removing it can lose changes that haven't synced.",
               guidance: "Remove files in Finder, or sign out of the service in its own app."),
        synced("cloud.cloudstorage", "Cloud storage folders", "Library/CloudStorage",
               "Your Dropbox, OneDrive, Google Drive and other cloud folders. Removing files here deletes them from the service too.",
               guidance: "Remove files in Finder, or let the service keep them online only."),
        synced("cloud.drivefs", "Google Drive's local files", "Library/Application Support/Google/DriveFS",
               owners: ["com.google.drivefs"],
               "Google Drive's cache, including files it hasn't uploaded yet.",
               guidance: "Change how much Google Drive keeps offline in its settings, or disconnect the account there."),
        synced("cloud.onedrive-support", "OneDrive's sync data", "Library/Application Support/OneDrive",
               owners: ["com.microsoft.OneDrive"],
               "OneDrive's record of what's synced. Removing it can make OneDrive sync everything again, or lose changes.",
               guidance: "Use Free Up Space on files in Finder, or unlink the account in OneDrive's settings."),
        synced("cloud.onedrive-container", "OneDrive's data", "Library/Containers/com.microsoft.OneDrive-mac",
               owners: ["com.microsoft.OneDrive"],
               "OneDrive's settings and sync state.",
               guidance: "Use Free Up Space on files in Finder, or unlink the account in OneDrive's settings."),
        synced("cloud.onedrive-group", "OneDrive's shared data", "Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite",
               owners: ["com.microsoft.OneDrive"],
               "Shared between OneDrive and its Finder extension to track what's synced.",
               guidance: "Unlink the account in OneDrive's settings if you want it gone."),
        synced("cloud.dropbox-support", "Dropbox's sync data", "Library/Application Support/Dropbox",
               owners: ["com.getdropbox.dropbox"],
               "Dropbox's record of what's synced.",
               guidance: "Make files online-only in Finder, or unlink this Mac in Dropbox's settings."),
        synced("cloud.dropbox-home", "Dropbox's settings", ".dropbox",
               owners: ["com.getdropbox.dropbox"],
               "Dropbox's account link and sync database.",
               guidance: "Unlink this Mac in Dropbox's settings if you want it gone."),
        synced("cloud.dropbox-cache", "Dropbox's cache", "Dropbox/.dropbox.cache",
               owners: ["com.getdropbox.dropbox"],
               "Files Dropbox is in the middle of syncing, and recently deleted ones. Dropbox empties it on its own.",
               guidance: "Let Dropbox manage it."),
    ]
}
