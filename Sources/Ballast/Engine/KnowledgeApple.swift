import Foundation

/// Apple's own apps and devices: Photos, Mail, Messages, iPhone and iPad
/// backups and software, wallpapers.
enum KnowledgeApple {
    static let entries: [KnowledgeEntry] = [
        // MARK: Photos
        KnowledgeEntry(
            id: "photos.library", name: "A Photos library", pathPattern: "Pictures/*.photoslibrary",
            owners: ["com.apple.Photos"], kind: .userData, verdict: .caution, insideVerdict: .blocked,
            regenerates: "Removing it deletes every photo and video in it that isn't also in iCloud Photos.",
            guidance: "Delete photos in Photos. To free space and keep them, turn on Photos › Settings › iCloud › Optimize Mac Storage."
        ),
        KnowledgeEntry(
            id: "photos.photo-booth", name: "The Photo Booth library", pathPattern: "Pictures/Photo Booth Library",
            owners: ["com.apple.PhotoBooth"], kind: .userData, verdict: .caution, insideVerdict: .blocked,
            regenerates: "Every photo and video you took in Photo Booth.",
            guidance: "Delete pictures in Photo Booth so its library stays in step."
        ),

        // MARK: Mail
        KnowledgeEntry(
            id: "mail.downloads", name: "Mail attachments you opened",
            pathPattern: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
            owners: ["com.apple.mail"], kind: .cache, verdict: .safe, action: .remove,
            regenerates: "Copies Mail saved when you opened or previewed an attachment. The originals stay in your messages.",
            needsFullDiskAccess: true
        ),
        KnowledgeEntry(
            id: "mail.data", name: "Your mail", pathPattern: "Library/Mail", owners: ["com.apple.mail"],
            kind: .userData, verdict: .blocked,
            regenerates: "Every message Mail downloaded. Mail that isn't on the server any more would be lost.",
            guidance: "Delete messages in Mail, or have Mail keep fewer attachments in Mail › Settings › Accounts.",
            needsFullDiskAccess: true
        ),

        // MARK: Messages
        KnowledgeEntry(
            id: "messages.attachments", name: "Messages attachments", pathPattern: "Library/Messages/Attachments",
            owners: ["com.apple.MobileSMS"], kind: .userData, verdict: .blocked,
            regenerates: "Photos, videos and files from your conversations. Removing them here leaves gaps in those conversations.",
            guidance: "In Messages › Settings › General, set Keep messages to 30 Days or 1 Year, or remove big attachments in System Settings › General › Storage › Messages.",
            needsFullDiskAccess: true
        ),
        KnowledgeEntry(
            id: "messages.data", name: "Your messages", pathPattern: "Library/Messages", owners: ["com.apple.MobileSMS"],
            kind: .userData, verdict: .blocked,
            regenerates: "Your conversations. Without Messages in iCloud, they can't be brought back.",
            guidance: "Delete conversations in Messages.",
            needsFullDiskAccess: true
        ),

        // MARK: iPhone and iPad
        KnowledgeEntry(
            id: "devices.backups", name: "iPhone and iPad backups", pathPattern: "Library/Application Support/MobileSync",
            kind: .backup, verdict: .blocked,
            regenerates: "Where Finder keeps device backups. Remove individual backups rather than the whole folder.",
            guidance: "Finder › your device › Manage Backups lists them with their dates.",
            needsFullDiskAccess: true
        ),
        KnowledgeEntry(
            id: "devices.backup", name: "An iPhone or iPad backup", pathPattern: "Library/Application Support/MobileSync/Backup/*",
            kind: .backup, verdict: .caution, insideVerdict: .blocked, action: .remove,
            regenerates: "Without it, that device can only be restored from iCloud or a newer backup. Finder makes a new one the next time you back up.",
            guidance: "Finder › your device › Manage Backups shows which device and date each one is.",
            needsFullDiskAccess: true
        ),
        KnowledgeEntry(
            id: "devices.iphone-updates", name: "iPhone software downloads", pathPattern: "Library/iTunes/iPhone Software Updates",
            kind: .installer, verdict: .safe, action: .remove,
            regenerates: "iOS versions Finder downloaded to update or restore an iPhone. Finder downloads one again when it needs it."
        ),
        KnowledgeEntry(
            id: "devices.ipad-updates", name: "iPad software downloads", pathPattern: "Library/iTunes/iPad Software Updates",
            kind: .installer, verdict: .safe, action: .remove,
            regenerates: "iPadOS versions Finder downloaded to update or restore an iPad. Finder downloads one again when it needs it."
        ),
        KnowledgeEntry(
            id: "devices.ipod-updates", name: "iPod software downloads", pathPattern: "Library/iTunes/iPod Software Updates",
            kind: .installer, verdict: .safe, action: .remove,
            regenerates: "iPod software Finder downloaded. It downloads again when needed."
        ),

        // MARK: System
        KnowledgeEntry(
            id: "system.aerials", name: "Aerial wallpapers and screen savers",
            pathPattern: "/Library/Application Support/com.apple.idleassetsd/Customer",
            kind: .download, verdict: .caution, action: .remove,
            regenerates: "Videos macOS downloaded for aerial wallpapers and screen savers. It downloads one again when you choose it in Wallpaper or Screen Saver settings."
        ),
        KnowledgeEntry(
            id: "system.diagnostic-reports", name: "Crash and hang reports", pathPattern: "Library/Logs/DiagnosticReports",
            kind: .log, verdict: .safe, action: .contents,
            regenerates: "Reports macOS wrote when apps crashed or hung. New ones are written if it happens again."
        ),
        KnowledgeEntry(
            id: "system.keychains", name: "Your keychains", pathPattern: "Library/Keychains", kind: .system, verdict: .blocked,
            regenerates: "Your saved passwords, certificates and keys. They can't be recreated.",
            guidance: "Manage them in the Passwords app or Keychain Access.", neverTouch: true
        ),
    ]
}
