import Foundation
import Testing
@testable import Ballast

/// The knowledge base: every recognized location gets a specific verdict
/// and a plain reason, and the general rules only cover the rest.
@Suite struct KnowledgeTests {
    let home = NSHomeDirectory()
    let nobody = AppInventory(running: [], installed: [])

    private func verdict(_ relative: String, directory: Bool = true, apps: AppInventory? = nil) -> Safety {
        SafetyCheck.assess(home + relative, isDirectory: directory, apps: apps ?? nobody, protected: [])
    }

    private func absolute(_ path: String) -> Safety {
        SafetyCheck.assess(path, isDirectory: true, apps: nobody, protected: [])
    }

    // MARK: The table itself

    @Test func entriesAreWellFormed() {
        let ids = Knowledge.entries.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate ids: \(Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
        for entry in Knowledge.entries {
            #expect(!entry.name.isEmpty && !entry.regenerates.isEmpty, "\(entry.id)")
            #expect(entry.regenerates.hasSuffix("."), "\(entry.id) regenerates should be a sentence")
            #expect(!entry.pathPattern.hasSuffix("/") && !entry.pathPattern.contains("//"), "\(entry.id)")
            #expect(!entry.pathPattern.split(separator: "/").contains(".."), "\(entry.id)")
            #expect(entry.owners.allSatisfy { $0.count >= 3 }, "\(entry.id)")
            // Nothing blocked is removed by Ballast; at most a tool's own command.
            if entry.verdict == .blocked, let action = entry.action {
                guard case .command = action else {
                    Issue.record("\(entry.id) is blocked but removes files")
                    continue
                }
            }
            if entry.neverTouch { #expect(entry.verdict == .blocked, "\(entry.id)") }
        }
    }

    @Test func mostSpecificEntryWins() throws {
        // Apple Music downloads sit inside the blocked Music library folder.
        let downloads = try #require(Knowledge.lookup(path: home + "/Music/Music/Media.localized/Apple Music/Album/1.m4p"))
        #expect(downloads.entry.id == "music.apple-music-downloads")
        #expect(downloads.isInside)
        #expect(downloads.matchedPath == home + "/Music/Music/Media.localized/Apple Music")
        // A named app beats the generic pattern for any app.
        #expect(Knowledge.lookup(path: home + "/Library/Caches/com.spotify.client")?.entry.id == "spotify.cache")
        let generic = try #require(Knowledge.lookup(path: home + "/Library/Caches/com.example.editor/data"))
        #expect(generic.entry.id == "app.caches")
        #expect(generic.captures == ["com.example.editor"])
        // Synced data beats anything more specific inside it.
        #expect(Knowledge.lookup(path: home + "/Library/Application Support/Google/DriveFS/123/Cache")?.entry.id == "cloud.drivefs")
    }

    @Test func explainsWhatAFolderIs() throws {
        let entry = try #require(Knowledge.explain(path: home + "/Music/Music/Media.localized/Apple Music"))
        #expect(entry.name == "Apple Music downloads")
        #expect(entry.guidance?.contains("Remove Download") == true)
        let backup = try #require(Knowledge.explain(path: home + "/Library/Application Support/MobileSync/Backup/00008110-001A"))
        #expect(backup.needsFullDiskAccess)
        #expect(backup.kind == .backup)
        #expect(Knowledge.explain(path: home + "/projects/app/src") == nil)
        #expect(Knowledge.explain(path: "relative/path") == nil)
    }

    // MARK: One representative per domain

    @Test(arguments: [
        // Music
        ("/Music/Music/Music Library.musiclibrary", Safety.Level.blocked),
        ("/Music/Music", .blocked),
        ("/Music/Music/Media.localized/Apple Music", .caution),
        ("/Music/iTunes/Previous iTunes Libraries", .safe),
        ("/Music/iTunes/Album Artwork/Cache", .safe),
        ("/Library/Caches/com.apple.Music", .safe),
        ("/Library/Group Containers/243LU875E5.groups.com.apple.podcasts", .caution),
        ("/Library/Application Support/Spotify/PersistentCache", .caution),
        ("/Library/Caches/com.spotify.client", .safe),
        ("/Music/Ableton", .caution),
        // Any app
        ("/Library/HTTPStorages/com.example.app", .caution),
        ("/Library/WebKit/com.example.app", .caution),
        ("/Library/Saved Application State/com.example.app.savedState", .safe),
        ("/Library/Containers/com.example.app/Data/Library/Caches", .safe),
        ("/Library/Group Containers/ABCDE12345.com.example.app/Library/Caches", .safe),
        ("/Library/Application Support/SomeElectronApp/Code Cache", .safe),
        ("/Library/Application Support/SomeElectronApp/Service Worker/CacheStorage", .safe),
        // Browsers
        ("/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", .caution),
        ("/Library/Application Support/Google/Chrome/Default/GPUCache", .safe),
        ("/Library/Application Support/Google/Chrome/Default", .blocked),
        ("/Library/Application Support/Microsoft Edge/Profile 1/Service Worker/CacheStorage", .safe),
        ("/Library/Application Support/BraveSoftware/Brave-Browser/Default/Bookmarks", .blocked),
        ("/Library/Caches/Firefox/Profiles/abc.default-release/cache2", .safe),
        ("/Library/Application Support/Firefox/Profiles/abc.default-release/storage/default", .caution),
        ("/Library/Containers/com.apple.Safari/Data/Library/Caches", .safe),
        // Messaging
        ("/Library/Application Support/Slack/Cache", .safe),
        ("/Library/Application Support/Slack/storage", .blocked),
        ("/Library/Application Support/discord/Code Cache", .safe),
        ("/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable/account-1/postbox/media", .blocked),
        ("/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media", .caution),
        // Xcode, iPhone and iPad
        ("/Library/Developer/Xcode/macOS DeviceSupport", .safe),
        ("/Library/Developer/Xcode/visionOS DeviceSupport/2.0", .safe),
        ("/Library/Developer/CoreSimulator/Caches", .safe),
        ("/Library/Developer/Xcode/iOS Device Logs", .safe),
        ("/Library/Developer/Xcode/DocumentationCache", .safe),
        ("/Library/Application Support/MobileSync/Backup/00008110-001A", .caution),
        ("/Library/Application Support/MobileSync/Backup/00008110-001A/Manifest.db", .blocked),
        ("/Library/Application Support/MobileSync", .blocked),
        ("/Library/iTunes/iPhone Software Updates/iPhone15,2_18.0_Restore.ipsw", .safe),
        // Apple apps
        ("/Library/Containers/com.apple.mail/Data/Library/Mail Downloads", .safe),
        ("/Library/Messages/Attachments", .blocked),
        ("/Pictures/Photos Library.photoslibrary", .caution),
        ("/Pictures/Photos Library.photoslibrary/database", .blocked),
        // Creative apps, editors, games
        ("/Library/Application Support/Adobe/Common/Media Cache Files", .safe),
        ("/Pictures/Lightroom/Lightroom Catalog Previews.lrdata", .caution),
        ("/Pictures/Lightroom/Lightroom Catalog.lrcat", .blocked),
        ("/Library/Application Support/Code/CachedData", .safe),
        ("/Library/Application Support/Code/CachedExtensionVSIXs", .safe),
        ("/Library/Application Support/Code/logs", .safe),
        ("/Library/Application Support/Code/User/workspaceStorage", .caution),
        ("/Library/Application Support/Cursor/CachedData", .safe),
        ("/Library/Application Support/Steam/steamapps/shadercache", .safe),
        ("/Library/Application Support/Steam/steamapps/common/Game", .blocked),
        // Developer tools and models
        ("/.cache/uv", .safe),
        ("/.cache/lm-studio", .caution),
        ("/.cache/torch/hub", .caution),
        ("/.cache/whisper", .caution),
        ("/Library/Caches/ms-playwright", .safe),
        ("/.cache/puppeteer", .safe),
        ("/Library/Caches/Mozilla.sccache", .safe),
        ("/Library/Unity/cache", .safe),
        ("/.pyenv/versions/3.12.1", .caution),
        ("/.nvm/versions/node/v20.11.0", .caution),
        ("/.pub-cache/hosted", .safe),
        ("/Library/Containers/com.docker.docker", .blocked),
        // Cloud sync: never
        ("/Library/Application Support/Google/DriveFS/123/content_cache", .blocked),
        ("/Library/Caches/com.apple.bird", .blocked),
        ("/Library/Caches/CloudKit", .blocked),
        ("/Library/Caches/com.apple.nsurlsessiond", .blocked),
        ("/Library/Application Support/FileProvider/abc", .blocked),
        ("/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite", .blocked),
    ])
    func verdictPerDomain(_ path: String, _ expected: Safety.Level) {
        let safety = verdict(path)
        #expect(safety.level == expected, "\(path): \(safety.reason)")
        #expect(!safety.reason.isEmpty)
    }

    @Test func reasonsArePlainAndSpecific() {
        #expect(verdict("/Music/Music/Media.localized/Apple Music").reason.contains("Remove Download"))
        #expect(verdict("/Library/HTTPStorages/com.example.app").reason.contains("signs you out"))
        #expect(verdict("/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable/account-1/postbox/media")
            .reason.contains("Data and Storage"))
        #expect(verdict("/Library/Messages/Attachments").reason.contains("Keep messages"))
        #expect(verdict("/Pictures/Photos Library.photoslibrary").reason.contains("Optimize Mac Storage"))
        #expect(absolute("/Library/Application Support/GarageBand").reason.contains("Sound Library"))
    }

    @Test func runningOwnersMustQuitFirst() {
        let music = RunningApp(name: "Music", bundleID: "com.apple.Music", pid: 1, bundlePath: "/System/Applications/Music.app")
        let slack = RunningApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", pid: 2, bundlePath: "/Applications/Slack.app")
        let apps = AppInventory(running: [music, slack], installed: [])
        #expect(verdict("/Library/Caches/com.apple.Music", apps: apps).level == .quitFirst)
        #expect(verdict("/Library/Application Support/Slack/Cache", apps: apps).app?.bundleID == slack.bundleID)
        // Generic patterns find the app through the folder name.
        let editor = RunningApp(name: "Editor", bundleID: "com.example.editor", pid: 3, bundlePath: "/Applications/Editor.app")
        #expect(verdict("/Library/Caches/com.example.editor", apps: AppInventory(running: [editor], installed: [])).level == .quitFirst)
        // Old library copies aren't used by Music.
        #expect(verdict("/Music/iTunes/Previous iTunes Libraries", apps: apps).level == .safe)
    }

    @Test func sharedSoundLibrariesOutsideHomeAreOnlyEverCaution() {
        #expect(absolute("/Library/Application Support/GarageBand").level == .caution)
        #expect(absolute("/Library/Application Support/Logic/Alchemy").level == .caution)
        #expect(absolute("/Library/Audio/Apple Loops/Apple/01 Hip Hop").level == .caution)
        // The rest of /Library stays protected, and the system is untouched.
        #expect(absolute("/Library/Application Support/SomethingElse").level == .blocked)
        #expect(absolute("/Library/Audio/Plug-Ins").level == .blocked)
        #expect(absolute("/usr/local/Homebrew").level == .blocked)
        #expect(absolute("/Library/Developer/CoreSimulator/Volumes/iOS_22A").level == .blocked)
    }

    @Test func emptyingAFolderKeepsWhatKnowledgeProtects() {
        #expect(Catalog.keptWhenEmptying.contains(home + "/Library/Caches/com.apple.bird"))
        #expect(Catalog.keptWhenEmptying.contains(home + "/Library/Caches/CloudKit"))
        #expect(Catalog.keptWhenEmptying.contains(home + "/.cache/torch"))
        // Safe caches inside are still emptied with the folder.
        #expect(!Catalog.keptWhenEmptying.contains(home + "/Library/Caches/com.spotify.client"))
        #expect(Catalog.covers(home + "/Library/Caches", action: .contents, home + "/Library/Caches/com.spotify.client"))
        #expect(!Catalog.covers(home + "/Library/Caches", action: .contents, home + "/Library/Caches/com.apple.bird/x"))
    }

    // MARK: Versioned folders

    @Test func olderVersionFoldersAreRecognized() {
        let siblings = ["PyCharm2023.3", "PyCharm2024.2", "PyCharmCE2024.1", "IntelliJIdea2024.1", "consentOptions"]
        #expect(VersionedFolder.newer(than: "PyCharm2023.3", among: siblings) == "PyCharm2024.2")
        #expect(VersionedFolder.newer(than: "PyCharm2024.2", among: siblings) == nil)
        #expect(VersionedFolder.newer(than: "PyCharmCE2024.1", among: siblings) == nil)
        #expect(VersionedFolder.newer(than: "consentOptions", among: siblings) == nil)
        #expect(VersionedFolder.newer(than: "AndroidStudio2023.1", among: ["AndroidStudio2023.1", "AndroidStudio2024.2.1"])
            == "AndroidStudio2024.2.1")
        #expect(VersionedFolder.parse("Toolbox") == nil)
        #expect(VersionedFolder.parse("WebStorm2024.1")?.version == [2024, 1])
    }
}

