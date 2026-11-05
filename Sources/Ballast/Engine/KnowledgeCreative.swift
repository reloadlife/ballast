import Foundation

/// Creative apps, editors and games: media caches and previews, IDE
/// caches by version, game downloads.
enum KnowledgeCreative {
    private static let vscode = ["com.microsoft.VSCode"]
    private static let cursor = ["com.todesktop.230313mzl4w4u92"]
    private static let steam = ["com.valvesoftware.steam"]
    private static let epic = ["com.epicgames.EpicGamesLauncher"]
    private static let jetbrains = [
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm", "com.jetbrains.goland", "com.jetbrains.CLion", "com.jetbrains.rider",
        "com.jetbrains.rubymine", "com.jetbrains.PhpStorm", "com.jetbrains.datagrip", "com.jetbrains.rustrover",
        "com.jetbrains.fleet", "com.google.android.studio",
    ]

    /// VS Code and the editors built from it share a layout.
    private static func codeEditor(_ id: String, _ app: String, root: String, extensions: String, owners: [String]) -> [KnowledgeEntry] {
        Knowledge.electron(id, app, root: root, owners: owners, extra: [
            ("CachedData", "compiled code cache"), ("CachedExtensionVSIXs", "downloaded extension packages"),
            ("CachedProfilesData", "profile cache"), ("logs", "logs"),
        ]) + [
            KnowledgeEntry(
                id: id + ".workspace-storage", name: "\(app) workspace state", pathPattern: root + "/User/workspaceStorage",
                owners: owners, kind: .appSupport, verdict: .caution, action: .remove,
                regenerates: "Per-project state: open editors, undo history, extension data. Each project opens fresh without it."
            ),
            KnowledgeEntry(
                id: id + ".history", name: "\(app) local history", pathPattern: root + "/User/History",
                owners: owners, kind: .userData, verdict: .blocked,
                regenerates: "Earlier versions of files you saved, for Timeline and Local History. They can't be brought back.",
                guidance: "Limit it with \(app)'s workbench.localHistory settings, or delete entries from the Timeline view."
            ),
            KnowledgeEntry(
                id: id + ".extensions", name: "\(app) extensions", pathPattern: extensions,
                owners: owners, kind: .download, verdict: .caution,
                regenerates: "Extensions you installed. They install again from the marketplace, but their local settings may not.",
                guidance: "Uninstall extensions from \(app)'s Extensions view."
            ),
        ]
    }

