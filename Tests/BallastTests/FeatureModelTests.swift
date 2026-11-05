import Darwin
import Foundation
import Testing
import os
@testable import Ballast

/// A disk made of `folders` (path → bytes); parents exist implicitly.
private func fakeDisk(_ folders: [String: Int64]) -> AppCacheFileSystem {
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
        containerIdentifier: { _ in nil }
    )
}

// MARK: - Per-app caches

@Suite struct AppCacheModelTests {
    let library = "/fake/Library"

    private var userCaches: [Target] {
        [Target(name: "User caches", path: library + "/Caches", category: .caches, action: .contents)]
    }

    private var slack: AppBundle {
        AppBundle(path: "/Applications/Slack.app", name: "Slack", bundleID: "com.tinyspeck.slackmacgap", groups: [])
    }

    /// Folders in ~/Library/Caches are counted by User caches already: the
    /// breakdown still frees them, but a section total leaves them out.
    @Test func coveredFoldersAreMarkedAndLeftOutOfTotals() throws {
        let fs = fakeDisk([
            "\(library)/Caches/com.tinyspeck.slackmacgap/data": 100,
            "\(library)/Application Support/Slack/Cache/data": 1_000,
            "\(library)/Application Support/Slack/Code Cache/js": 300,
        ])
        let breakdown = try #require(AppCaches.breakdown(apps: [slack], library: library, fs: fs, targets: userCaches).first)
        #expect(breakdown.bytes == 1_400)
        #expect(breakdown.uncoveredBytes == 1_300)
        let cache = try #require(breakdown.folders.first { $0.path.hasSuffix("/Caches/com.tinyspeck.slackmacgap") })
        #expect(cache.coveredBy == library + "/Caches")
        #expect(breakdown.folders.filter { $0.coveredBy == nil }.count == 2)
        // Nothing covers anything without Suggestions entries.
        #expect(AppCaches.breakdown(apps: [slack], library: library, fs: fs, targets: []).first?.uncoveredBytes == 1_400)
    }

    @Test func planCandidatesNameTheAppAndUseTheKnowledgeAction() throws {
        let fs = fakeDisk([
            "\(library)/Caches/com.tinyspeck.slackmacgap/data": 100,
            "\(library)/Application Support/Slack/Cache/data": 1_000,
        ])
        let breakdown = try #require(AppCaches.breakdown(apps: [slack], library: library, fs: fs).first)
        let candidates = breakdown.planCandidates
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.action == .remove && $0.isDirectory })
        #expect(candidates.contains { $0.name == "Slack: Cache" && $0.bytes == 100 })
        // A knowledge name that already says whose it is stays as it is.
        let spotify = AppCacheFolder(path: "/x", label: "Spotify's cache", bytes: 1, knowledgeID: "spotify.cache")
        #expect(spotify.title(appName: "Spotify") == "Spotify's cache")
    }

    @Test func knowledgeSaysWhichFoldersAreEmptiedInPlace() {
        let home = NSHomeDirectory()
        // Xcode's DerivedData is emptied, never removed.
        #expect(AppCaches.action(for: home + "/Library/Developer/Xcode/DerivedData", knowledgeID: nil, home: home) == .contents)
        #expect(AppCaches.action(for: home + "/Library/Caches/com.spotify.client", knowledgeID: "spotify.cache", home: home) == .remove)
        // Something inside an emptied folder is removed as itself.
        #expect(AppCaches.action(for: home + "/Library/Developer/Xcode/DerivedData/App-abc", knowledgeID: nil, home: home) == .remove)
    }

    @Test func coveringTargetMatchesTheSameFolderAndWhatItEmpties() {
        let targets = userCaches + [Target(name: "Yarn", path: library + "/Caches/Yarn", category: .caches, action: .remove),
                                    Target(name: "Claude", path: library + "/Application Support/Claude", category: .appData, action: nil)]
        #expect(AppCaches.coveringTarget(library + "/Caches/Yarn", targets: targets) != nil)
        #expect(AppCaches.coveringTarget(library + "/Caches/com.example", targets: targets) == library + "/Caches")
        // Review-only entries (no action) don't clean anything.
        #expect(AppCaches.coveringTarget(library + "/Application Support/Claude/Cache", targets: targets) == nil)
        #expect(AppCaches.coveringTarget(library + "/Caches", targets: targets) == library + "/Caches")
    }
}

// MARK: - Index-backed sizing

