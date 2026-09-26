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

    @Test func rulesStartOffAndSurviveEncoding() throws {
        let settings = AutoCleanSettings()
        #expect(!settings.anyEnabled)
        #expect(settings.rules.count == ArtifactKind.allCases.count)
        let decoded = try JSONDecoder().decode(AutoCleanSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}
