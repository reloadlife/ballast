import Foundation
import Testing
@testable import Ballast

@Suite struct HomebrewInventoryTests {
    /// A Homebrew prefix laid out the way brew leaves it on disk.
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ballast-brew-\(UUID().uuidString)")
        let fm = FileManager.default
        func write(_ text: String, _ path: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        // node: two kegs, the older one still linked from opt/.
        try write(#"{"installed_on_request":true,"time":100,"source":{"tap":"homebrew/core"},"runtime_dependencies":[{"full_name":"icu4c"},{"bad":1}]}"#,
                  "Cellar/node/20.1.0/INSTALL_RECEIPT.json")
        try write(#"{"installed_on_request":true,"time":200,"source":{"tap":"homebrew/core"}}"#, "Cellar/node/21.0.0/INSTALL_RECEIPT.json")
        try fm.createDirectory(at: root.appendingPathComponent("opt"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("opt/node").path, withDestinationPath: "../Cellar/node/20.1.0")
        // A dependency node still needs, and one nothing needs any more.
        try write(#"{"installed_on_request":false,"time":50,"source":{"tap":"homebrew/core"}}"#, "Cellar/icu4c/74.2/INSTALL_RECEIPT.json")
        try write(#"{"installed_on_request":false,"time":60,"source":{"tap":"homebrew/core"}}"#, "Cellar/libleft/1.0/INSTALL_RECEIPT.json")
        // From a third-party tap, and pinned.
        try write(#"{"installed_on_request":true,"time":70,"source":{"tap":"team/tools"}}"#, "Cellar/same/2.0/INSTALL_RECEIPT.json")
        try write("", "var/homebrew/pinned/same")
        // A receipt brew half wrote: still listed, never called an orphan.
        try write("{not json", "Cellar/broken/1.0/INSTALL_RECEIPT.json")
        // A cask with metadata from two installs, and a folder of its app.
        try write(#"{"desc":"Web browser"}"#, "Caskroom/firefox/.metadata/120.0/20240101000000.000/Casks/firefox.json")
        try write(#"{"desc":"Web browser"}"#, "Caskroom/firefox/.metadata/121.0/20240201000000.000/Casks/firefox.json")
        try fm.createDirectory(at: root.appendingPathComponent("Caskroom/firefox/121.0"), withIntermediateDirectories: true)
        // An empty folder isn't a package.
        try fm.createDirectory(at: root.appendingPathComponent("Cellar/empty"), withIntermediateDirectories: true)
        return root
    }

    @Test func inventoryComesFromReceiptsWithoutBrew() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = Dictionary(uniqueKeysWithValues: Homebrew.inventory(prefix: root.path).map { ($0.id, $0) })
        #expect(Set(packages.keys) == ["formula:node", "formula:icu4c", "formula:libleft", "formula:team/tools/same",
                                      "formula:broken", "cask:firefox"])

        let node = try #require(packages["formula:node"])
        #expect(node.installed == "20.1.0")
        #expect(node.oldVersions == ["21.0.0"])
        #expect(node.dependencies == ["icu4c"])
        #expect(!node.orphaned)

        #expect(packages["formula:icu4c"]?.orphaned == false)
        #expect(packages["formula:libleft"]?.orphaned == true)
        #expect(packages["formula:team/tools/same"]?.pinned == true)
        #expect(packages["formula:team/tools/same"]?.token == "same")

        let broken = try #require(packages["formula:broken"])
        #expect(broken.installed == "1.0")
        #expect(!broken.orphaned)

        let firefox = try #require(packages["cask:firefox"])
        #expect(firefox.installed == "121.0")
        #expect(firefox.description == "Web browser")
    }

    @Test func theNewestReceiptWinsWhenNothingIsLinked() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("opt/node"))
        let node = try #require(Homebrew.package("node", kind: .formula, prefix: root.path))
        #expect(node.installed == "21.0.0")
        #expect(node.oldVersions == ["20.1.0"])
        #expect(Homebrew.package("gone", kind: .formula, prefix: root.path) == nil)
    }

    @Test func theFingerprintChangesWhenAPackageDoes() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = Homebrew.fingerprint(prefix: root.path)
        #expect(before == Homebrew.fingerprint(prefix: root.path))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Cellar/wget/1.24"), withIntermediateDirectories: true)
        #expect(before != Homebrew.fingerprint(prefix: root.path))
    }

    @Test func theCacheRoundTripsAndChecksItsPrefix() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("support/homebrew-inventory.json").path
        var packages = Homebrew.inventory(prefix: root.path)
        packages[0].bytes = 1234
        Homebrew.saveCache(.init(prefix: root.path, fingerprint: "abc", packages: packages), to: file)
        let cache = try #require(Homebrew.loadCache(prefix: root.path, from: file))
        #expect(cache.fingerprint == "abc")
        #expect(cache.packages == packages)
        #expect(Homebrew.loadCache(prefix: "/elsewhere", from: file) == nil)
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: file))
        #expect(Homebrew.loadCache(prefix: root.path, from: file) == nil)
    }

    @Test func mergeKeepsWhatIsKnownUntilTheVersionChanges() {
        func package(_ name: String, _ installed: String) -> BrewPackage {
            BrewPackage(name: name, kind: .formula, installed: installed, available: installed, description: "", outdated: false, pinned: false)
        }
        var known = package("node", "20")
        known.available = "21"
        known.outdated = true
        known.description = "JavaScript runtime"
        known.bytes = 100
        var same = package("git", "2.0")
        same.available = "2.1"
        same.outdated = true
        let merged = Homebrew.merge([package("node", "21"), package("git", "2.0"), package("new", "1")], keeping: [known, same])
        let byName = Dictionary(uniqueKeysWithValues: merged.map { ($0.name, $0) })
        // Upgraded: the old update flag is stale, the description and size aren't.
        #expect(byName["node"]?.outdated == false)
        #expect(byName["node"]?.description == "JavaScript runtime")
        #expect(byName["node"]?.bytes == 100)
        #expect(byName["git"]?.outdated == true)
        #expect(byName["git"]?.available == "2.1")
        #expect(byName["new"] != nil)
    }

    @Test func oneMalformedEntryDoesNotHideTheRest() throws {
        let json = """
        {"formulae":[{"name":"good","desc":"Fine","installed":[{"version":"1.0"}],"versions":{"stable":"1.1"},"outdated":true},
                     {"desc":"no name"},
                     {"name":"odd","installed":[{"version":"2"},{"nope":true}]}],
         "casks":[{"token":"app","installed":"3","version":"3"},{"token":42}]}
        """
        let packages = try Homebrew.parse(Data(json.utf8))
        #expect(packages.map(\.name) == ["app", "good", "odd"])
        #expect(packages.first { $0.name == "odd" }?.installed == "2")
        #expect(packages.first { $0.name == "good" }?.outdated == true)
        #expect(throws: (any Error).self) { try Homebrew.parse(Data("[]".utf8)) }
    }

    @Test func updatesAreReadLossilyAndApplied() throws {
        let json = """
        {"formulae":[{"name":"node","installed_versions":["20"],"current_version":"21","pinned":false},
                     {"installed_versions":["1"]},
                     {"name":"held","current_version":"5","pinned":true}],
         "casks":[{"name":"firefox","current_version":"122.0"}]}
        """
        let updates = try Homebrew.parseOutdated(Data(json.utf8))
        #expect(updates.count == 3)
        #expect(updates["formula:node"] == BrewUpdate(available: "21", pinned: false))
        #expect(updates["formula:held"]?.pinned == true)
        #expect(updates["cask:firefox"]?.available == "122.0")
        #expect(throws: (any Error).self) { try Homebrew.parseOutdated(Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try Homebrew.parseOutdated(Data("not json".utf8)) }

        let packages = [
            BrewPackage(name: "node", kind: .formula, installed: "20", available: "20", description: "", outdated: false, pinned: false),
            BrewPackage(name: "homebrew/core/held", kind: .formula, installed: "4", available: "4", description: "", outdated: false, pinned: false),
            BrewPackage(name: "wget", kind: .formula, installed: "1", available: "2", description: "", outdated: true, pinned: false),
        ]
        let applied = Homebrew.apply(updates, to: packages)
        #expect(applied[0].outdated && applied[0].available == "21")
        #expect(applied[1].outdated && applied[1].pinned)
        #expect(!applied[2].outdated && applied[2].available == "1")
    }

    @Test func changesThatNeedAPasswordPointToTerminal() {
        let cask = BrewPackage(name: "zoom", kind: .cask, installed: "1", available: "2", description: "", outdated: true, pinned: false)
        let sudo = Homebrew.failure("==> Running installer for zoom\nsudo: a terminal is required to read the password", verb: "upgrade", package: cask)
        #expect(sudo.command == "brew upgrade --cask zoom")
        #expect(sudo.message.contains("Terminal"))

        let plain = Homebrew.failure("Warning: something\nError: No available formula", verb: "uninstall", package: cask)
        #expect(plain.command == nil)
        #expect(plain.message.hasSuffix("Error: No available formula"))
    }
}
