import Foundation
import Testing
@testable import Ballast

/// The rules that decide what may be deleted. A regression here can cost
/// someone their data, so every protected area gets a test.
@Suite struct SafetyTests {
    let home = NSHomeDirectory()
    let nobody = AppInventory(running: [], installed: [])

    private func level(_ relative: String, directory: Bool = true, apps: AppInventory? = nil) -> Safety.Level {
        SafetyCheck.assess(home + relative, isDirectory: directory, apps: apps ?? nobody).level
    }

    @Test func refusesEverythingOutsideHome() {
        #expect(SafetyCheck.assess("/Applications/Safari.app", isDirectory: true, apps: nobody).level == .blocked)
        #expect(SafetyCheck.assess("/System/Library", isDirectory: true, apps: nobody).level == .blocked)
        #expect(level("/projects/../Documents") == .blocked)
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
        #expect(SafetyCheck.assess(repo.path, isDirectory: true, apps: nobody).level == .caution)
    }
}