/// A temp folder indexed as its own volume, as in IndexEngineTests.
private struct IndexedFolder {
    let base: URL
    let root: URL
    let index: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "ballast-feature-\(UUID().uuidString)")
        root = base.appending(path: "Drive")
        index = base.appending(path: "index/index.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    func path(_ relative: String) -> String { root.path + "/" + relative }

    func write(_ relative: String, bytes: Int) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    func scan() throws {
        var st = stat()
        lstat(root.path, &st)
        let uuid = try #require(try root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        let volume = MountedVolume(uuid: uuid, name: "Test", path: root.path, format: "APFS", isReadOnly: false,
                                   isJournaled: true, isRemovable: true, total: 0, free: 0, device: st.st_dev)
        let target = IndexTarget(index: index.path, root: root.path, device: st.st_dev, volume: volume)
        try ScanEngine.fullScan(target, report: { _ in }, cancel: CancelFlag())
    }

    func indexedTotal(_ relative: String) throws -> Int64 {
        let found = try #require(try IndexDB(path: index.path, mode: .read).locate(path(relative)).last)
        #expect(found.path == path(relative))
        return found.row.total
    }
}

@Suite struct IndexedSizingTests {
    /// Indexed folders are one lookup; only what the index doesn't hold
    /// (made since the scan) is walked.
    @Test func sizesComeFromTheIndexAndFallBackToWalking() throws {
        let drive = try IndexedFolder()
        defer { drive.remove() }
        try drive.write("Library/Caches/com.tinyspeck.slackmacgap/data", bytes: 100_000)
        try drive.write("Library/Application Support/Slack/Cache/data", bytes: 300_000)
        try drive.scan()
        try drive.write("Library/Application Support/Slack/Code Cache/js", bytes: 50_000)

        let lookup = try #require(IndexLookup(index: drive.index.path, isStartup: false))
        #expect(lookup.size(of: drive.path("Library/Application Support/Slack/Cache")) == (try drive.indexedTotal("Library/Application Support/Slack/Cache")))
        #expect(lookup.size(of: drive.path("Library/Application Support/Slack/Code Cache")) == nil)
        #expect(lookup.childNames(of: drive.path("Library/Application Support/Slack"))?.sorted() == ["Cache"])

        let walked = OSAllocatedUnfairLock<[String]>(initialState: [])
        var fallback = AppCacheFileSystem.live
        let live = fallback.size
        fallback.size = { path in
            walked.withLock { $0.append(path) }
            return live(path)
        }
        let fs = AppCacheFileSystem.indexed(lookup, fallback: fallback)
        let slack = AppBundle(path: "/Applications/Slack.app", name: "Slack", bundleID: "com.tinyspeck.slackmacgap", groups: [])
        let breakdown = try #require(AppCaches.breakdown(apps: [slack], library: drive.path("Library"), fs: fs).first)

        #expect(walked.withLock { $0 } == [drive.path("Library/Application Support/Slack/Code Cache")])
        let cache = try #require(breakdown.folders.first { $0.path == drive.path("Library/Application Support/Slack/Cache") })
        #expect(cache.bytes == (try drive.indexedTotal("Library/Application Support/Slack/Cache")))
        let codeCache = try #require(breakdown.folders.first { $0.path.hasSuffix("/Code Cache") })
        #expect(codeCache.bytes >= 50_000)
        #expect(breakdown.folders.count == 3)
    }

    @Test func noIndexMeansNoLookup() {
        #expect(IndexLookup(index: "/nonexistent/ballast-\(UUID().uuidString).sqlite") == nil)
    }

    @Test func cancelledWalksStopEarly() throws {
        let drive = try IndexedFolder()
        defer { drive.remove() }
        for index in 0..<600 { try drive.write("many/f\(index)", bytes: 10) }
        let cancel = CancelFlag()
        cancel.set()
        #expect(AppCacheFileSystem.allocatedSize(drive.path("many"), cancel: cancel) < AppCacheFileSystem.allocatedSize(drive.path("many")))
    }
}

// MARK: - Music & media

@Suite struct MediaLocationTests {
    let home = "/fake/home"

    private func assess(_ path: String) -> Safety {
        Knowledge.lookup(path: path, home: home).map { Safety(level: $0.level, reason: $0.reason) } ?? .safe("Your own files.")
    }

