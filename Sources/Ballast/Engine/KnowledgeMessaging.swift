import Foundation

/// Chat and meeting apps. Their caches rebuild; their media may be the
/// only copy, and their databases must be cleaned from inside the app.
enum KnowledgeMessaging {
    private static let slack = ["com.tinyspeck.slackmacgap"]
    private static let discord = ["com.hnc.Discord"]
    private static let teams = ["com.microsoft.teams2"]
    private static let telegram = ["ru.keepcoder.Telegram"]
    private static let whatsapp = ["net.whatsapp.WhatsApp"]
    private static let signal = ["org.whispersystems.signal-desktop"]

    static let entries: [KnowledgeEntry] =
        Knowledge.electron("slack", "Slack", root: "Library/Application Support/Slack", owners: slack,
                           guidance: "Slack › Help › Troubleshooting › Clear Cache and Restart does the same from inside.",
                           extra: [("logs", "logs")])
        + Knowledge.electron("slack.store", "Slack",
                             root: "Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack",
                             owners: slack,
                             guidance: "Slack › Help › Troubleshooting › Clear Cache and Restart does the same from inside.",
                             extra: [("logs", "logs")])
        + Knowledge.electron("discord", "Discord", root: "Library/Application Support/discord", owners: discord)
        + Knowledge.electron("teams.classic", "Teams (classic)", root: "Library/Application Support/Microsoft/Teams",
                             owners: ["com.microsoft.teams"])
        + Knowledge.electron("signal", "Signal", root: "Library/Application Support/Signal", owners: signal)
        + Knowledge.chromiumCaches("teams", "Teams",
                                   root: "Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/EBWebView",
                                   owners: teams)
        + [
            KnowledgeEntry(
                id: "teams.webview", name: "Teams' built-in browser data",
                pathPattern: "Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/EBWebView",
                owners: teams, kind: .appSupport, verdict: .caution,
                regenerates: "Teams' cache together with your sign-in. Teams rebuilds the rest, but you have to sign in again."
            ),
            KnowledgeEntry(
                id: "teams.data", name: "Teams' data", pathPattern: "Library/Containers/com.microsoft.teams2",
                owners: teams, kind: .appSupport, verdict: .blocked,
                regenerates: "Teams' settings, sign-in and local chat data."
            ),

            // MARK: Telegram
            KnowledgeEntry(
                id: "telegram.media", name: "Telegram's downloaded media",
                pathPattern: "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/*/*/postbox/media", owners: telegram,
                kind: .download, verdict: .blocked,
                regenerates: "Photos, videos and files Telegram downloaded from chats. They download again from Telegram, but removing them here confuses its database.",
                guidance: "Telegram › Settings › Data and Storage › Storage Usage › Clear cache."
            ),
            KnowledgeEntry(
                id: "telegram.data", name: "Telegram's chats and media",
                pathPattern: "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram", owners: telegram,
                kind: .userData, verdict: .blocked,
                regenerates: "Your chats, sign-in and downloaded media. Media comes back from Telegram's servers, but only Telegram can clear it consistently.",
                guidance: "Telegram › Settings › Data and Storage › Storage Usage › Clear cache."
            ),

            // MARK: WhatsApp
            KnowledgeEntry(
                id: "whatsapp.media", name: "WhatsApp media",
                pathPattern: "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media", owners: whatsapp,
                kind: .userData, verdict: .caution,
                regenerates: "Photos, videos and voice messages from your chats. If they aren't on your phone or in a backup, this may be the only copy.",
                guidance: "Delete media from inside WhatsApp so chats don't show missing files."
            ),
            KnowledgeEntry(
                id: "whatsapp.data", name: "WhatsApp's chats",
                pathPattern: "Library/Group Containers/group.net.whatsapp.WhatsApp.shared", owners: whatsapp,
                kind: .userData, verdict: .blocked,
                regenerates: "Your chats and WhatsApp's sign-in on this Mac."
            ),

            // MARK: Zoom
            KnowledgeEntry(
                id: "zoom.recordings", name: "Zoom recordings", pathPattern: "Documents/Zoom", owners: ["us.zoom.xos"],
                kind: .userData, verdict: .caution,
                regenerates: "Meetings you recorded to this Mac. They exist nowhere else."
            ),
        ]
}
