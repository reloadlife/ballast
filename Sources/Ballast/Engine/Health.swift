import Darwin
import Foundation
import os

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
    static let outputLimit = 16_000_000

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15, cancel: CancelFlag? = nil) throws -> Data {
        let result: CommandResult
        do {
            result = try CommandRunner.runSync(path, arguments, timeout: .milliseconds(Int(timeout * 1000)),
                                               environment: CommandEnvironment.diagnostics, quality: .utility,
                                               outputLimit: outputLimit + 1, cancel: cancel)
        } catch let error as CommandError {
            switch error.reason {
            case .timedOut: throw ToolFailure(message: "The check timed out. Try again later.")
            case .cancelled: throw ToolFailure(message: "The check was cancelled.")
            case .launch: throw ToolFailure(message: "The system tool for this check isn't available on this Mac.")
            }
        }
        guard result.succeeded else {
            let detail = result.tail()
            throw ToolFailure(message: "The system tool could not complete this check (exit \(result.status))" + (detail.isEmpty ? "." : ": \(detail)"))
        }
        guard !result.truncated, result.stdout.count <= outputLimit else {
            throw ToolFailure(message: "The diagnostic output exceeded the size limit.")
        }
        return result.stdout
    }
}

/// Findings from one check, with where they go in the report.
struct HealthUpdate: Sendable {
    let storage: Bool
    let order: Int
    let findings: [HealthFinding]
}

struct LocalHealthReport: Sendable {
    var storage: [HealthFinding] = []
    var security: [HealthFinding] = []
    let date = Date()
    private var orders: [String: Int] = [:]

    init() {}

    /// Checks finish in any order; the report always reads in the same one.
    mutating func insert(_ update: HealthUpdate) {
        for (index, finding) in update.findings.enumerated() {
            orders[finding.id] = update.order * 100 + index
        }
        let orders = orders
        func sorted(_ list: [HealthFinding]) -> [HealthFinding] {
            list.sorted { (orders[$0.id] ?? .max, $0.id) < (orders[$1.id] ?? .max, $1.id) }
        }
        let ids = Set(update.findings.map(\.id))
        if update.storage {
            storage = sorted(storage.filter { !ids.contains($0.id) } + update.findings)
        } else {
            security = sorted(security.filter { !ids.contains($0.id) } + update.findings)
        }
    }
}

/// One security setting read from a command-line tool.
struct SecurityCheck: Sendable {
    let path: String
    let arguments: [String]
    let title: String
    let enabled: String
    let disabled: String
    let advice: String

    static let all = [
        SecurityCheck(path: "/usr/bin/fdesetup", arguments: ["status"], title: "FileVault", enabled: "FileVault is On.",
                      disabled: "FileVault is Off.", advice: "Turn on disk encryption in Privacy & Security."),
        SecurityCheck(path: "/usr/bin/csrutil", arguments: ["status"], title: "System Integrity Protection",
                      enabled: "System Integrity Protection status: enabled.", disabled: "System Integrity Protection status: disabled.",
                      advice: "Review why SIP is disabled before changing it in Recovery."),
        SecurityCheck(path: "/usr/sbin/spctl", arguments: ["--status"], title: "Gatekeeper", enabled: "assessments enabled",
                      disabled: "assessments disabled", advice: "Review app security in Privacy & Security."),
        SecurityCheck(path: "/usr/libexec/ApplicationFirewall/socketfilterfw", arguments: ["--getglobalstate"], title: "Firewall",
                      enabled: "Firewall is enabled. (State = 1)", disabled: "Firewall is disabled. (State = 0)",
                      advice: "Review incoming connections in Network → Firewall."),
    ]
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

    /// Compares the tool's first line with the exact enabled and disabled
    /// wording; extra lines (a custom SIP configuration's details) are ignored.
    static func securityResult(id: String, title: String, output: String, enabled: String, disabled: String, advice: String) -> HealthFinding {
        let value = firstLine(output)
        let state: HealthFinding.State = value == enabled ? .passed : value == disabled ? .attention : .unavailable
        return finding(id: id, title: title, state: state, value: value, advice: advice)
    }

    /// A security check's result, with the tools whose wording varies read
    /// by what they mean rather than by exact text.
    static func security(_ check: SecurityCheck, output: String) -> HealthFinding {
        let value = firstLine(output)
        if check.path.hasSuffix("/socketfilterfw"),
           let match = output.firstMatch(of: /State = (\d+)/), let state = Int(match.1) {
            // 2 is "block all incoming connections": on, and stricter than 1.
            switch state {
            case 1: return finding(id: check.path, title: check.title, state: .passed, value: "Firewall is on.", advice: check.advice)
            case 2: return finding(id: check.path, title: check.title, state: .passed,
                                   value: "Firewall is on and blocks all incoming connections.", advice: check.advice)
            case 0: return finding(id: check.path, title: check.title, state: .attention, value: "Firewall is off.", advice: check.advice)
            default: break
            }
        }
        if check.path.hasSuffix("/fdesetup"), let line = output.split(separator: "\n").first(where: { $0.localizedCaseInsensitiveContains("in progress") }) {
            return .init(id: check.path, title: check.title, state: .information,
                         detail: line.trimmingCharacters(in: .whitespaces) + " Check again when it finishes.", source: check.path)
        }
        return securityResult(id: check.path, title: check.title, output: value, enabled: check.enabled,
                              disabled: check.disabled, advice: check.advice)
    }

