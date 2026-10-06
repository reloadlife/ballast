import Foundation
import Testing
@testable import Ballast

/// The rules that decide what may be deleted. A regression here can cost
/// someone their data, so every protected area gets a test.
@Suite struct SafetyTests {
    let home = NSHomeDirectory()
    let nobody = AppInventory(running: [], installed: [])

    /// Always with an explicit protected list, so the tests never depend on
    /// what the person running them protected in Settings.
    private func level(_ relative: String, directory: Bool = true, apps: AppInventory? = nil,
                       protected: [String] = []) -> Safety.Level {
        SafetyCheck.assess(home + relative, isDirectory: directory, apps: apps ?? nobody,
                           protected: protected.map { home + $0 }).level
    }

    @Test func protectsSystemLocationsAndTraversal() {
        #expect(SafetyCheck.assess("/Applications/Safari.app", isDirectory: true, apps: nobody, protected: []).level == .blocked)
        #expect(SafetyCheck.assess("/System/Library", isDirectory: true, apps: nobody, protected: []).level == .blocked)
        #expect(level("/projects/../Documents") == .blocked)
    }

    @Test func outsideHomeCleanupAndSymlinkProtection() throws {
        let root = URL(fileURLWithPath: "/private/tmp/ballast-policy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("disposable.txt")
        try Data("test".utf8).write(to: file)
        var item = PlanItem.assess(name: "Test", path: file.path, bytes: 4, action: .remove,
                                  isDirectory: false, apps: nobody, protected: [])
        #expect(item.safety.level == .caution)
        #expect(Cleaner.canRemove(file.path))
        item.included = true
        let outcomes = Cleaner.clean([item], permanently: true, apps: nobody, protected: [], cancel: CancelFlag()) { _, _ in }
        #expect(outcomes.first?.succeeded == true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let alias = root.appendingPathComponent("system-alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "/System/Library")
        #expect(SafetyCheck.assess(alias.path, isDirectory: true, apps: nobody, protected: []).level == .blocked)
        #expect(SafetyCheck.assess(root.path, isDirectory: true, apps: nobody, protected: [root.path]).level == .blocked)
    }

    @Test(arguments: ["/Documents", "/Library", "/Desktop", "/Pictures", "/projects", "/.config"])
    func protectsTopLevelHomeFolders(_ folder: String) {
        #expect(level(folder) == .blocked)
    }

    @Test(arguments: ["/.zshrc", "/.gitconfig"])
    func protectsDotfiles(_ file: String) {
        #expect(level(file, directory: false) == .blocked)
    }

    @Test func allowsLooseFilesInHome() {
        #expect(level("/installer.dmg", directory: false) == .safe)
    }

    @Test(arguments: [
        "/Library/Preferences/com.apple.finder.plist",
        "/Library/Keychains/login.keychain-db",
        "/Library/Mail/V10",
        "/.ssh/id_ed25519",
        "/Pictures/Photos Library.photoslibrary/originals",
        "/projects/app/.git",
        "/Library/Group Containers/group.com.apple.notes/data",
    ])
    func protectsPersonalAndSystemData(_ path: String) {
        #expect(level(path) == .blocked)
    }

    @Test func cachesAndBuildOutputAreSafe() {
        #expect(level("/Library/Caches/com.example.editor") == .safe)
        #expect(level("/projects/app/node_modules") == .safe)
        #expect(level("/.cache/uv") == .safe)
        #expect(level("/Library/Developer/Xcode/DerivedData") == .safe)
    }

    @Test func runningAppMustQuitBeforeItsCacheGoes() {
        let chrome = RunningApp(name: "Google Chrome", bundleID: "com.google.Chrome", pid: 1, bundlePath: "/Applications/Google Chrome.app")
        let apps = AppInventory(running: [chrome], installed: [])
        #expect(level("/Library/Caches/Google/Chrome", apps: apps) == .quitFirst)
        #expect(level("/Library/Caches/com.google.Chrome", apps: apps) == .quitFirst)
        #expect(level("/Library/Caches/com.google.Chrome") == .safe)
    }

    @Test func installedAppDataIsProtectedEvenWhenClosed() {
        let apps = AppInventory(running: [], installed: [InstalledApp(name: "Google Chrome", bundleID: "com.google.Chrome")])
        #expect(level("/Library/Application Support/Google/Chrome", apps: apps) == .blocked)
        // …but its caches inside are fair game.
        #expect(level("/Library/Application Support/Google/Chrome/Default/Cache", apps: apps) == .safe)
    }

    @Test func containerNamesThatDontMatchTheBundleIDStillMatchTheApp() {
        // OrbStack's bundle id is dev.kdrag0n.MacVirt, its data lives in "…dev.orbstack".
        let apps = AppInventory(running: [], installed: [InstalledApp(name: "OrbStack", bundleID: "dev.kdrag0n.MacVirt")])
        #expect(level("/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data", apps: apps) == .blocked)
    }

    @Test func unknownAppDataStaysProtected() {
        #expect(level("/Library/Application Support/SomethingNobodyKnows") == .blocked)
    }

    @Test func gitRepositoriesNeedConfirmation() throws {
        // Only paths inside home are considered, so the repo has to live there.
        let parent = URL(fileURLWithPath: home).appending(path: "ballast-test-\(UUID().uuidString)")
        let repo = parent.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        #expect(SafetyCheck.assess(repo.path, isDirectory: true, apps: nobody, protected: []).level == .caution)
    }

    // MARK: Tool folders with a verdict of their own

    @Test(arguments: [
        "/Library/Developer/Xcode/Archives",
        "/Library/Developer/Xcode/Archives/2026-09-01/App.xcarchive",
        "/.cache/huggingface",
        "/.cache/huggingface/hub/models--bert",
        "/.m2/repository",
        "/.android/avd",
        "/Library/Android/sdk/system-images",
        "/.ollama/models",
    ])
    func downloadsYouChoseOrShippedBuildsNeedConfirmation(_ path: String) {
        #expect(level(path) == .caution)
    }

    @Test(arguments: [
        "/Library/Developer/Xcode/iOS DeviceSupport",
        "/Library/Developer/Xcode/watchOS DeviceSupport/10.0",
        "/Library/Developer/Xcode/UserData/Previews",
        "/.gradle/wrapper/dists",
    ])
    func regeneratedToolFilesAreSafe(_ path: String) {
        #expect(level(path) == .safe)
    }

    @Test func otherCachesAndDeveloperDataKeepTheirVerdicts() {
        // Only Hugging Face is carved out of ~/.cache; the rest is still a cache.
        #expect(level("/.cache/uv") == .safe)
        #expect(level("/Library/Developer/Xcode/UserData/CodeSnippets") == .blocked)
        #expect(level("/Library/Android/sdk/platforms") == .blocked)
        #expect(level("/.m2/settings.xml", directory: false) == .caution)
    }

    @Test func xcodeAndOllamaMustQuitFirst() {
        let xcode = RunningApp(name: "Xcode", bundleID: "com.apple.dt.Xcode", pid: 1, bundlePath: "/Applications/Xcode.app")
        let ollama = RunningApp(name: "Ollama", bundleID: "com.electron.ollama", pid: 2, bundlePath: "/Applications/Ollama.app")
        let apps = AppInventory(running: [xcode, ollama], installed: [])
        #expect(level("/Library/Developer/Xcode/UserData/Previews", apps: apps) == .quitFirst)
        #expect(level("/Library/Developer/Xcode/Archives", apps: apps) == .quitFirst)
        #expect(level("/.ollama/models", apps: apps) == .quitFirst)
    }

    @Test func protectionBeatsToolVerdicts() {
        #expect(level("/.gradle/wrapper/dists", protected: ["/.gradle/wrapper/dists"]) == .blocked)
        #expect(level("/Library/Developer/Xcode/iOS DeviceSupport", protected: ["/Library/Developer"]) == .blocked)
    }

    @Test func dockerPruneNeedsConfirmationOtherToolCommandsDont() {
        func verdict(_ command: String, path: String) -> Safety.Level {
            PlanItem.assess(name: "x", path: path, bytes: 1, action: .command(command), isDirectory: true,
                            apps: nobody, protected: []).safety.level
        }
        #expect(verdict(Catalog.dockerPrune, path: home + "/.orbstack") == .caution)
        #expect(verdict("npm cache clean --force", path: home + "/.npm") == .safe)
        #expect(verdict("pip3 cache purge", path: home + "/Library/Caches/pip") == .safe)
        #expect(!Catalog.dockerPrune.contains("--volumes"))
        // A protected folder still blocks the tool's own cleanup.
        let blocked = PlanItem.assess(name: "x", path: home + "/.orbstack", bytes: 1, action: .command(Catalog.dockerPrune),
                                      isDirectory: true, apps: nobody, protected: [home + "/.orbstack"])
        #expect(blocked.safety.level == .blocked)
    }

    // MARK: Folders protected in Settings

    @Test func protectedFolderAndEverythingInsideIsBlocked() {
        let protected = ["/projects/keep"]
        #expect(level("/projects/keep", protected: protected) == .blocked)
        #expect(level("/projects/keep/node_modules", protected: protected) == .blocked)
        #expect(level("/projects/keep/a/b/c.bin", directory: false, protected: protected) == .blocked)
        let verdict = SafetyCheck.assess(home + "/projects/keep", isDirectory: true, apps: nobody,
                                         protected: [home + "/projects/keep"])
        #expect(verdict.reason == "You protected this folder in Settings.")
    }

    @Test func removingAParentOfAProtectedFolderIsBlocked() {
        // Removing ~/projects/app would take ~/projects/app/data with it.
        #expect(level("/projects/app", protected: ["/projects/app/data"]) == .blocked)
    }

    @Test func protectionMatchesWholeFolderNamesOnly() {
        let protected = ["/projects/app"]
        #expect(level("/projects/app2/node_modules", protected: protected) == .safe)
        #expect(level("/projects/ap", protected: protected) == .safe)
        #expect(level("/projects/other/node_modules", protected: protected) == .safe)
    }

    @Test func protectionOverridesRulesThatWouldAllowIt() {
        // Caches are normally safe; the user's word wins.
        #expect(level("/Library/Caches/com.example.editor", protected: ["/Library/Caches/com.example.editor"]) == .blocked)
    }

    @Test func cleanerRefusesProtectedItemsAtDeletionTime() throws {
        // The item was added as safe; the folder got protected afterwards.
        let parent = URL(fileURLWithPath: home).appending(path: "ballast-test-\(UUID().uuidString)")
        let folder = parent.appending(path: "keep")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let item = PlanItem(name: "keep", path: folder.path, bytes: 1, action: .remove,
                            isDirectory: true, safety: .safe("added earlier"), included: true)

        let outcome = Cleaner.clean([item], permanently: true, apps: nobody, protected: [folder.path],
                                    cancel: CancelFlag()) { _, _ in }
        #expect(outcome.first?.succeeded == false)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func emptyingAFolderKeepsWhatIsListedOnItsOwn() throws {
        // ~/Library/Caches keeps pip's cache: it's a separate item with its own command.
        let parent = URL(fileURLWithPath: home).appending(path: "ballast-test-\(UUID().uuidString)/cache")
        let fm = FileManager.default
        try fm.createDirectory(at: parent.appending(path: "pip/http"), withIntermediateDirectories: true)
        try fm.createDirectory(at: parent.appending(path: "junk"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent.deletingLastPathComponent()) }
        let item = PlanItem(name: "x", path: parent.path, bytes: 1, action: .contents,
                            isDirectory: true, safety: .safe("cache"), included: true)

        let outcome = Cleaner.clean([item], permanently: true, apps: nobody, protected: [],
                                    kept: [parent.appending(path: "pip").path],
                                    cancel: CancelFlag()) { _, _ in }
        #expect(outcome.first?.succeeded == true)
        #expect(fm.fileExists(atPath: parent.appending(path: "pip/http").path))
        #expect(!fm.fileExists(atPath: parent.appending(path: "junk").path))
    }

    @Test func emptyingAFolderKeepsProtectedItemsInside() throws {
        let parent = URL(fileURLWithPath: home).appending(path: "ballast-test-\(UUID().uuidString)/cache")
        let fm = FileManager.default
        try fm.createDirectory(at: parent.appending(path: "keep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: parent.appending(path: "junk"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent.deletingLastPathComponent()) }
        let item = PlanItem(name: "x", path: parent.path, bytes: 1, action: .contents,
                            isDirectory: true, safety: .safe("cache"), included: true)

        let outcome = Cleaner.clean([item], permanently: true, apps: nobody,
                                    protected: [parent.appending(path: "keep").path],
                                    cancel: CancelFlag()) { _, _ in }
        #expect(outcome.first?.succeeded == true)
        #expect(fm.fileExists(atPath: parent.appending(path: "keep").path))
        #expect(!fm.fileExists(atPath: parent.appending(path: "junk").path))
    }
}