/// Library bundles (Photos, Music, Final Cut, Logic…) and the folders that
/// hold your own files.
@Suite struct LibraryBundleTests {
    let home = NSHomeDirectory()
    let nobody = AppInventory(running: [], installed: [])

    private func level(_ path: String) -> Safety.Level {
        SafetyCheck.assess(path, isDirectory: true, apps: nobody, protected: []).level
    }

    @Test(arguments: ["photoslibrary", "photolibrary", "aplibrary", "musiclibrary", "tvlibrary", "fcpbundle",
                      "imovielibrary", "logicx", "band", "lrcat", "photoboothlibrary"])
    func bundleIsCautionAndInsideIsBlocked(_ ext: String) {
        let bundle = home + "/Projects-\(ext)/Library.\(ext)"
        #expect(level(bundle) == .caution)
        #expect(level(bundle + "/Contents/data") == .blocked)
        #expect(SafetyCheck.isPartOfLibraryBundle(bundle))
        #expect(SafetyCheck.isPartOfLibraryBundle(bundle + "/Contents"))
    }

    @Test func libraryBundleHelpers() throws {
        let inside = try #require(SafetyCheck.libraryBundle(in: "/Users/me/Movies/Trip.fcpbundle/Render Files/x"))
        #expect(inside.path == "/Users/me/Movies/Trip.fcpbundle")
        #expect(inside.app == "Final Cut Pro")
        #expect(inside.isInside)
        #expect(SafetyCheck.libraryBundle(in: "/Users/me/Music/Song.BAND")?.isInside == false)
        #expect(!SafetyCheck.isPartOfLibraryBundle("/Users/me/Music/Bands"))
        #expect(!SafetyCheck.isPartOfLibraryBundle("/Users/me/Movies"))
    }

