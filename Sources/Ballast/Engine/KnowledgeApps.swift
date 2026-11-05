import Foundation

/// Where any app keeps its caches, by macOS convention and by the
/// Chromium/Electron layout. Named entries in the other tables are more
/// specific and win; these cover every other app. The wildcard stands for
/// the app's folder, and the folder name it matched is used to find the
/// app among running ones.
enum KnowledgeApps {
    private static func appCache(_ id: String, _ name: String, _ path: String, _ regenerates: String,
                                 kind: KnowledgeEntry.Kind = .cache) -> KnowledgeEntry {
        KnowledgeEntry(id: id, name: name, pathPattern: path, kind: kind, verdict: .quitFirst, action: .remove,
                       regenerates: regenerates)
    }

    /// Chromium and Electron cache folders inside `root`, for any app.
    private static func chromiumCaches(_ id: String, root: String) -> [KnowledgeEntry] {
        (Knowledge.chromiumProfileCaches + [("Crashpad", "crash reports waiting to be sent")]).map { folder, name in
            appCache("\(id).\(Knowledge.slug(folder))", "App \(name)", root + "/" + folder,
                     "Kept by apps built on Chromium or Electron. The app makes it again as it's used.")
        }
    }

    static let entries: [KnowledgeEntry] = [
        appCache("app.caches", "App cache", "Library/Caches/*", "The app rebuilds it when it needs it."),
        appCache("app.container-caches", "App cache", "Library/Containers/*/Data/Library/Caches",
                 "The app rebuilds it when it needs it."),
        appCache("app.group-container-caches", "Shared app cache", "Library/Group Containers/*/Library/Caches",
                 "Shared by an app and its extensions; they rebuild it when needed."),
        appCache("app.saved-state", "Saved windows", "Library/Saved Application State/*",
                 "Which windows an app had open. It opens with fresh windows next time.", kind: .appSupport),
        appCache("app.logs", "App logs", "Library/Logs/*", "Apps write new logs as they run.", kind: .log),
        KnowledgeEntry(
            id: "app.http-storage", name: "App cookies and sessions", pathPattern: "Library/HTTPStorages/*",
            kind: .appSupport, verdict: .caution, action: .remove,
            regenerates: "Cookies and web sessions the app keeps. Removing them signs you out of the app and the websites inside it."
        ),
        KnowledgeEntry(
            id: "app.webkit", name: "App website data", pathPattern: "Library/WebKit/*",
            kind: .appSupport, verdict: .caution, action: .remove,
            regenerates: "Local storage, databases and cookies of web pages shown inside the app. Removing it signs you out and can lose offline data."
        ),
    ]
        + chromiumCaches("app.support", root: "Library/Application Support/*")
        + chromiumCaches("app.support-profile", root: "Library/Application Support/*/*")
        + chromiumCaches("app.support-vendor-profile", root: "Library/Application Support/*/*/*")
        + chromiumCaches("app.container-support", root: "Library/Containers/*/Data/Library/Application Support/*")
}