    static let entries: [KnowledgeEntry] =
        codeEditor("vscode", "VS Code", root: "Library/Application Support/Code", extensions: ".vscode/extensions", owners: vscode)
        + codeEditor("cursor", "Cursor", root: "Library/Application Support/Cursor", extensions: ".cursor/extensions", owners: cursor)
        + [
            // MARK: JetBrains
            KnowledgeEntry(
                id: "jetbrains.caches", name: "JetBrains IDE caches", pathPattern: "Library/Caches/JetBrains/*",
                owners: jetbrains, kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "Indexes and caches for one IDE version. The IDE rebuilds its index on the next launch; older versions' folders are left behind after upgrades.",
                olderVersionsSafe: true
            ),
            KnowledgeEntry(
                id: "jetbrains.logs", name: "JetBrains IDE logs", pathPattern: "Library/Logs/JetBrains/*",
                owners: jetbrains, kind: .log, verdict: .safe, action: .remove,
                regenerates: "The IDE writes new logs as it runs.", olderVersionsSafe: true
            ),
            KnowledgeEntry(
                id: "jetbrains.settings", name: "JetBrains IDE settings and plugins", pathPattern: "Library/Application Support/JetBrains/*",
                owners: jetbrains, kind: .appSupport, verdict: .blocked,
                regenerates: "Settings and plugins for one IDE version. The current version's folder holds your setup; older versions' folders are left over after upgrades.",
                guidance: "Remove plugins in the IDE's Settings › Plugins.",
                olderVersionsSafe: true
            ),
            KnowledgeEntry(
                id: "jetbrains.android-studio-caches", name: "Android Studio caches", pathPattern: "Library/Caches/Google/AndroidStudio*",
                owners: ["com.google.android.studio"], kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "Indexes for one Android Studio version, rebuilt on the next launch.", olderVersionsSafe: true
            ),
            KnowledgeEntry(
                id: "jetbrains.toolbox", name: "JetBrains Toolbox apps", pathPattern: "Library/Application Support/JetBrains/Toolbox",
                kind: .download, verdict: .caution,
                regenerates: "IDEs installed through Toolbox. They install again from Toolbox.",
                guidance: "Remove old versions in Toolbox: an IDE's ⋯ menu › Uninstall, or turn off keeping previous versions in its settings."
            ),

            // MARK: Adobe
            KnowledgeEntry(
                id: "adobe.media-cache", name: "Adobe media cache files",
                pathPattern: "Library/Application Support/Adobe/Common/Media Cache Files",
                kind: .cache, verdict: .safe, action: .remove,
                regenerates: "Audio and video previews Premiere Pro and After Effects make when you import media. They're made again when a project opens.",
                guidance: "Premiere Pro › Settings › Media Cache › Delete does the same."
            ),
            KnowledgeEntry(
                id: "adobe.media-cache-db", name: "Adobe media cache database",
                pathPattern: "Library/Application Support/Adobe/Common/Media Cache",
                kind: .cache, verdict: .safe, action: .remove,
                regenerates: "The index of the media cache files. Rebuilt with them."
            ),
            KnowledgeEntry(
                id: "adobe.camera-raw-cache", name: "Camera Raw cache", pathPattern: "Library/Caches/Adobe Camera Raw",
                kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "Previews Camera Raw, Photoshop and Bridge make of raw photos. Made again when opened."
            ),
            KnowledgeEntry(
                id: "adobe.after-effects-cache", name: "After Effects disk cache", pathPattern: "Library/Caches/Adobe/After Effects",
                kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "Rendered frames After Effects keeps to play back faster. Rendered again when needed.",
                guidance: "After Effects › Settings › Media & Disk Cache › Empty Disk Cache does the same."
            ),
            KnowledgeEntry(
                id: "adobe.lightroom-previews", name: "Lightroom Classic previews", pathPattern: "Pictures/Lightroom/*Previews.lrdata",
                kind: .cache, verdict: .caution, action: .remove,
                regenerates: "Previews of your photos. Lightroom makes them again, slowly; Smart Previews are what let you edit photos whose originals are offline.",
                guidance: "Library › Previews › Discard 1:1 Previews in Lightroom frees space more selectively."
            ),
            KnowledgeEntry(
                id: "adobe.lightroom-catalog", name: "A Lightroom Classic catalog", pathPattern: "Pictures/Lightroom/*.lrcat",
                kind: .userData, verdict: .blocked,
                regenerates: "Every edit, keyword and collection you made in Lightroom. It can't be rebuilt from the photos.",
                guidance: "Manage catalogs in Lightroom Classic › File."
            ),

            // MARK: Final Cut Pro and iMovie
            KnowledgeEntry(
                id: "video.fcp-library", name: "A Final Cut Pro library", pathPattern: "Movies/*.fcpbundle",
                owners: ["com.apple.FinalCut"], kind: .userData, verdict: .caution, insideVerdict: .blocked,
                regenerates: "Your Final Cut Pro events and projects, often with the media you imported.",
                guidance: "To free space safely, select the library in Final Cut Pro and choose File › Delete Generated Library Files."
            ),
            KnowledgeEntry(
                id: "video.imovie-library", name: "The iMovie library", pathPattern: "Movies/*.imovielibrary",
                owners: ["com.apple.iMovieApp"], kind: .userData, verdict: .caution, insideVerdict: .blocked,
                regenerates: "Your iMovie events and projects, with the media you imported.",
                guidance: "Delete render files in iMovie › Settings to free space without losing projects."
            ),

            // MARK: Games
            KnowledgeEntry(
                id: "steam.data", name: "Steam's data", pathPattern: "Library/Application Support/Steam", owners: steam,
                kind: .appSupport, verdict: .blocked,
                regenerates: "Steam itself, your installed games and their settings.",
                guidance: "Uninstall games in Steam: right-click a game › Manage › Uninstall."
            ),
            KnowledgeEntry(
                id: "steam.games", name: "Steam games", pathPattern: "Library/Application Support/Steam/steamapps/common", owners: steam,
                kind: .userData, verdict: .blocked,
                regenerates: "Your installed games. Removing them here leaves Steam thinking they're still installed.",
                guidance: "Uninstall games in Steam: right-click a game › Manage › Uninstall."
            ),
            KnowledgeEntry(
                id: "steam.shader-cache", name: "Steam shader cache", pathPattern: "Library/Application Support/Steam/steamapps/shadercache",
                owners: steam, kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "Compiled graphics shaders for your games. Rebuilt as you play."
            ),
            KnowledgeEntry(
                id: "steam.downloading", name: "Unfinished Steam downloads", pathPattern: "Library/Application Support/Steam/steamapps/downloading",
                owners: steam, kind: .download, verdict: .quitFirst, action: .remove,
                regenerates: "Game updates and installs that didn't finish. Steam starts them again."
            ),
            KnowledgeEntry(
                id: "steam.temp", name: "Steam temporary files", pathPattern: "Library/Application Support/Steam/steamapps/temp",
                owners: steam, kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "Leftovers from installs and updates."
            ),
            KnowledgeEntry(
                id: "steam.appcache", name: "Steam app cache", pathPattern: "Library/Application Support/Steam/appcache",
                owners: steam, kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "Store and library information Steam downloads again on launch."
            ),
            KnowledgeEntry(
                id: "steam.depotcache", name: "Steam download cache", pathPattern: "Library/Application Support/Steam/depotcache",
                owners: steam, kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "Download manifests Steam fetches again."
            ),
            KnowledgeEntry(
                id: "steam.logs", name: "Steam logs", pathPattern: "Library/Application Support/Steam/logs",
                owners: steam, kind: .log, verdict: .safe, action: .remove,
                regenerates: "Steam writes new ones as it runs."
            ),
            KnowledgeEntry(
                id: "epic.games", name: "Epic Games installs", pathPattern: "/Users/Shared/Epic Games", owners: epic,
                kind: .userData, verdict: .caution,
                regenerates: "Games installed with the Epic Games Launcher. They download again from it.",
                guidance: "Uninstall games from the Epic Games Launcher's Library."
            ),
            KnowledgeEntry(
                id: "epic.webcache", name: "Epic Games Launcher web cache",
                pathPattern: "Library/Application Support/Epic/EpicGamesLauncher/Saved/webcache*", owners: epic,
                kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "Store pages the launcher cached. It fills again as you browse."
            ),
            KnowledgeEntry(
                id: "epic.caches", name: "Epic Games Launcher cache", pathPattern: "Library/Caches/com.epicgames.EpicGamesLauncher",
                owners: epic, kind: .cache, verdict: .quitFirst, action: .remove,
                regenerates: "The launcher rebuilds it."
            ),
        ]
}
