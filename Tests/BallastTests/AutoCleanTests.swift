import Foundation
import Testing
@testable import Ballast

@Suite struct ArtifactKindTests {
    /// A throwaway project folder with the given files.
    private func project(_ files: [String], dirs: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ballast-kind-\(UUID().uuidString)")
        for dir in dirs { try FileManager.default.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true) }
        for file in files { try Data().write(to: root.appending(path: file)) }
        return root
    }

    @Test func recognizesKindsByTheirMarkers() throws {
        let root = try project(["Cargo.toml", "package.json", "build.gradle.kts", "Podfile", "main.tf"],
                               dirs: ["target", ".next", "node_modules", "build", "Pods", ".terraform", ".venv"])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appending(path: ".venv/pyvenv.cfg"))

        #expect(ArtifactKind.detect(root.appending(path: "target")) == .rustTarget)
        #expect(ArtifactKind.detect(root.appending(path: ".next")) == .next)
        #expect(ArtifactKind.detect(root.appending(path: "node_modules")) == .nodeModules)
        #expect(ArtifactKind.detect(root.appending(path: "build")) == .gradleBuild)
        #expect(ArtifactKind.detect(root.appending(path: "Pods")) == .pods)
        #expect(ArtifactKind.detect(root.appending(path: ".terraform")) == .terraform)
        #expect(ArtifactKind.detect(root.appending(path: ".venv")) == .pythonVenv)
    }

    @Test func refusesLookalikesWithoutMarkers() throws {
        // A folder called target/ or build/ with no project file is somebody's data.
        let root = try project(["README.md"], dirs: ["target", "build", "node_modules", "venv", "Pods"])
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["target", "build", "node_modules", "venv", "Pods"] {
            #expect(ArtifactKind.detect(root.appending(path: name)) == nil, "\(name) must not match")
        }
    }

    @Test func mavenTargetIsNotRust() throws {
        let root = try project(["pom.xml"], dirs: ["target"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArtifactKind.detect(root.appending(path: "target")) == .mavenTarget)
    }

    /// A build folder (relative to the project) and the files that prove it.
    struct Case: Sendable, CustomTestStringConvertible {
        let kind: ArtifactKind
        let folder: String
        let markers: [String]
        var testDescription: String { "\(folder) with \(markers.joined(separator: ", "))" }
    }

    static let cases: [Case] = [
        Case(kind: .swiftBuild, folder: ".build", markers: ["Package.swift"]),
        Case(kind: .dotnet, folder: "bin", markers: ["App.csproj"]),
        Case(kind: .dotnet, folder: "obj", markers: ["Lib.fsproj"]),
        Case(kind: .dotnet, folder: "bin", markers: ["Old.vbproj"]),
        Case(kind: .elixir, folder: "_build", markers: ["mix.exs"]),
        Case(kind: .elixir, folder: "deps", markers: ["mix.exs"]),
        Case(kind: .haskell, folder: ".stack-work", markers: ["stack.yaml"]),
        Case(kind: .haskell, folder: "dist-newstyle", markers: ["cabal.project"]),
        Case(kind: .haskell, folder: "dist-newstyle", markers: ["app.cabal"]),
        Case(kind: .tox, folder: ".tox", markers: ["tox.ini"]),
        Case(kind: .pythonToolCache, folder: ".pytest_cache", markers: [".pytest_cache/CACHEDIR.TAG"]),
        Case(kind: .pythonToolCache, folder: ".mypy_cache", markers: [".mypy_cache/CACHEDIR.TAG"]),
        Case(kind: .pythonToolCache, folder: ".ruff_cache", markers: [".ruff_cache/CACHEDIR.TAG"]),
        Case(kind: .carthageBuild, folder: "Carthage/Build", markers: ["Cartfile"]),
        Case(kind: .androidCxx, folder: ".cxx", markers: ["build.gradle.kts"]),
        Case(kind: .expo, folder: ".expo", markers: ["app.json"]),
        Case(kind: .wrangler, folder: ".wrangler/tmp", markers: ["wrangler.jsonc"]),
        Case(kind: .coverage, folder: "coverage", markers: ["package.json", "coverage/lcov.info"]),
        Case(kind: .nx, folder: ".nx", markers: ["nx.json"]),
        Case(kind: .docusaurus, folder: ".docusaurus", markers: ["docusaurus.config.ts"]),
        Case(kind: .astro, folder: ".astro", markers: ["astro.config.mjs"]),
        Case(kind: .vercelOutput, folder: ".vercel/output", markers: ["vercel.json"]),
        Case(kind: .vercelOutput, folder: ".vercel/output", markers: [".vercel/project.json"]),
        Case(kind: .vercelOutput, folder: ".vercel/output", markers: [".vercel/output/config.json"]),
    ]

    @Test(arguments: cases)
    func recognizesNewKindsByTheirMarkers(_ c: Case) throws {
        let root = try project(c.markers, dirs: [c.folder])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArtifactKind.detect(root.appending(path: c.folder)) == c.kind)
    }

    @Test(arguments: cases)
    func refusesNewKindsWithoutTheirMarkers(_ c: Case) throws {
        let root = try project(["README.md"], dirs: [c.folder])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArtifactKind.detect(root.appending(path: c.folder)) == nil)
    }

    @Test func everyKindHasATestCase() {
        let old: Set<ArtifactKind> = [.nodeModules, .next, .nuxt, .svelteKit, .angular, .turbo, .parcel, .rustTarget,
                                      .mavenTarget, .gradleBuild, .gradleCache, .pythonVenv, .pythonCache, .pods,
                                      .dartTool, .zigCache, .terraform]
        #expect(Set(ArtifactKind.allCases).subtracting(old) == Set(Self.cases.map(\.kind)))
    }

    @Test func coverageNeedsAReportAndAPackage() throws {
        // "coverage" is a common name: Go's src/internal/coverage is source code.
        let noReport = try project(["package.json", "coverage/notes.md"], dirs: ["coverage"])
        let noPackage = try project(["coverage/lcov.info"], dirs: ["coverage"])
        let htmlOnly = try project(["package.json"], dirs: ["coverage/lcov-report"])
        defer { for root in [noReport, noPackage, htmlOnly] { try? FileManager.default.removeItem(at: root) } }
        #expect(ArtifactKind.detect(noReport.appending(path: "coverage")) == nil)
        #expect(ArtifactKind.detect(noPackage.appending(path: "coverage")) == nil)
        #expect(ArtifactKind.detect(htmlOnly.appending(path: "coverage")) == .coverage)
    }

    @Test func projectFileExtensionsMustMatchExactly() throws {
        // A backup of a project file isn't a project file.
        let root = try project(["App.csproj.bak", "notes.cabal.txt"], dirs: ["bin", "obj", "dist-newstyle"])
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["bin", "obj", "dist-newstyle"] {
            #expect(ArtifactKind.detect(root.appending(path: name)) == nil, "\(name) must not match")
        }
    }

    @Test func nestedKindsOnlyCountAtTheirOwnDepth() throws {
        // Build/ next to a Cartfile isn't Carthage's; only Carthage/Build is.
        let root = try project(["Cartfile", "wrangler.toml", "Carthage/Cartfile", "vercel.json"],
                               dirs: ["Build", "Carthage", "Other/Build", "tmp", ".wrangler/state", "output"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArtifactKind.detect(root.appending(path: "Build")) == nil)
        #expect(ArtifactKind.detect(root.appending(path: "Other/Build")) == nil)
        #expect(ArtifactKind.detect(root.appending(path: "tmp")) == nil)
        #expect(ArtifactKind.detect(root.appending(path: "output")) == nil)
        // .wrangler/state holds local databases: never build output.
        #expect(ArtifactKind.detect(root.appending(path: ".wrangler/state")) == nil)
        #expect(ArtifactKind.detect(root.appending(path: ".wrangler")) == nil)
        // The marker belongs in the project, not inside Carthage/.
        let inner = try project(["Carthage/Cartfile"], dirs: ["Carthage/Build"])
        defer { try? FileManager.default.removeItem(at: inner) }
        #expect(ArtifactKind.detect(inner.appending(path: "Carthage/Build")) == nil)
    }

    @Test func scannerFindsNestedKindsAndCountsEachFolderOnce() throws {
        let fm = FileManager.default
        let root = try project(["Cartfile", "wrangler.toml", "package.json", "node_modules/pkg/Package.swift"],
                               dirs: ["Carthage/Build", ".wrangler/tmp", ".wrangler/state", "node_modules/pkg/.build"])
        defer { try? fm.removeItem(at: root) }
        for folder in ["Carthage/Build", ".wrangler/tmp", ".wrangler/state", "node_modules/pkg/.build"] {
            try Data(count: 8_192).write(to: root.appending(path: folder + "/blob"))
        }
        // A throwaway index of just this project, built the way a full scan builds one.
        let indexPath = root.path + ".sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: indexPath + suffix) } }
        let db = try IndexDB(path: indexPath, mode: .build)
        try Walker.walk(root.path) { node in
            try db.upsert(id: node.local + 1, parent: node.parent < 0 ? nil : node.parent + 1, name: node.name, node: node)
        }
        try db.createIndexes()

        let found = ArtifactScanner.scan(db)
        let byPath = Dictionary(uniqueKeysWithValues: found.map { ($0.path, $0.kind) })
        #expect(byPath[root.path + "/Carthage/Build"] == .carthageBuild)
        #expect(byPath[root.path + "/.wrangler/tmp"] == .wrangler)
        #expect(byPath[root.path + "/node_modules"] == .nodeModules)
        // Inside node_modules, already counted by it; state/ is never build output.
        #expect(found.count == 3)
        #expect(found.first { $0.kind == .carthageBuild }?.project == root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
    }
}