    @Test func knownLibrariesKeepTheirOwnVerdict() {
        // The Music database is never removable, even though bundles are caution.
        #expect(level(home + "/Music/Music/Music Library.musiclibrary") == .blocked)
        #expect(level(home + "/Movies/Trip.fcpbundle") == .caution)
        #expect(SafetyCheck.assess(home + "/Movies/Trip.fcpbundle/Render Files", isDirectory: true, apps: nobody, protected: [])
            .reason.contains("Delete Generated Library Files"))
    }

    @Test func librariesOutsideHomeAndOnOtherDrives() {
        #expect(level("/Users/Shared/Family.photoslibrary/originals") == .blocked)
        #expect(level("/Users/Shared/Family.photoslibrary") == .caution)
        let drive = DriveFacts(mountPath: "/Volumes/Archive", name: "Archive")
        #expect(SafetyCheck.drive(drive, rules: "/Volumes/Archive/Old.photoslibrary/originals", isDirectory: true).level == .blocked)
        #expect(SafetyCheck.drive(drive, rules: "/Volumes/Archive/Old.musiclibrary", isDirectory: true).level == .caution)
    }

    @Test func folderHoldingALibraryNeedsATick() throws {
        let parent = URL(fileURLWithPath: home).appending(path: "ballast-test-\(UUID().uuidString)")
        let holder = parent.appending(path: "Old Stuff")
        try FileManager.default.createDirectory(at: holder.appending(path: "Trip.imovielibrary"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let verdict = SafetyCheck.assess(holder.path, isDirectory: true, apps: nobody, protected: [])
        #expect(verdict.level == .caution)
        #expect(verdict.reason.contains("Trip.imovielibrary"))
    }

    // MARK: Personal folders

    @Test(arguments: ["/Documents/Old Thesis", "/Desktop/Folder", "/Music/Recordings", "/Movies/Holiday",
                      "/Pictures/Scans", "/Documents/notes.txt"])
    func personalFilesNeedATick(_ relative: String) {
        let verdict = SafetyCheck.assess(home + relative, isDirectory: !relative.hasSuffix(".txt"), apps: nobody, protected: [])
        #expect(verdict.level == .caution)
        #expect(verdict.reason != "Your own files.")
    }

    @Test func otherHomeFoldersKeepTheirVerdicts() {
        // The personal-folder rule is a fallback, not a blanket.
        #expect(SafetyCheck.assess(home + "/projects/scratch", isDirectory: true, apps: nobody, protected: []).level == .safe)
        #expect(SafetyCheck.assess(home + "/Desktop/Installer.dmg", isDirectory: false, apps: nobody, protected: []).level == .safe)
        #expect(SafetyCheck.assess(home + "/Documents", isDirectory: true, apps: nobody, protected: []).level == .blocked)
    }
}

/// Build output: what `Catalog.isProjectArtifact` recognizes, and which of
/// it needs a tick because a rebuild may not bring everything back.
@Suite struct ProjectArtifactTests {
    private func project(_ files: [String], dirs: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ballast-artifact-\(UUID().uuidString)")
        for dir in dirs { try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true) }
        for file in files { try Data().write(to: root.appending(path: file)) }
        return root
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let folder: String
        let files: [String]
        var dirs: [String] = []
        var testDescription: String { folder }
    }

    static let regenerable: [Case] = [
        Case(folder: "node_modules", files: ["package.json"]),
        Case(folder: ".next", files: ["next.config.js"]),
        Case(folder: ".turbo", files: ["turbo.json"]),
        Case(folder: ".parcel-cache", files: ["package.json"]),
        Case(folder: "target", files: ["Cargo.toml"]),
        Case(folder: ".build", files: ["Package.swift"]),
        Case(folder: ".gradle", files: ["settings.gradle.kts"]),
        Case(folder: "__pycache__", files: []),
        Case(folder: ".dart_tool", files: ["pubspec.yaml"]),
        Case(folder: "_build", files: ["mix.exs"]),
        Case(folder: "obj", files: ["App.csproj"]),
        Case(folder: "DerivedData", files: ["App.xcodeproj"], dirs: ["DerivedData/Build"]),
        Case(folder: "DerivedData", files: ["Package.swift"], dirs: ["DerivedData/ModuleCache.noindex"]),
    ]

    @Test(arguments: regenerable)
    func recognizesRegenerableBuildOutput(_ c: Case) throws {
        let root = try project(c.files, dirs: [c.folder] + c.dirs)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appending(path: c.folder)
        #expect(Catalog.isProjectArtifact(dir))
        #expect(SafetyCheck.buildOutput(dir.path, apps: nil)?.level == .safe)
    }

    @Test func derivedDataNeedsAProjectAndXcodesLayout() throws {
        let noProject = try project([], dirs: ["DerivedData/Build"])
        let empty = try project(["App.xcodeproj"], dirs: ["DerivedData/notes"])
        defer { for root in [noProject, empty] { try? FileManager.default.removeItem(at: root) } }
        #expect(!Catalog.isProjectArtifact(noProject.appending(path: "DerivedData")))
        #expect(!Catalog.isProjectArtifact(empty.appending(path: "DerivedData")))
    }

    @Test func venvNeedsALockfileToBeSafe() throws {
        let bare = try project([".venv/pyvenv.cfg"], dirs: [".venv"])
        let locked = try project([".venv/pyvenv.cfg", "uv.lock"], dirs: [".venv"])
        let pinned = try project(["venv/pyvenv.cfg", "requirements-dev.txt"], dirs: ["venv"])
        defer { for root in [bare, locked, pinned] { try? FileManager.default.removeItem(at: root) } }
        #expect(SafetyCheck.buildOutput(bare.appending(path: ".venv").path, apps: nil)?.level == .caution)
        #expect(SafetyCheck.buildOutput(locked.appending(path: ".venv").path, apps: nil)?.level == .safe)
        #expect(SafetyCheck.buildOutput(pinned.appending(path: "venv").path, apps: nil)?.level == .safe)
    }

    @Test func podsAreSafeOnlyWhenGitIgnoresThem() throws {
        let committed = try project(["Podfile"], dirs: ["Pods", ".git"])
        let ignored = try project(["Podfile"], dirs: ["Pods", ".git"])
        try Data("Pods/\n".utf8).write(to: ignored.appending(path: ".gitignore"))
        defer { for root in [committed, ignored] { try? FileManager.default.removeItem(at: root) } }
        #expect(SafetyCheck.buildOutput(committed.appending(path: "Pods").path, apps: nil)?.level == .caution)
        #expect(SafetyCheck.buildOutput(ignored.appending(path: "Pods").path, apps: nil)?.level == .safe)
    }

    @Test func handPatchableDependenciesNeedATick() throws {
        let php = try project(["composer.json"], dirs: ["vendor", ".git"])
        try Data("vendor/\n".utf8).write(to: php.appending(path: ".gitignore"))
        let elixir = try project(["mix.exs"], dirs: ["deps", "_build"])
        defer { for root in [php, elixir] { try? FileManager.default.removeItem(at: root) } }
        #expect(SafetyCheck.buildOutput(php.appending(path: "vendor").path, apps: nil)?.level == .caution)
        #expect(SafetyCheck.buildOutput(elixir.appending(path: "deps").path, apps: nil)?.level == .caution)
        #expect(SafetyCheck.buildOutput(elixir.appending(path: "_build").path, apps: nil)?.level == .safe)
        // Still recognized as build output: only the default tick changes.
        #expect(Catalog.isProjectArtifact(elixir.appending(path: "deps")))
    }

    @Test func lookalikesAreNotBuildOutput() throws {
        let root = try project(["README.md"], dirs: ["target", "build", "DerivedData/Build", "Pods"])
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["target", "build", "DerivedData", "Pods"] {
            #expect(!Catalog.isProjectArtifact(root.appending(path: name)), "\(name)")
            #expect(SafetyCheck.buildOutput(root.appending(path: name).path, apps: nil) == nil, "\(name)")
        }
    }
}