    private var disk: AppCacheFileSystem {
        fakeDisk([
            "\(home)/Music/Music/Media.localized/Apple Music/Album/1.m4p": 3_000_000_000,
            "\(home)/Music/Music/Media.localized/Music/Artist/2.m4a": 2_000_000_000,
            "\(home)/Music/Music/Music Library.musiclibrary/Library.musicdb": 10_000_000,
            "\(home)/Library/Caches/com.spotify.client/Data/x": 500_000_000,
            "\(home)/Library/Application Support/Spotify/PersistentCache/x": 40_000_000,
            "\(home)/Library/Application Support/Spotify/prefs": 70_000_000,
            "\(home)/Movies/Trip.fcpbundle/Day 1/Render Files/x": 800_000_000,
            "\(home)/Movies/Trip.fcpbundle/Day 1/Original Media/clip.mov": 5_000_000_000,
            "\(home)/Library/Caches/JetBrains/IdeaIC2024.1/x": 1_000_000_000,
            "\(home)/Library/Caches/com.apple.Music/small": 1_000,
        ])
    }

    private func locations(targets: [Target] = []) -> [MediaLocation] {
        let apps = AppInventory(running: [], installed: [InstalledApp(name: "Spotify", bundleID: "com.spotify.client")])
        return MediaLocations.locations(home: home, fs: disk, apps: apps, targets: targets, assess: assess)
    }

    @Test func listsMediaLocationsByTheirOwnSize() {
        let found = locations()
        #expect(found.map(\.knowledgeID) == [
            "video.fcp-library", "music.apple-music-downloads", "music.media", "video.fcp-render-files",
            "spotify.cache", "spotify.data",
        ])
        let library = found[0]
        #expect(library.bytes == 5_800_000_000)
        #expect(library.ownBytes == 5_000_000_000)
        // The Music library itself is only its database once songs are listed: too small for a row.
        #expect(!found.contains { $0.knowledgeID == "music.library-folder" })
        // Editors and games are other sections' business.
        #expect(!found.contains { $0.knowledgeID.hasPrefix("jetbrains.") })
        #expect(found.first { $0.knowledgeID == "music.media" }?.path == "\(home)/Music/Music/Media.localized")
        #expect(found.allSatisfy { $0.id == $0.knowledgeID + "|" + $0.path })
    }

    @Test func onlyCleanableLocationsGoOnTheList() throws {
        let found = locations()
        let spotify = try #require(found.first { $0.knowledgeID == "spotify.cache" })
        #expect(spotify.canAddToPlan)
        #expect(spotify.planCandidate == PlanCandidate(name: "Spotify's cache", path: spotify.path, bytes: 500_000_000, action: .remove))
        #expect(spotify.appName == "Spotify")
        #expect(spotify.kind == .cache)
        // Render files live inside the library: guidance only, with the way to do it in Final Cut Pro.
        let render = try #require(found.first { $0.knowledgeID == "video.fcp-render-files" })
        #expect(render.level == .blocked)
        #expect(render.action == nil && render.planCandidate == nil)
        #expect(render.guidance?.contains("Delete Generated Library Files") == true)
        // Caution without a way to clean it from Ballast: guidance too.
        let downloads = try #require(found.first { $0.knowledgeID == "music.apple-music-downloads" })
        #expect(downloads.level == .caution && !downloads.canAddToPlan)
        #expect(downloads.guidance?.contains("Remove Download") == true)
    }

    @Test func coveredLocationsAreMarked() throws {
        let caches = Target(name: "User caches", path: home + "/Library/Caches", category: .caches, action: .contents)
        let found = locations(targets: [caches])
        #expect(found.first { $0.knowledgeID == "spotify.cache" }?.coveredBy == home + "/Library/Caches")
        #expect(found.first { $0.knowledgeID == "video.fcp-library" }?.coveredBy == nil)
    }

    @Test func wildcardsExpandAgainstTheDisk() {
        let fs = disk
        #expect(MediaLocations.expand("Music/Music/Media*/Apple Music", home: home, fs: fs)
            == ["\(home)/Music/Music/Media.localized/Apple Music"])
        #expect(MediaLocations.expand("Movies/*.fcpbundle/*/Render Files", home: home, fs: fs)
            == ["\(home)/Movies/Trip.fcpbundle/Day 1/Render Files"])
        #expect(MediaLocations.expand("Movies/*.imovielibrary/*/Render Files", home: home, fs: fs).isEmpty)
        #expect(MediaLocations.expand("/Library/Application Support/GarageBand", home: home, fs: fs).isEmpty)
    }

    @Test func cancelledLoadReturnsNothing() {
        let cancel = CancelFlag()
        cancel.set()
        #expect(MediaLocations.locations(home: home, fs: disk, apps: AppInventory(running: [], installed: []),
                                         cancel: cancel, assess: assess).isEmpty)
    }

    @Test func mediaDomainsLeaveEditorsAndGamesOut() {
        let ids = MediaLocations.entries.map(\.id)
        #expect(ids.contains("music.apple-music-downloads") && ids.contains("audio.logic-sounds") && ids.contains("photos.derivatives"))
        #expect(!ids.contains { $0.hasPrefix("vscode.") || $0.hasPrefix("steam.") || $0.hasPrefix("jetbrains.") })
    }
}