@Suite struct AutoCleanRuleTests {
    private func artifact(_ kind: ArtifactKind, idleDays: Double) -> Artifact {
        Artifact(path: "/Users/x/p/\(kind.rawValue)", kind: kind, bytes: 1_000,
                 projectNewest: Int64(Date.now.timeIntervalSince1970 - idleDays * 86_400))
    }

    @Test func dueOnlyWhenEnabledAndIdleLongEnough() {
        var settings = AutoCleanSettings()
        let rule = AutoCleanRule(kind: .next, enabled: true, days: 3, permanent: true)
        settings.rules = [rule]

        let fresh = artifact(.next, idleDays: 1)
        let stale = artifact(.next, idleDays: 5)
        let otherKind = artifact(.rustTarget, idleDays: 50)

        let due = AutoClean.due([fresh, stale, otherKind], settings: settings)
        #expect(due.map(\.0.path) == [stale.path])
    }

    @Test func unknownActivityIsNeverStale() {
        let never = Artifact(path: "/x", kind: .next, bytes: 1, projectNewest: 0)
        #expect(!AutoClean.isStale(never, rule: AutoCleanRule(kind: .next, enabled: true, days: 1)))
    }

    @Test func settingsFromAnOlderVersionGetRulesForNewKinds() throws {
        // Saved before most kinds existed: only a Next.js rule, turned on.
        let old = #"{"background": true, "rules": [{"kind": "next", "enabled": true, "days": 3, "permanent": false}]}"#
        var settings = try JSONDecoder().decode(AutoCleanSettings.self, from: Data(old.utf8))
        settings.addMissingRules()
        #expect(settings.rules.count == ArtifactKind.allCases.count)
        #expect(settings.rule(for: .next).enabled)
        #expect(!settings.rule(for: .swiftBuild).enabled)
        #expect(settings.rules.filter(\.enabled).count == 1)
    }

    @Test func rulesStartOffAndSurviveEncoding() throws {
        let settings = AutoCleanSettings()
        #expect(!settings.anyEnabled)
        #expect(settings.rules.count == ArtifactKind.allCases.count)
        let decoded = try JSONDecoder().decode(AutoCleanSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}
