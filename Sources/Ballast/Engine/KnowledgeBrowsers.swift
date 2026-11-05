import Foundation

/// Web browsers: profiles stay protected, their caches are carved out.
enum KnowledgeBrowsers {
    private static let chrome = ["com.google.Chrome"]
    private static let edge = ["com.microsoft.edgemac"]
    private static let brave = ["com.brave.Browser"]
    private static let arc = ["company.thebrowser.Browser"]
    private static let firefox = ["org.mozilla.firefox"]
    private static let safari = ["com.apple.Safari"]
    private static let clearData = "Clear browsing data from the browser's settings instead to choose what goes."

    static let entries: [KnowledgeEntry] =
        Knowledge.chromium("chrome", "Chrome", root: "Library/Application Support/Google/Chrome",
                           caches: "Library/Caches/Google/Chrome", owners: chrome,
                           guidance: "Chrome › Settings › Privacy and security › Delete browsing data clears caches and history.")
        + Knowledge.chromium("edge", "Edge", root: "Library/Application Support/Microsoft Edge",
                             caches: "Library/Caches/Microsoft Edge", owners: edge, guidance: clearData)
        + Knowledge.chromium("brave", "Brave", root: "Library/Application Support/BraveSoftware/Brave-Browser",
                             caches: "Library/Caches/BraveSoftware/Brave-Browser", owners: brave, guidance: clearData)
        + Knowledge.chromium("arc", "Arc", root: "Library/Application Support/Arc/User Data",
                             caches: "Library/Caches/Arc", owners: arc, guidance: clearData)
        + [
            KnowledgeEntry(
                id: "arc.data", name: "Arc's data", pathPattern: "Library/Application Support/Arc", owners: arc,
                kind: .userData, verdict: .blocked,
                regenerates: "Your Arc spaces, sidebar and sign-in. They come back only if synced to your Arc account."
            ),

            // MARK: Firefox
            KnowledgeEntry(
                id: "firefox.cache", name: "Firefox web cache", pathPattern: "Library/Caches/Firefox/Profiles/*/cache2",
                owners: firefox, kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "Firefox fills it again as you browse; pages load a little slower at first."
            ),
            KnowledgeEntry(
                id: "firefox.caches", name: "Firefox caches", pathPattern: "Library/Caches/Firefox", owners: firefox,
                kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "Firefox makes them again as you browse."
            ),
            KnowledgeEntry(
                id: "firefox.site-storage", name: "Firefox website storage",
                pathPattern: "Library/Application Support/Firefox/Profiles/*/storage", owners: firefox,
                kind: .userData, verdict: .caution,
                regenerates: "What websites saved in Firefox: offline data, settings and some sign-ins. Sites start fresh without it.",
                guidance: "Firefox › Settings › Privacy & Security › Cookies and Site Data › Manage Data lets you pick sites."
            ),
            KnowledgeEntry(
                id: "firefox.profiles", name: "Firefox profiles", pathPattern: "Library/Application Support/Firefox",
                owners: firefox, kind: .userData, verdict: .blocked,
                regenerates: "Bookmarks, saved passwords, history and add-ons. They don't come back unless you sync.",
                guidance: clearData
            ),

            // MARK: Safari
            KnowledgeEntry(
                id: "safari.container-cache", name: "Safari's cache",
                pathPattern: "Library/Containers/com.apple.Safari/Data/Library/Caches", owners: safari,
                kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "Safari fills it again as you browse."
            ),
            KnowledgeEntry(
                id: "safari.cache", name: "Safari's web cache", pathPattern: "Library/Caches/com.apple.Safari", owners: safari,
                kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "Safari fills it again as you browse.", needsFullDiskAccess: true
            ),
            KnowledgeEntry(
                id: "safari.data", name: "Safari's bookmarks and history", pathPattern: "Library/Safari", owners: safari,
                kind: .userData, verdict: .blocked,
                regenerates: "Bookmarks, history, Reading List and extension settings.",
                guidance: "Safari › Clear History, or Safari › Settings › Privacy › Manage Website Data.",
                needsFullDiskAccess: true
            ),
            KnowledgeEntry(
                id: "safari.container", name: "Safari's data", pathPattern: "Library/Containers/com.apple.Safari", owners: safari,
                kind: .userData, verdict: .blocked,
                regenerates: "Safari's settings and website data.",
                guidance: "Safari › Settings › Privacy › Manage Website Data."
            ),
        ]
}