// MARK: - Knowledge for "What is this?"

@Suite struct KnowledgeExplanationTests {
    let home = NSHomeDirectory()

    @Test func explainsAFolderAndWhatsInside() async throws {
        let cache = try #require(await Knowledge.explainAsync(path: home + "/Library/Caches/com.spotify.client"))
        #expect(cache.entryID == "spotify.cache")
        #expect(cache.title == "Spotify's cache" && !cache.isInside)
        #expect(cache.kindTitle == "Cache")
        #expect(cache.level == .quitFirst)
        #expect(cache.action == .remove)
        #expect(cache.whenRemoved.contains("fills it again"))

        let song = try #require(Knowledge.explanation(path: home + "/Music/Music/Media.localized/Apple Music/Album/1.m4p"))
        #expect(song.isInside && song.title == "Inside Apple Music downloads")
        #expect(song.matchedPath == home + "/Music/Music/Media.localized/Apple Music")
        #expect(song.action == nil)
        #expect(song.guidance != nil)
        #expect(Knowledge.explanation(path: "relative/path") == nil)
    }

    @Test func manyPathsAtOnce() async {
        let paths = [home + "/Library/Caches/com.spotify.client", "relative/path", home + "/Library/Mail"]
        let found = await Knowledge.explainAsync(paths: paths)
        #expect(Set(found.keys) == [paths[0], paths[2]])
        #expect(found[paths[2]]?.needsFullDiskAccess == true)
        #expect(found[paths[2]]?.level == .blocked && found[paths[2]]?.action == nil)
    }

    @Test func generatedFilesInsideLibrariesAreGuidanceOnly() {
        let nobody = AppInventory(running: [], installed: [])
        let render = home + "/Movies/Trip.fcpbundle/Day 1/Render Files"
        #expect(Knowledge.lookup(path: render)?.entry.id == "video.fcp-render-files")
        let verdict = SafetyCheck.assess(render, isDirectory: true, apps: nobody, protected: [])
        #expect(verdict.level == .blocked)
        #expect(verdict.reason.contains("Delete Generated Library Files"))
        let previews = home + "/Pictures/Photos Library.photoslibrary/resources/derivatives"
        #expect(Knowledge.lookup(path: previews)?.entry.id == "photos.derivatives")
        #expect(SafetyCheck.assess(previews, isDirectory: true, apps: nobody, protected: []).level == .blocked)
        let photos = RunningApp(name: "Photos", bundleID: "com.apple.Photos", pid: 1, bundlePath: "/System/Applications/Photos.app")
        let open = AppInventory(running: [photos], installed: [])
        #expect(SafetyCheck.assess(home + "/Library/Containers/com.apple.Photos/Data/Library/Caches", isDirectory: true,
                                   apps: open, protected: []).level == .quitFirst)
    }
}

// MARK: - Homebrew extras

@Suite struct HomebrewExtrasTests {
    @Test func autoremoveDryRun() {
        let output = """
        ==> Would autoremove 3 unneeded formulae:
        libfoo
        python@3.12
        team/tap/bar-baz

        """
        #expect(Homebrew.parseAutoremove(output) == ["libfoo", "python@3.12", "team/tap/bar-baz"])
        #expect(Homebrew.parseAutoremove("").isEmpty)
        #expect(Homebrew.parseAutoremove("Warning: Skipping aom: most recent version 3.15.3 not installed\n").isEmpty)
    }

    @Test func autoremoveRealRunStopsAtUninstallLines() {
        let output = """
        ==> Autoremoving 2 unneeded formulae:
        libfoo
        libbar
        Uninstalling /opt/homebrew/Cellar/libfoo/1.0... (12 files, 1.2MB)
        Uninstalling /opt/homebrew/Cellar/libbar/2.0... (3 files, 20KB)
        """
        #expect(Homebrew.parseAutoremove(output) == ["libfoo", "libbar"])
    }

