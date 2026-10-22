import Darwin
import Foundation

struct HealthFinding: Identifiable, Sendable {
    enum State: String, Sendable { case passed = "Passed", attention = "Needs attention", unavailable = "Unavailable", information = "Information" }
    let id: String
    let title: String
    let state: State
    let detail: String
    let source: String
}

/// Read-only diagnostics use bounded subprocesses. No shell, sudo, repair, or self-test.
enum HealthCommand {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15) throws -> Data {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let output = folder.appendingPathComponent("output")
        fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                               "HOME": NSHomeDirectory(), "LC_ALL": "C", "LANG": "C",
                               "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"]
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ToolFailure(message: "The check timed out. Try again later.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolFailure(message: "The system tool could not complete this check (exit \(process.terminationStatus)).")
        }
        let size = (try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size <= 16_000_000 else { throw ToolFailure(message: "The diagnostic output exceeded the size limit.") }
        return try Data(contentsOf: output)
    }
}

struct LocalHealthReport: Sendable {
    var storage: [HealthFinding] = []
    var security: [HealthFinding] = []
    let date = Date()
}

enum HealthChecks {
    static func plist(_ data: Data) throws -> [String: Any] {
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ToolFailure(message: "macOS returned an unrecognized diagnostic format.")
        }
        return result
    }

    static func smart(_ disk: [String: Any], id: String) -> [HealthFinding] {
        let name = (disk["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
        let status = disk["SMARTStatus"] as? String
        let state: HealthFinding.State = status == "Verified" ? .passed : status == "Failing" ? .attention : .unavailable
        var rows = [HealthFinding(id: id + "-smart", title: "\(name) · SMART", state: state,
            detail: state == .passed ? "The drive reports no SMART failure. This does not guarantee that it will not fail."
                : state == .attention ? "The drive reports a hardware failure. Back up your files and arrange a replacement."
                : "SMART status is not available through macOS for this drive or enclosure.", source: "diskutil info · \(id)")]
        // These optional keys are explicitly device-specific. Never assume absent values are zero.
        if let metrics = disk["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any] {
            if let used = metrics["PERCENTAGE_USED"] as? Int, used >= 0 {
                rows.append(.init(id: id + "-wear", title: "SSD endurance used", state: used >= 100 ? .attention : .information,
                    detail: "\(used)% of the manufacturer's estimated write endurance has been used. This is not remaining lifespan.", source: "diskutil · PERCENTAGE_USED"))
            }
            if let spare = metrics["AVAILABLE_SPARE"] as? Int, (0...100).contains(spare) {
                let threshold = metrics["AVAILABLE_SPARE_THRESHOLD"] as? Int
                rows.append(.init(id: id + "-spare", title: "Available spare capacity", state: threshold.map { spare < $0 } == true ? .attention : .information,
                    detail: "\(spare)%" + (threshold.map { " · manufacturer threshold \($0)%" } ?? " · threshold unavailable"), source: "diskutil · AVAILABLE_SPARE"))
            }
            if let errors = (metrics["MEDIA_ERRORS_0"] as? NSNumber).flatMap({ $0.doubleValue >= 0 ? $0.uint64Value : nil }), let high = (metrics["MEDIA_ERRORS_1"] as? NSNumber).flatMap({ $0.doubleValue >= 0 ? $0.uint64Value : nil }) {
                rows.append(.init(id: id + "-errors", title: "Media errors", state: errors > 0 || high > 0 ? .attention : .information,
                    detail: high == 0 ? "\(errors) cumulative media errors reported by the drive." : "The drive reports a nonzero cumulative media error count.", source: "diskutil · MEDIA_ERRORS"))
            }
        }
        return rows
    }

    static func securityResult(id: String, title: String, output: String, enabled: String, disabled: String, advice: String) -> HealthFinding {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let state: HealthFinding.State = value == enabled ? .passed : value == disabled ? .attention : .unavailable
        return .init(id: id, title: title, state: state,
                     detail: state == .passed ? value : state == .attention ? value + " " + advice : "macOS returned an unrecognized or transitional status. Check System Settings.",
                     source: id)
    }

    static func local() -> LocalHealthReport {
        var report = LocalHealthReport()
        do {
            let disks = try plist(HealthCommand.run("/usr/sbin/diskutil", ["list", "-plist", "physical"]))
            guard let ids = disks["WholeDisks"] as? [String], !ids.isEmpty else { throw ToolFailure(message: "No physical drives were reported.") }
            for id in ids {
                guard id.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else { continue }
                do { report.storage += smart(try plist(HealthCommand.run("/usr/sbin/diskutil", ["info", "-plist", id])), id: id) }
                catch { report.storage.append(unavailable(id, title: "\(id) · SMART", error: error)) }
            }
        } catch { report.storage.append(unavailable("drives", title: "Physical drives", error: error)) }
        do {
            let values = try URL(fileURLWithPath: "/System/Volumes/Data").resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
            guard let free = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity, total > 0 else {
                throw ToolFailure(message: "Available capacity could not be read.")
            }
            report.storage.append(.init(id: "capacity", title: "Startup disk space", state: Double(free) / Double(total) < 0.1 ? .attention : .passed,
                detail: "\(Int64(free).bytes) available of \(Int64(total).bytes). Ballast flags less than 10% free.", source: "macOS volume capacity"))
        } catch { report.storage.append(unavailable("capacity", title: "Startup disk space", error: error)) }
        let checks = [
            ("/usr/bin/fdesetup", ["status"], "FileVault", "FileVault is On.", "FileVault is Off.", "Turn on disk encryption in Privacy & Security."),
            ("/usr/bin/csrutil", ["status"], "System Integrity Protection", "System Integrity Protection status: enabled.", "System Integrity Protection status: disabled.", "Review why SIP is disabled before changing it in Recovery."),
            ("/usr/sbin/spctl", ["--status"], "Gatekeeper", "assessments enabled", "assessments disabled", "Review app security in Privacy & Security."),
            ("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"], "Firewall", "Firewall is enabled. (State = 1)", "Firewall is disabled. (State = 0)", "Review incoming connections in Network → Firewall.")
        ]
        for (path, args, title, on, off, advice) in checks {
            do {
                let output = String(decoding: try HealthCommand.run(path, args), as: UTF8.self)
                report.security.append(securityResult(id: path, title: title, output: output, enabled: on, disabled: off, advice: advice))
            } catch { report.security.append(unavailable(path, title: title, error: error)) }
        }
        return report
    }

    private static func unavailable(_ id: String, title: String, error: Error) -> HealthFinding {
        .init(id: id, title: title, state: .unavailable, detail: error.localizedDescription, source: "Local macOS check")
    }
}