/// Suggestions keep their identity across reloads.
@Suite struct StableIdentityTests {
    @Test func targetsAndResultsAreIdentifiedByPath() {
        let first = Target(name: "Cache", path: "/Users/me/Library/Caches", category: .caches, action: .contents)
        let again = Target(name: "Cache", path: "/Users/me/Library/Caches", category: .caches, action: .contents)
        #expect(first.id == again.id)
        #expect(first.id == "/Users/me/Library/Caches")
        let result = ScanResult(target: first, bytes: 10)
        let reloaded = ScanResult(target: again, bytes: 20)
        #expect(result.id == reloaded.id)
        #expect(Target(name: "Other", path: "/Users/me/.npm", category: .caches, action: nil).id != first.id)
    }

    @Test func catalogTargetsHaveUniqueIDs() {
        let ids = Catalog.targets.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func newCatalogTargetsAreCleanable() {
        let nobody = AppInventory(running: [], installed: [])
        for target in Catalog.targets where target.action == .remove {
            let item = PlanItem.assess(name: target.name, path: target.path, bytes: 1, action: .remove, isDirectory: true,
                                       apps: nobody, protected: [])
            #expect(item.safety.level != .blocked, "\(target.name): \(item.safety.reason)")
        }
    }
}

/// "Clear Slack's cache (1.2 GB)": per-app cache folders over a fake disk.
@Suite struct AppCacheBreakdownTests {
    let library = "/fake/Library"