    @Test func cleanupDryRun() throws {
        let output = """
        Warning: Skipping aom: most recent version 3.15.3 not installed
        Would remove: /opt/homebrew/Cellar/node/22.1.0 (2,345 files, 85.3MB)
        Would remove: /opt/homebrew/Caskroom/thing/1.0 (4.1MB)
        Would remove: /Users/me/Library/Caches/Homebrew/kind--0.33.0 (4.2MB)
        Would remove: /Users/me/Library/Caches/Homebrew/linkage.json (640B)
        Would remove: /Users/me/Library/Caches/Homebrew/odd (name) here.json (17.4KB)
        Would remove (broken link): /opt/homebrew/bin/gone
        Would remove (empty directory): /opt/homebrew/share/empty
        ==> This operation would free approximately 93.6MB of disk space.
        """
        let preview = Homebrew.parseCleanup(output)
        #expect(preview.items.count == 7)
        #expect(preview.bytes == 93_600_000)
        let node = try #require(preview.items.first)
        #expect(node.path == "/opt/homebrew/Cellar/node/22.1.0")
        #expect(node.bytes == 85_300_000 && node.files == 2_345)
        #expect(preview.items.contains { $0.path == "/Users/me/Library/Caches/Homebrew/odd (name) here.json" && $0.bytes == 17_400 })
        #expect(preview.items.contains { $0.path == "/opt/homebrew/bin/gone" && $0.bytes == nil })
        #expect(preview.oldVersions(prefix: "/opt/homebrew").map(\.path) == ["/opt/homebrew/Cellar/node/22.1.0", "/opt/homebrew/Caskroom/thing/1.0"])
        #expect(preview.downloads(prefix: "/opt/homebrew").count == 5)
        #expect(preview.paths.count == 7)
    }

    @Test func cleanupWithoutTotalAddsItemsUp() {
        let preview = Homebrew.parseCleanup("Would remove: /a (1KB)\nWould remove: /b (2.5KB)\n")
        #expect(preview.bytes == 3_500)
        #expect(Homebrew.parseCleanup("").isEmpty)
        #expect(Homebrew.parseCleanup("").bytes == 0)
        // A real run's summary, with colours.
        let real = "Removing: /a... (1KB)\n\u{1B}[34m==>\u{1B}[0m \u{1B}[1mThis operation has freed approximately 1GB of disk space.\u{1B}[0m\n"
        #expect(Homebrew.parseCleanup(real).bytes == 1_000_000_000)
    }

    @Test func sizesUseHomebrewsDecimalUnits() {
        #expect(Homebrew.parseSize("640B") == 640)
        #expect(Homebrew.parseSize("17.4KB") == 17_400)
        #expect(Homebrew.parseSize("4.2MB") == 4_200_000)
        #expect(Homebrew.parseSize("2GB") == 2_000_000_000)
        #expect(Homebrew.parseSize("1.5 MB") == 1_500_000)
        #expect(Homebrew.parseSize("files") == nil)
        #expect(Homebrew.parseSize("") == nil)
    }

    @Test func previewsRunTheCommandsThatClean() {
        #expect(Homebrew.cleanupArguments(downloads: false) == ["cleanup"])
        #expect(Homebrew.cleanupArguments(downloads: true) == ["cleanup", "-s", "--prune=all"])
        #expect(Homebrew.autoremoveArguments == ["autoremove"])
        #expect(Homebrew.extrasFailure("Error: sudo: a terminal is required", command: "brew cleanup").command == "brew cleanup")
        #expect(Homebrew.extrasFailure("Error: Permission denied", command: "brew cleanup").message.contains("Permission denied"))
    }

    @Test func savedFiguresRoundTripForTheSamePrefix() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ballast-extras-\(UUID().uuidString)/extras.json").path
        defer { try? FileManager.default.removeItem(atPath: (file as NSString).deletingLastPathComponent) }
        let preview = HomebrewCleanupPreview(items: [.init(path: "/opt/homebrew/Cellar/a/1", bytes: 5, files: 2)], bytes: 5)
        Homebrew.saveExtras(Homebrew.ExtrasCache(prefix: "/opt/homebrew", date: .now, orphans: ["a"], oldVersions: preview,
                                                 fullCleanup: nil), to: file)
        let loaded = try #require(Homebrew.loadExtras(prefix: "/opt/homebrew", from: file))
        #expect(loaded.orphans == ["a"])
        #expect(loaded.oldVersions == preview)
        #expect(loaded.fullCleanup == nil)
        #expect(Homebrew.loadExtras(prefix: "/usr/local", from: file) == nil)
    }
}