struct VulnerabilityPackage: Hashable, Sendable {
    let name: String
    let version: String
}

struct VulnerabilityInventory: Sendable {
    let packages: [VulnerabilityPackage]
    let excluded: Int

    static func package(name: String, version: String, receipt: Data) throws -> VulnerabilityPackage? {
        struct Receipt: Decodable {
            struct Source: Decodable { let tap: String?; let spec: String? }
            let source: Source
        }
        let source = try JSONDecoder().decode(Receipt.self, from: receipt).source
        guard source.tap == "homebrew/core", source.spec == "stable",
              !name.isEmpty, !version.isEmpty, !version.hasPrefix("HEAD") else { return nil }
        return .init(name: name, version: version)
    }

    /// Read installation receipts rather than invoking brew: even inventory commands
    /// can refresh remote metadata. This preparation step must be strictly offline.
    static func read(prefixes: [String] = ["/opt/homebrew", "/usr/local"]) throws -> Self {
        let fm = FileManager.default
        var packages = Set<VulnerabilityPackage>()
        var excluded = 0
        var found = false
        func children(_ url: URL) throws -> [URL] {
            try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                .filter { child in
                    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    return values.isDirectory == true && values.isSymbolicLink != true
                }
        }
        for prefix in prefixes {
            let cellar = URL(fileURLWithPath: prefix).appendingPathComponent("Cellar")
            guard fm.fileExists(atPath: cellar.path) else { continue }
            found = true
            for formula in try children(cellar) {
                for version in try children(formula) {
                    let receipt = version.appendingPathComponent("INSTALL_RECEIPT.json")
                    guard let size = try? receipt.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                          size.isSymbolicLink != true, (size.fileSize ?? Int.max) < 1_000_000,
                          let data = try? Data(contentsOf: receipt),
                          let package = try? package(name: formula.lastPathComponent, version: version.lastPathComponent, receipt: data) else {
                        excluded += 1
                        continue
                    }
                    packages.insert(package)
                }
            }
            let casks = URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom")
            if fm.fileExists(atPath: casks.path) { excluded += try children(casks).count }
        }
        guard found else { throw ToolFailure(message: "No Homebrew Cellar was found in /opt/homebrew or /usr/local. Custom prefixes and app bundles are not covered.") }
        return Self(packages: packages.sorted { ($0.name, $0.version) < ($1.name, $1.version) }, excluded: excluded)
    }
}