    /// A disk made of `folders` (path → size); parents exist implicitly.
    private func disk(_ folders: [String: Int64], containers: [String: String] = [:]) -> AppCacheFileSystem {
        var all = Set<String>()
        for path in folders.keys {
            var current = path
            while current.count > 1 {
                all.insert(current)
                current = (current as NSString).deletingLastPathComponent
            }
        }
        let existing = all
        return AppCacheFileSystem(
            exists: { existing.contains($0) },
            children: { parent in
                existing.filter { ($0 as NSString).deletingLastPathComponent == parent }.map { ($0 as NSString).lastPathComponent }
            },
            size: { path in folders.filter { $0.key == path || $0.key.hasPrefix(path + "/") }.values.reduce(0, +) },
            containerIdentifier: { containers[$0] }
        )
    }

    private func app(_ name: String, _ id: String, groups: [String] = []) -> AppBundle {
        AppBundle(path: "/Applications/\(name).app", name: name, bundleID: id, groups: groups)
    }

    @Test func slackCachesOnlyRegenerableParts() {
        let slack = app("Slack", "com.tinyspeck.slackmacgap", groups: ["BQR82RBBHL.com.tinyspeck.slackmacgap"])
        let fs = disk([
            "\(library)/Caches/com.tinyspeck.slackmacgap/data": 100,
            "\(library)/Application Support/Slack/Cache/data": 1_000,
            "\(library)/Application Support/Slack/Code Cache/js": 300,
            "\(library)/Application Support/Slack/Service Worker/CacheStorage/x": 50,
            "\(library)/Application Support/Slack/storage/db": 9_000,
            "\(library)/Application Support/Slack/Cookies": 1,
            "\(library)/HTTPStorages/com.tinyspeck.slackmacgap/cookies": 7,
            "\(library)/WebKit/com.tinyspeck.slackmacgap/WebsiteData": 7,
            "\(library)/Saved Application State/com.tinyspeck.slackmacgap.savedState/windows": 2,
            "\(library)/Group Containers/BQR82RBBHL.com.tinyspeck.slackmacgap/Library/Caches/x": 20,
            "\(library)/Containers/com.tinyspeck.slackmacgap/Data/Library/Caches/x": 5,
        ])
        let folders = AppCaches.folders(for: slack, others: [slack], library: library, fs: fs)
        let paths = Set(folders.map(\.path))
        #expect(paths == [
            "\(library)/Caches/com.tinyspeck.slackmacgap",
            "\(library)/Application Support/Slack/Cache",
            "\(library)/Application Support/Slack/Code Cache",
            "\(library)/Application Support/Slack/Service Worker/CacheStorage",
            "\(library)/Saved Application State/com.tinyspeck.slackmacgap.savedState",
            "\(library)/Group Containers/BQR82RBBHL.com.tinyspeck.slackmacgap/Library/Caches",
            "\(library)/Containers/com.tinyspeck.slackmacgap/Data/Library/Caches",
        ])
        #expect(folders.first?.path == "\(library)/Application Support/Slack/Cache")
        #expect(folders.first?.bytes == 1_000)