    private static func firstLine(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private static func finding(id: String, title: String, state: HealthFinding.State, value: String, advice: String) -> HealthFinding {
        .init(id: id, title: title, state: state,
              detail: state == .passed ? value : state == .attention ? value + " " + advice : "macOS returned an unrecognized or transitional status. Check System Settings.",
              source: id)
    }

    /// Each check is independent; `yield` gets its findings as soon as it
    /// finishes. Commands block the calling thread, so these run on GCD
    /// threads, never on Swift's shared pool.
    static func jobs(cancel: CancelFlag) -> [@Sendable (_ yield: @Sendable (HealthUpdate) -> Void) -> Void] {
        var jobs: [@Sendable (_ yield: @Sendable (HealthUpdate) -> Void) -> Void] = []
        jobs.append { yield in
            do {
                let disks = try plist(HealthCommand.run("/usr/sbin/diskutil", ["list", "-plist", "physical"], cancel: cancel))
                guard let ids = disks["WholeDisks"] as? [String], !ids.isEmpty else { throw ToolFailure(message: "No physical drives were reported.") }
                let valid = ids.filter { $0.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil }
                // One stuck external drive mustn't hold up the others.
                DispatchQueue.concurrentPerform(iterations: valid.count) { index in
                    let id = valid[index]
                    let rows: [HealthFinding]
                    do { rows = smart(try plist(HealthCommand.run("/usr/sbin/diskutil", ["info", "-plist", id], cancel: cancel)), id: id) }
                    catch { rows = [unavailable(id + "-smart", title: "\(id) · SMART", error: error)] }
                    if !cancel.isSet { yield(HealthUpdate(storage: true, order: 10 + index, findings: rows)) }
                }
            } catch {
                yield(HealthUpdate(storage: true, order: 0, findings: [unavailable("drives", title: "Physical drives", error: error)]))
            }
        }
        jobs.append { yield in
            yield(HealthUpdate(storage: true, order: 10_000, findings: [capacity()]))
        }
        for (index, check) in SecurityCheck.all.enumerated() {
            jobs.append { yield in
                let row: HealthFinding
                do { row = security(check, output: String(decoding: try HealthCommand.run(check.path, check.arguments, cancel: cancel), as: UTF8.self)) }
                catch { row = unavailable(check.path, title: check.title, error: error) }
                if !cancel.isSet { yield(HealthUpdate(storage: false, order: index, findings: [row])) }
            }
        }
        return jobs
    }

    /// All local checks, run side by side; returns when the last finishes.
    static func local() -> LocalHealthReport {
        let jobs = jobs(cancel: CancelFlag())
        let updates = OSAllocatedUnfairLock(initialState: [HealthUpdate]())
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let job = jobs[index]
            job { update in updates.withLock { $0.append(update) } }
        }
        var report = LocalHealthReport()
        for update in updates.withLock({ $0 }) { report.insert(update) }
        return report
    }

    /// The same checks, delivered as each one finishes. Ending the stream
    /// (the consuming task is cancelled) stops the tools still running.
    static func updates() -> AsyncStream<HealthUpdate> {
        AsyncStream { continuation in
            let cancel = CancelFlag()
            let group = DispatchGroup()
            for job in jobs(cancel: cancel) {
                DispatchQueue.global(qos: .utility).async(group: group) {
                    job { update in continuation.yield(update) }
                }
            }
            group.notify(queue: .global(qos: .utility)) { continuation.finish() }
            continuation.onTermination = { _ in cancel.set() }
        }
    }

    private static func capacity() -> HealthFinding {
        do {
            let values = try URL(fileURLWithPath: "/System/Volumes/Data").resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
            guard let free = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity, total > 0 else {
                throw ToolFailure(message: "Available capacity could not be read.")
            }
            return .init(id: "capacity", title: "Startup disk space", state: Double(free) / Double(total) < 0.1 ? .attention : .passed,
                         detail: "\(Int64(free).bytes) available of \(Int64(total).bytes). Ballast flags less than 10% free.", source: "macOS volume capacity")
        } catch {
            return unavailable("capacity", title: "Startup disk space", error: error)
        }
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