struct VulnerabilityMatch: Identifiable, Sendable {
    let package: VulnerabilityPackage
    let advisory: String
    var id: String { package.name + "@" + package.version + ":" + advisory }
    var url: URL { URL(string: "https://osv.dev/vulnerability/")!.appendingPathComponent(advisory) }
}

struct VulnerabilityReport: Sendable {
    let checked: Int
    let excluded: Int
    let matches: [VulnerabilityMatch]
    let date = Date()
}

enum VulnerabilityCheck {
    struct Batch: Decodable {
        struct Result: Decodable {
            struct Advisory: Decodable { let id: String }
            let vulns: [Advisory]?
            let next_page_token: String?
        }
        let results: [Result]
    }

    static func scan(_ inventory: VulnerabilityInventory,
                     send: @Sendable (Data) async throws -> Data = request) async throws -> VulnerabilityReport {
        var matches: [String: VulnerabilityMatch] = [:]
        for start in stride(from: 0, to: inventory.packages.count, by: 100) {
            var pending = Array(inventory.packages[start..<min(start + 100, inventory.packages.count)]).map { ($0, "") }
            var pages = 0
            while !pending.isEmpty {
                try Task.checkCancellation()
                pages += 1
                guard pages <= 20 else { throw ToolFailure(message: "OSV returned too many pages. The check is incomplete; try again later.") }
                let queries = pending.map { package, token -> [String: Any] in
                    var query: [String: Any] = ["package": ["name": package.name, "ecosystem": "Homebrew"], "version": package.version]
                    if !token.isEmpty { query["page_token"] = token }
                    return query
                }
                let data = try JSONSerialization.data(withJSONObject: ["queries": queries])
                let response = try JSONDecoder().decode(Batch.self, from: await send(data))
                try Task.checkCancellation()
                guard response.results.count == pending.count else { throw ToolFailure(message: "OSV returned an incomplete response. No clean result can be reported.") }
                var next: [(VulnerabilityPackage, String)] = []
                for (entry, result) in zip(pending, response.results) {
                    for advisory in result.vulns ?? [] {
                        guard !advisory.id.isEmpty else { throw ToolFailure(message: "OSV returned an invalid advisory.") }
                        let match = VulnerabilityMatch(package: entry.0, advisory: advisory.id)
                        matches[match.id] = match
                    }
                    if let token = result.next_page_token, !token.isEmpty { next.append((entry.0, token)) }
                }
                pending = next
            }
        }
        return .init(checked: inventory.packages.count, excluded: inventory.excluded, matches: matches.values.sorted { $0.id < $1.id })
    }

    static func request(_ body: Data) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.osv.dev/v1/querybatch")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToolFailure(message: "OSV could not complete the request. The vulnerability check is incomplete.")
        }
        guard data.count <= 16_000_000 else { throw ToolFailure(message: "OSV response exceeded the size limit.") }
        return data
    }
}