        let breakdown = AppCaches.breakdown(apps: [slack], library: library, fs: fs)
        #expect(breakdown.count == 1)
        #expect(breakdown.first?.bytes == 1_477)
        #expect(breakdown.first?.title == "Clear Slack's cache")
        #expect(breakdown.first?.appPath == "/Applications/Slack.app")
    }

    @Test func knowledgeAddsNamedCachesAndExpandsWildcards() {
        let chrome = app("Google Chrome", "com.google.Chrome")
        let fs = disk([
            "\(library)/Caches/Google/Chrome/Default/Cache/x": 400,
            "\(library)/Application Support/Google/Chrome/Default/GPUCache/x": 30,
            "\(library)/Application Support/Google/Chrome/Profile 1/Code Cache/x": 20,
            "\(library)/Application Support/Google/Chrome/Default/History": 999,
            "\(library)/Application Support/Google/Chrome/OptGuideOnDeviceModel/model": 4_000,
        ])
        let folders = AppCaches.folders(for: chrome, others: [chrome], library: library, fs: fs)
        let paths = Set(folders.map(\.path))
        #expect(paths.contains("\(library)/Caches/Google/Chrome"))
        #expect(paths.contains("\(library)/Application Support/Google/Chrome/Default/GPUCache"))
        #expect(paths.contains("\(library)/Application Support/Google/Chrome/Profile 1/Code Cache"))
        // The on-device model is caution, and history is your data.
        #expect(!paths.contains { $0.contains("OptGuideOnDeviceModel") || $0.hasSuffix("History") })
        #expect(folders.first { $0.path.hasSuffix("/Caches/Google/Chrome") }?.knowledgeID == "chrome.caches")
    }

    @Test func sharedFoldersAndDuplicatesAreLeftOut() {
        let word = app("Microsoft Word", "com.microsoft.Word", groups: ["UBF8T346G9.Office"])
        let excel = app("Microsoft Excel", "com.microsoft.Excel", groups: ["UBF8T346G9.Office"])
        let copy = AppBundle(path: "/Users/me/Applications/Microsoft Word.app", name: "Microsoft Word",
                             bundleID: "com.microsoft.Word", groups: [])
        let fs = disk([
            "\(library)/Group Containers/UBF8T346G9.Office/Library/Caches/x": 50,
            "\(library)/Caches/com.microsoft.Word/x": 10,
            "\(library)/Caches/com.microsoft.Excel/x": 5,
        ])
        let breakdown = AppCaches.breakdown(apps: [word, excel, copy], library: library, fs: fs)
        #expect(breakdown.map(\.bundleID) == ["com.microsoft.Word", "com.microsoft.Excel"])
        #expect(!breakdown.flatMap(\.folders).contains { $0.path.contains("UBF8T346G9.Office") })
        #expect(AppCaches.breakdown(apps: [word, excel], library: library, fs: fs, minimumBytes: 8).map(\.bundleID)
            == ["com.microsoft.Word"])
    }

    @Test func uuidContainersNeedMetadataPermission() {
        let notes = app("Notes Plus", "com.example.notes")
        let container = "\(library)/Containers/5A1B2C3D-0000-4000-8000-000000000001"
        let fs = disk(["\(container)/Data/Library/Caches/x": 70], containers: [container: "com.example.notes"])
        #expect(AppCaches.folders(for: notes, others: [notes], library: library, fs: fs).isEmpty)
        let found = AppCaches.folders(for: notes, others: [notes], library: library, fs: fs, readContainerMetadata: true)
        #expect(found.map(\.path) == ["\(container)/Data/Library/Caches"])
    }
}
