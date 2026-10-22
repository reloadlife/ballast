import Foundation
import Testing
@testable import Ballast

@Suite struct HealthTests {
    @Test func missingSMARTIsNotHealthy() {
        let rows = HealthChecks.smart([:], id: "disk4")
        #expect(rows.count == 1)
        #expect(rows[0].state == .unavailable)
        #expect(!rows[0].detail.contains("no SMART failure"))
    }

    @Test func failureAndEnduranceAreSeparate() {
        let rows = HealthChecks.smart(["SMARTStatus": "Failing", "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
            "PERCENTAGE_USED": 105, "AVAILABLE_SPARE": 5, "AVAILABLE_SPARE_THRESHOLD": 10,
            "MEDIA_ERRORS_0": 3, "MEDIA_ERRORS_1": 0]], id: "disk0")
        #expect(rows.count == 4)
        #expect(rows.allSatisfy { $0.state == .attention })
    }

    @Test func optionalMetricsAreNotInvented() {
        let rows = HealthChecks.smart(["SMARTStatus": "Verified", "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": ["MEDIA_ERRORS_0": 0]], id: "disk0")
        #expect(rows.count == 1)
        #expect(rows[0].state == .passed)
    }

    @Test func unexpectedSecurityOutputIsUnavailable() {
        for output in ["", "System Integrity Protection status: unknown (Custom Configuration).", "not enabled", "enabled but failed"] {
            #expect(HealthChecks.securityResult(id: "test", title: "Test", output: output, enabled: "enabled", disabled: "disabled", advice: "Review").state == .unavailable)
        }
        #expect(HealthChecks.securityResult(id: "test", title: "Test", output: "enabled\n", enabled: "enabled", disabled: "disabled", advice: "Review").state == .passed)
    }

    @Test func receiptsPreserveRevisionAndExcludeUnmappedPackages() throws {
        let core = Data(#"{"source":{"tap":"homebrew/core","spec":"stable"}}"#.utf8)
        let package = try VulnerabilityInventory.package(name: "openssl@3", version: "3.0.1_2", receipt: core)
        #expect(package?.version == "3.0.1_2")
        #expect(try VulnerabilityInventory.package(name: "openssl@3", version: "HEAD-abc", receipt: core) == nil)
        #expect(try VulnerabilityInventory.package(name: "custom", version: "1", receipt: Data(#"{"source":{"tap":"me/tools","spec":"stable"}}"#.utf8)) == nil)
        #expect(try VulnerabilityInventory.package(name: "unknown", version: "1", receipt: Data(#"{"source":{}}"#.utf8)) == nil)
    }

    @Test func localInventoryReadsReceiptsAndCountsExclusions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Cellar/openssl@3/3.0.1_2", "Cellar/openssl@3/3.0.1_3", "Cellar/bad/1", "Caskroom/firefox"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for version in ["3.0.1_2", "3.0.1_3"] {
            try Data(#"{"source":{"tap":"homebrew/core","spec":"stable"}}"#.utf8)
                .write(to: root.appendingPathComponent("Cellar/openssl@3/\(version)/INSTALL_RECEIPT.json"))
        }
        let inventory = try VulnerabilityInventory.read(prefixes: [root.path])
        #expect(inventory.packages.map(\.version) == ["3.0.1_2", "3.0.1_3"])
        #expect(inventory.excluded == 2)
    }

    @Test func paginationKeepsPackageAssociationAndDeduplicates() async throws {
        let inventory = VulnerabilityInventory(packages: [.init(name: "a", version: "1"), .init(name: "b", version: "2")], excluded: 1)
        let report = try await VulnerabilityCheck.scan(inventory) { body in
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let queries = try #require(json["queries"] as? [[String: Any]])
            if queries.count == 2 {
                #expect((queries[0]["package"] as? [String: String])?["ecosystem"] == "Homebrew")
                return Data(#"{"results":[{"vulns":[{"id":"BREW-1"}],"next_page_token":"next"},{}]}"#.utf8)
            }
            #expect(queries.count == 1)
            #expect(queries[0]["page_token"] as? String == "next")
            #expect((queries[0]["package"] as? [String: String])?["name"] == "a")
            return Data(#"{"results":[{"vulns":[{"id":"BREW-1"},{"id":"BREW-2"}]}]}"#.utf8)
        }
        #expect(report.checked == 2)
        #expect(report.excluded == 1)
        #expect(report.matches.count == 2)
        #expect(report.matches.allSatisfy { $0.package.name == "a" })
    }

    @Test func incompleteResponseCannotReportClean() async {
        let inventory = VulnerabilityInventory(packages: [.init(name: "a", version: "1")], excluded: 0)
        await #expect(throws: (any Error).self) {
            _ = try await VulnerabilityCheck.scan(inventory) { _ in Data(#"{"results":[]}"#.utf8) }
        }
        await #expect(throws: (any Error).self) {
            _ = try await VulnerabilityCheck.scan(inventory) { _ in Data(#"{"error":"unavailable"}"#.utf8) }
        }
    }

    @Test func emptyInventoryDoesNotContactNetwork() async throws {
        let report = try await VulnerabilityCheck.scan(.init(packages: [], excluded: 3)) { _ in
            Issue.record("Empty inventory must not contact OSV")
            return Data()
        }
        #expect(report.checked == 0)
    }

    @Test func healthDeepLink() {
        #expect(Pane(link: URL(string: "ballast://health")!) == .health)
    }

    @Test func commandFailureAndTimeoutAreErrors() throws {
        #expect(throws: (any Error).self) { _ = try HealthCommand.run("/usr/bin/false", []) }
        #expect(throws: (any Error).self) { _ = try HealthCommand.run("/bin/sleep", ["2"], timeout: 0.01) }
    }
}
