import CoreServices
import Foundation

struct ToolFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Developer tools through `CommandRunner`: no shell, the user's PATH,
/// Homebrew kept from updating itself, and a deadline on every run.
enum ToolCommand {
    /// Blocking form for synchronous callers. Throws with the tool's own
    /// error output when it exits non-zero.
    static func run(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(600)) throws -> String {
        try checked(CommandRunner.runSync(executable, arguments, timeout: timeout), executable: executable)
    }

    static func output(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(600),
                       quality: QualityOfService = .userInitiated) async throws -> String {
        try checked(await CommandRunner.run(executable, arguments, timeout: timeout, quality: quality), executable: executable)
    }

    private static func checked(_ result: CommandResult, executable: String) throws -> String {
        guard result.succeeded else {
            throw ToolFailure(message: result.tail(8000).nonempty
                              ?? "\((executable as NSString).lastPathComponent) exited with status \(result.status).")
        }
        return result.output
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}

/// Decodes one element of a list on its own, so one entry Homebrew changed
/// the shape of drops that entry instead of the whole list.
private struct LossyDecoded<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) { value = try? Value(from: decoder) }
}

private extension Array {
    func values<Value>() -> [Value] where Element == LossyDecoded<Value> { compactMap(\.value) }
}

struct BrewPackage: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Sendable, Codable { case formula, cask }
    let name: String
    let kind: Kind
    var installed: String
    var available: String
    var description: String
    var outdated: Bool
    var pinned: Bool
    var bytes: Int64? = nil
    var lastUsed: Date? = nil
    /// False when Homebrew installed it only as another package's dependency.
    var installedOnRequest = true
    /// A dependency nothing installed needs any more (`brew autoremove` candidate).
    var orphaned = false
    /// Older versions still in the Cellar, which `brew cleanup` removes.
    var oldVersions: [String] = []
    var oldVersionBytes: Int64? = nil
    /// Runtime dependencies from the install receipt, as full names.
    var dependencies: [String] = []
    var id: String { "\(kind.rawValue):\(name)" }
    /// "node" for "node", "same" for "team/tap/same".
    var token: String { String(name.split(separator: "/").last ?? Substring(name)) }

    enum Sort: String, CaseIterable, Identifiable {
        case name = "Name"
        case size = "Largest first"
        case oldestUse = "Least recently used"
        case newestUse = "Recently used"
        var id: Self { self }
    }

    static func sorted(_ packages: [Self], by order: Sort) -> [Self] {
        packages.sorted { lhs, rhs in
            if order == .size, lhs.bytes != rhs.bytes {
                return (lhs.bytes ?? -1) > (rhs.bytes ?? -1)
            }
            if order == .oldestUse || order == .newestUse, lhs.lastUsed != rhs.lastUsed {
                guard let left = lhs.lastUsed else { return false }
                guard let right = rhs.lastUsed else { return true }
                return order == .oldestUse ? left < right : left > right
            }
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }

    /// What the list shows for a search and filter, in the chosen order.
    static func visible(_ packages: [Self], query: String, updatesOnly: Bool, sort: Sort) -> [Self] {
        sorted(packages.filter {
            (!updatesOnly || $0.outdated) && (query.isEmpty || "\($0.name) \($0.description)".localizedStandardContains(query))
        }, by: sort)
    }
}

/// What a background check learned about an installed package.
struct BrewUpdate: Sendable, Equatable {
    let available: String
    let pinned: Bool
}

enum Homebrew {
    /// Resolved once: the list view reads it on every render.
    static let executable: String? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", NSHomeDirectory() + "/.linuxbrew/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// /opt/homebrew/bin/brew → /opt/homebrew. Cellar and Caskroom live
    /// directly under the prefix, so no `brew --cellar` process is needed.
    static func prefix(for executable: String) -> String {
        URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().path
    }

    // MARK: Install receipts (no brew process)

    private struct Dependencies: Decodable {
        struct Dependency: Decodable { let full_name: String? }
        var names: [String] = []
        // Formula receipts list dependencies; cask receipts use a dictionary
        // keyed by kind. Anything else counts as none.
        init(from decoder: any Decoder) {
            guard let single = try? decoder.singleValueContainer() else { return }
            if let list = try? single.decode([LossyDecoded<Dependency>].self) {
                names = list.values().compactMap(\.full_name)
            } else if let byKind = try? single.decode([String: [LossyDecoded<Dependency>]].self) {
                names = byKind.values.flatMap { $0.values().compactMap(\.full_name) }
            }
        }
    }

    private struct Receipt: Decodable {
        struct Source: Decodable {
            let tap: String?
            let version: String?
        }
        let installed_on_request: Bool?
        let time: Double?
        let source: Source?
        let runtime_dependencies: Dependencies?
    }

    private static func receipt(at url: URL) -> Receipt? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, (values.fileSize ?? .max) < 4_000_000,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    private static func folders(in url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                       options: .skipsHiddenFiles)) ?? [])
            .filter { child in
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func fullName(_ token: String, tap: String?, core: String) -> String {
        guard let tap, !tap.isEmpty, tap != core else { return token }
        return tap + "/" + token
    }

    /// Everything installed under `prefix`, read from Homebrew's own install
    /// receipts. Descriptions, latest versions and sizes come later.
    static func inventory(prefix: String) -> [BrewPackage] {
        let root = URL(fileURLWithPath: prefix)
        var packages = folders(in: root.appendingPathComponent("Cellar")).compactMap { formula(at: $0, prefix: root) }
        packages += folders(in: root.appendingPathComponent("Caskroom")).compactMap { cask(at: $0) }
        return markOrphans(packages)
    }

    /// One formula or cask, after a change to it; nil once it's gone.
    static func package(_ name: String, kind: BrewPackage.Kind, prefix: String) -> BrewPackage? {
        let root = URL(fileURLWithPath: prefix)
        let token = String(name.split(separator: "/").last ?? Substring(name))
        let folder = root.appendingPathComponent(kind == .formula ? "Cellar" : "Caskroom").appendingPathComponent(token)
        return kind == .formula ? formula(at: folder, prefix: root) : cask(at: folder)
    }

    private static func formula(at folder: URL, prefix: URL) -> BrewPackage? {
        let token = folder.lastPathComponent
        let versions = folders(in: folder)
        guard !versions.isEmpty else { return nil }
        let receipts = Dictionary(uniqueKeysWithValues: versions.map { ($0.lastPathComponent, receipt(at: $0.appendingPathComponent("INSTALL_RECEIPT.json"))) })
        // The linked keg is the one in use; otherwise the newest install.
        let linked = (try? FileManager.default.destinationOfSymbolicLink(atPath: prefix.appendingPathComponent("opt/" + token).path))
            .map { ($0 as NSString).lastPathComponent }
        let names = versions.map(\.lastPathComponent)
        let current = linked.flatMap { names.contains($0) ? $0 : nil } ?? names.max { lhs, rhs in
            let left = receipts[lhs]??.time ?? 0, right = receipts[rhs]??.time ?? 0
            return left == right ? lhs.localizedStandardCompare(rhs) == .orderedAscending : left < right
        } ?? names[0]
        let receipt = receipts[current] ?? nil
        let pinned = FileManager.default.fileExists(atPath: prefix.appendingPathComponent("var/homebrew/pinned/" + token).path)
        // An unreadable receipt mustn't make a package look like an orphan.
        return BrewPackage(name: fullName(token, tap: receipt?.source?.tap, core: "homebrew/core"), kind: .formula,
                           installed: current, available: current, description: "", outdated: false, pinned: pinned,
                           installedOnRequest: receipt?.installed_on_request ?? true,
                           oldVersions: names.filter { $0 != current },
                           dependencies: receipt?.runtime_dependencies?.names ?? [])
    }

    private static func cask(at folder: URL) -> BrewPackage? {
        let token = folder.lastPathComponent
        let metadata = folder.appendingPathComponent(".metadata")
        let receipt = receipt(at: metadata.appendingPathComponent("INSTALL_RECEIPT.json"))
        // .metadata/<version>/<timestamp>/Casks/<token>.json: the newest
        // timestamp is the version installed now.
        let stamped = folders(in: metadata).compactMap { version -> (version: String, stamp: String, folder: URL)? in
            guard let newest = folders(in: version).max(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return nil }
            return (version.lastPathComponent, newest.lastPathComponent, newest)
        }.max { $0.stamp < $1.stamp }
        let versionFolders = folders(in: folder).filter { !$0.lastPathComponent.hasSuffix(".upgrading") }
        guard stamped != nil || !versionFolders.isEmpty || receipt != nil else { return nil }
        let newestFolder = versionFolders.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        let installed = stamped?.version ?? newestFolder?.lastPathComponent ?? receipt?.source?.version ?? "Unknown"
        var description = ""
        if let stamped {
            struct Definition: Decodable { let desc: String? }
            let definition = stamped.folder.appendingPathComponent("Casks/\(token).json")
            if let size = try? definition.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 4_000_000,
               let data = try? Data(contentsOf: definition),
               let desc = (try? JSONDecoder().decode(Definition.self, from: data))?.desc {
                description = desc
            }
        }
        return BrewPackage(name: fullName(token, tap: receipt?.source?.tap, core: "homebrew/cask"), kind: .cask,
                           installed: installed, available: installed, description: description, outdated: false, pinned: false,
                           installedOnRequest: receipt?.installed_on_request ?? true,
                           dependencies: receipt?.runtime_dependencies?.names ?? [])
    }

    /// Dependencies installed for something that's gone since.
    static func markOrphans(_ packages: [BrewPackage]) -> [BrewPackage] {
        var needed = Set<String>()
        for package in packages {
            for dependency in package.dependencies {
                needed.insert(dependency)
                needed.insert(String(dependency.split(separator: "/").last ?? Substring(dependency)))
            }
        }
        return packages.map { package in
            var package = package
            package.orphaned = package.kind == .formula && !package.installedOnRequest
                && !needed.contains(package.name) && !needed.contains(package.token)
            return package
        }
    }

    /// Changes whenever a package is installed, upgraded or removed: the
    /// Cellar and Caskroom folders and each package's own folder.
    static func fingerprint(prefix: String) -> String {
        var text = ""
        for area in ["Cellar", "Caskroom"] {
            let url = URL(fileURLWithPath: prefix).appendingPathComponent(area)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            text += "\(area)=\(date);"
            let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
                text += "\(child.lastPathComponent)=\(modified);"
            }
        }
        // FNV-1a: stable across launches, unlike Hasher.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    // MARK: Saved inventory

    struct Cache: Codable, Sendable {
        static let currentVersion = 1
        var version = Cache.currentVersion
        var prefix: String
        var fingerprint: String
        var packages: [BrewPackage]
    }

    static let cacheFile = Paths.supportDir + "/homebrew-inventory.json"

    static func loadCache(prefix: String, from path: String = cacheFile) -> Cache? {
        guard let data = FileManager.default.contents(atPath: path),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == Cache.currentVersion, cache.prefix == prefix else { return nil }
        return cache
    }

    static func saveCache(_ cache: Cache, to path: String = cacheFile) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Fresh receipts, keeping what was already known about packages whose
    /// installed version hasn't changed (latest version, description, size).
    static func merge(_ fresh: [BrewPackage], keeping previous: [BrewPackage]) -> [BrewPackage] {
        let known = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return fresh.map { package in
            guard let old = known[package.id] else { return package }
            var package = package
            if package.description.isEmpty { package.description = old.description }
            package.bytes = old.bytes
            package.lastUsed = old.lastUsed
            if package.oldVersions == old.oldVersions { package.oldVersionBytes = old.oldVersionBytes }
            if old.installed == package.installed {
                package.available = old.available
                package.outdated = old.outdated
                if package.kind == .cask { package.pinned = old.pinned }
            }
            return package
        }
    }

    // MARK: Sizes and last use (disk index, Spotlight)

    static func measure(_ packages: [BrewPackage], prefix: String) -> [BrewPackage] {
        let db = FileManager.default.fileExists(atPath: Paths.index) ? try? IndexDB(path: Paths.index, mode: .read) : nil
        func size(_ path: String) -> Int64? {
            let indexed = Paths.onVolume(path)
            guard let row = try? db?.locate(indexed).last, row.path == indexed, row.row.err == 0 else { return nil }
            return row.row.total
        }
        return packages.map { package in
            var package = package
            let storage = prefix + "/" + (package.kind == .formula ? "Cellar" : "Caskroom") + "/" + package.token
            let apps = package.kind == .cask ? linkedApps(in: storage) : []
            let paths = Set([storage] + apps).sorted().reduce(into: [String]()) { roots, path in
                if !roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { roots.append(path) }
            }
            let sizes = paths.map(size)
            package.bytes = sizes.allSatisfy { $0 != nil } ? sizes.compactMap { $0 }.reduce(0, +) : nil
            let old = package.oldVersions.map { size(storage + "/" + $0) }
            package.oldVersionBytes = !old.isEmpty && old.allSatisfy { $0 != nil } ? old.compactMap { $0 }.reduce(0, +) : nil
            package.lastUsed = apps.compactMap { path in
                AppScanner.recorded(MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL)
                    .flatMap { MDItemCopyAttribute($0, "kMDItemLastUsedDate" as CFString) as? Date })
            }.max()
            return package
        }
    }

    /// Caskroom retains links to apps moved into the user's chosen appdir.
    /// Resolve those links instead of assuming every app lives in /Applications.
    static func linkedApps(in storage: String) -> [String] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: storage)
        var apps = Set<String>()
        for version in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
            guard (try? version.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            for app in (try? fm.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)) ?? [] where app.pathExtension == "app" {
                let resolved = Paths.canonical(app.path)
                if fm.fileExists(atPath: resolved) { apps.insert(resolved) }
            }
        }
        return apps.sorted()
    }

    // MARK: brew's JSON

    /// `brew info --json=v2 --installed`. A malformed entry is skipped; a
    /// response without both lists isn't Homebrew's inventory and throws.
    static func parse(_ data: Data) throws -> [BrewPackage] {
        struct Inventory: Decodable {
            struct Formula: Decodable {
                struct Installed: Decodable { let version: String }
                struct Versions: Decodable { let stable: String? }
                let name: String
                let full_name: String?
                let desc: String?
                let installed: [LossyDecoded<Installed>]?
                let versions: Versions?
                let outdated: Bool?
                let pinned: Bool?
            }
            struct Cask: Decodable {
                let token: String
                let full_token: String?
                let desc: String?
                let installed: String?
                let version: String?
                let outdated: Bool?
            }
            let formulae: [LossyDecoded<Formula>]
            let casks: [LossyDecoded<Cask>]
        }
        let inventory = try JSONDecoder().decode(Inventory.self, from: data)
        return (inventory.formulae.values().map {
            let installed = ($0.installed ?? []).values().map(\.version).joined(separator: ", ")
            return BrewPackage(name: $0.full_name ?? $0.name, kind: .formula, installed: installed,
                               available: $0.versions?.stable ?? "HEAD", description: $0.desc ?? "",
                               outdated: $0.outdated ?? false, pinned: $0.pinned ?? false)
        } + inventory.casks.values().map {
            BrewPackage(name: $0.full_token ?? $0.token, kind: .cask, installed: $0.installed ?? "Unknown",
                        available: $0.version ?? "Unknown", description: $0.desc ?? "", outdated: $0.outdated ?? false, pinned: false)
        }).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `brew outdated --json=v2`, keyed by package id ("formula:node").
    static func parseOutdated(_ data: Data) throws -> [String: BrewUpdate] {
        struct Entry: Decodable {
            let name: String
            let current_version: String?
            let pinned: Bool?
        }
        struct Outdated: Decodable {
            let formulae: [LossyDecoded<Entry>]?
            let casks: [LossyDecoded<Entry>]?
        }
        let outdated = try JSONDecoder().decode(Outdated.self, from: data)
        guard outdated.formulae != nil || outdated.casks != nil else {
            throw ToolFailure(message: "Homebrew returned an unrecognized list of updates.")
        }
        var updates: [String: BrewUpdate] = [:]
        for (kind, entries) in [(BrewPackage.Kind.formula, outdated.formulae), (.cask, outdated.casks)] {
            for entry in (entries ?? []).values() {
                updates["\(kind.rawValue):\(entry.name)"] = BrewUpdate(available: entry.current_version ?? "newer", pinned: entry.pinned ?? false)
            }
        }
        return updates
    }

    /// Marks what has an update; everything else is current.
    static func apply(_ updates: [String: BrewUpdate], to packages: [BrewPackage]) -> [BrewPackage] {
        packages.map { package in
            var package = package
            if let update = updates[package.id] ?? updates["\(package.kind.rawValue):\(package.token)"] {
                package.outdated = true
                package.available = update.available
                if package.kind == .formula { package.pinned = package.pinned || update.pinned }
            } else {
                package.outdated = false
                package.available = package.installed
            }
            return package
        }
    }

    /// Descriptions from `brew info`, which install receipts don't carry.
    static func apply(details: [BrewPackage], to packages: [BrewPackage]) -> [BrewPackage] {
        let byID = Dictionary(details.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byToken = Dictionary(details.map { ("\($0.kind.rawValue):\($0.token)", $0) }, uniquingKeysWith: { first, _ in first })
        return packages.map { package in
            guard let detail = byID[package.id] ?? byToken["\(package.kind.rawValue):\(package.token)"] else { return package }
            var package = package
            if !detail.description.isEmpty { package.description = detail.description }
            if package.kind == .formula { package.pinned = detail.pinned }
            return package
        }
    }

    // MARK: Changes

    static func arguments(_ verb: String, package: BrewPackage) -> [String] {
        [verb, "--\(package.kind.rawValue)", "--", package.name]
    }

    /// What to tell the user when a change fails. Some packages (casks with
    /// .pkg installers) need sudo, which a GUI app has no terminal for: say
    /// which command to run in Terminal instead of showing brew's output.
    static func failure(_ output: String, verb: String, package: BrewPackage) -> (message: String, command: String?) {
        let lower = output.lowercased()
        let needsTerminal = ["sudo", "a terminal is required", "password:", "no tty present", "askpass", "administrator privileges"]
            .contains(where: lower.contains)
        let command = "brew \(verb) --\(package.kind.rawValue) \(package.name)"
        if needsTerminal {
            return ("Homebrew needs your administrator password to \(verb) \(package.name), which it can only ask for in Terminal. Run this command there:", command)
        }
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let error = lines.last { $0.hasPrefix("Error:") } ?? lines.last ?? "brew exited with an error."
        return ("Couldn't \(verb) \(package.name). \(String(error.prefix(600)))", nil)
    }
}

struct GitWorktree: Identifiable, Hashable, Sendable {
    let path: String
    let head: String
    let branch: String?
    let isMain: Bool
    let locked: Bool
    let prunable: Bool
    var id: String { path }
    var label: String { branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "Detached HEAD" }
}

enum GitWorktrees {
    static let executable = "/usr/bin/git"
    /// Status checks of one worktree; a huge or stuck one mustn't hold up the rest.
    static let checkTimeout: Duration = .seconds(10)

    static func git(_ repository: String, _ arguments: [String], timeout: Duration = .seconds(600)) throws -> String {
        try ToolCommand.run(executable, ["-C", repository] + arguments, timeout: timeout)
    }

    static func gitOutput(_ repository: String, _ arguments: [String], timeout: Duration = .seconds(600)) async throws -> String {
        try await ToolCommand.output(executable, ["-C", repository] + arguments, timeout: timeout)
    }

    static func list(_ repository: String) throws -> [GitWorktree] {
        parse(try git(repository, ["worktree", "list", "--porcelain", "-z"], timeout: checkTimeout))
    }

    static func listAsync(_ repository: String) async throws -> [GitWorktree] {
        parse(try await gitOutput(repository, ["worktree", "list", "--porcelain", "-z"], timeout: checkTimeout))
    }

    /// NUL records preserve paths containing spaces, newlines and quotes.
    static func parse(_ text: String) -> [GitWorktree] {
        text.components(separatedBy: "\0\0").filter { !$0.isEmpty }.enumerated().compactMap { index, record in
            let fields = record.components(separatedBy: "\0")
            guard let path = fields.first, path.hasPrefix("worktree ") else { return nil }
            return GitWorktree(path: String(path.dropFirst(9)),
                               head: fields.first { $0.hasPrefix("HEAD ") }.map { String($0.dropFirst(5)) } ?? "",
                               branch: fields.first { $0.hasPrefix("branch ") }.map { String($0.dropFirst(7)) },
                               isMain: index == 0,
                               locked: fields.contains { $0 == "locked" || $0.hasPrefix("locked ") },
                               prunable: fields.contains { $0 == "prunable" || $0.hasPrefix("prunable ") })
        }
    }

    // `--no-optional-locks` keeps Ballast from taking index.lock in a
    // worktree an agent is working in. Ignored files are listed separately:
    // nearly every worktree has build output, which mustn't block removal.
    private static let statusArguments = ["--no-optional-locks", "status", "--porcelain", "-z", "-uall", "--ignored=no"]
    private static let ignoredArguments = ["--no-optional-locks", "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"]
    private static let detachedArguments = ["for-each-ref", "--contains", "HEAD", "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"]

    /// Why this worktree can't be removed without Git commands, or nil.
    static func check(_ worktree: GitWorktree) throws -> String? {
        if let reason = precheck(worktree) { return reason }
        let status = try git(worktree.path, statusArguments, timeout: checkTimeout)
        let ignored = status.isEmpty ? try git(worktree.path, ignoredArguments, timeout: checkTimeout) : ""
        let refs = status.isEmpty && worktree.branch == nil ? try git(worktree.path, detachedArguments, timeout: checkTimeout) : nil
        return verdict(worktree, status: status, ignored: ignored, detachedRefs: refs)
    }

    static func checkAsync(_ worktree: GitWorktree) async throws -> String? {
        if let reason = precheck(worktree) { return reason }
        let status = try await gitOutput(worktree.path, statusArguments, timeout: checkTimeout)
        let ignored = status.isEmpty ? try await gitOutput(worktree.path, ignoredArguments, timeout: checkTimeout) : ""
        let refs = status.isEmpty && worktree.branch == nil ? try await gitOutput(worktree.path, detachedArguments, timeout: checkTimeout) : nil
        return verdict(worktree, status: status, ignored: ignored, detachedRefs: refs)
    }

    private static func precheck(_ worktree: GitWorktree) -> String? {
        if worktree.isMain { return "The main working tree stays in place. Use Clean Build Files to reclaim generated files." }
        let safety = SafetyCheck.assess(worktree.path, isDirectory: true, apps: AppInventory(running: [], installed: []))
        if safety.level == .blocked || safety.level == .quitFirst { return safety.reason }
        if worktree.locked { return "Locked by Git. Unlock it in your terminal after reviewing why it was locked." }
        if worktree.prunable { return "The directory is missing. Review and prune its registration with Git." }
        return nil
    }

    /// The decision, from Git's output. Changed and untracked files block
    /// removal; ignored files only when they aren't rebuildable build output.
    static func verdict(_ worktree: GitWorktree, status: String, ignored: String, detachedRefs: String?) -> String? {
        if !status.isEmpty { return "Contains changed or untracked files. Review them before removing this worktree." }
        let kept = ignoredKeepers(ignored, root: worktree.path)
        if !kept.isEmpty {
            let names = kept.prefix(3).joined(separator: ", ") + (kept.count > 3 ? ", …" : "")
            return "Contains ignored files that aren't build output (\(names)). Review them before removing this worktree."
        }
        if worktree.branch == nil, detachedRefs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            return "Detached commits have no branch or tag. Create a branch before removing this worktree."
        }
        return nil
    }

    /// Ignored entries worth keeping: anything but recognized build folders
    /// (node_modules, .build, DerivedData…) and Finder's .DS_Store.
    static func ignoredKeepers(_ listing: String, root: String) -> [String] {
        let base = URL(fileURLWithPath: root)
        return listing.split(separator: "\0").map(String.init).filter { entry in
            let name = entry.split(separator: "/").last.map(String.init) ?? entry
            if name == ".DS_Store" { return false }
            guard entry.hasSuffix("/"), !entry.split(separator: "/").contains("..") else { return true }
            return !Catalog.isProjectArtifact(base.appendingPathComponent(entry).standardizedFileURL)
        }
    }

    /// Re-list and re-check just before removal. Never force, delete branches,
    /// prune unrelated registrations, or bypass the generic cleaner's policy.
    static func remove(_ worktree: GitWorktree, repository: String) throws {
        guard let current = try list(repository).first(where: { $0.path == worktree.path }), current.head == worktree.head,
              current.branch == worktree.branch else {
            throw ToolFailure(message: "This worktree changed. Refresh and review it again.")
        }
        if let reason = try check(current) { throw ToolFailure(message: reason) }
        _ = try git(repository, ["worktree", "remove", "--", current.path], timeout: .seconds(300))
    }

    static func removeAsync(_ worktree: GitWorktree, repository: String) async throws {
        guard let current = try await listAsync(repository).first(where: { $0.path == worktree.path }), current.head == worktree.head,
              current.branch == worktree.branch else {
            throw ToolFailure(message: "This worktree changed. Refresh and review it again.")
        }
        if let reason = try await checkAsync(current) { throw ToolFailure(message: reason) }
        _ = try await gitOutput(repository, ["worktree", "remove", "--", current.path], timeout: .seconds(300))
    }

    /// Only ignored, recognized build folders are offered for cleanup. Git's
    /// directory listing avoids traversing dependency trees or repository data.
    static func buildFolders(_ worktree: GitWorktree) throws -> [URL] {
        guard !worktree.locked, !worktree.prunable else {
            throw ToolFailure(message: "Unlock or restore this worktree before cleaning its build files.")
        }
        return folders(try git(worktree.path, ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"],
                               timeout: .seconds(60)), root: worktree.path)
    }

    static func buildFoldersAsync(_ worktree: GitWorktree) async throws -> [URL] {
        guard !worktree.locked, !worktree.prunable else {
            throw ToolFailure(message: "Unlock or restore this worktree before cleaning its build files.")
        }
        let listing = try await gitOutput(worktree.path, ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"],
                                          timeout: .seconds(60))
        return await Task.detached(priority: .userInitiated) { folders(listing, root: worktree.path) }.value
    }

    private static func folders(_ listing: String, root path: String) -> [URL] {
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return listing.split(separator: "\0").compactMap { entry in
            let relative = String(entry)
            guard relative.hasSuffix("/"), !relative.split(separator: "/").contains("..") else { return nil }
            let url = root.appendingPathComponent(relative).standardizedFileURL
            guard url.resolvingSymlinksInPath().path == url.path,
                  url.path.hasPrefix(root.path + "/"), Catalog.isProjectArtifact(url) else { return nil }
            return url
        }
    }

    // MARK: Repositories

    /// Repositories from the disk index that look like the user's own:
    /// not Homebrew's taps, tool installs in hidden folders, dependencies
    /// or caches. Most recently used first.
    static func indexedRepositories() throws -> [String] {
        guard FileManager.default.fileExists(atPath: Paths.index) else { return [] }
        let db = try IndexDB(path: Paths.index, mode: .read)
        let found = try db.rows(named: [".git"]).compactMap { row -> String? in
            guard let parent = row.parent else { return nil }
            let path = Paths.display(try db.path(of: parent))
            return isCandidate(path) ? path : nil
        }
        return byActivity(found.filter(exists))
    }

    /// Whether a repository found on disk is worth listing.
    static func isCandidate(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let excludedRoots = [home + "/Library", "/Library", "/System", "/Applications", "/private", "/usr", "/opt/homebrew", "/Volumes/Recovery"]
        if excludedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        let components = path.split(separator: "/").map(String.init)
        let skipped: Set<String> = ["node_modules", "Pods", "Carthage", "vendor", "bower_components", "site-packages", "DerivedData", "Taps"]
        return !components.contains { $0.hasPrefix(".") || skipped.contains($0) }
    }

    static func exists(_ repository: String) -> Bool {
        FileManager.default.fileExists(atPath: repository + "/.git")
    }

    /// When the repository was last worked in: commits, checkouts, staging.
    static func lastActivity(_ repository: String) -> Date {
        ["/.git/index", "/.git/HEAD", "/.git/logs/HEAD", "/.git"].compactMap { suffix -> Date? in
            var st = stat()
            guard lstat(repository + suffix, &st) == 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        }.max() ?? .distantPast
    }

    static func byActivity(_ repositories: [String]) -> [String] {
        let dates = Dictionary(repositories.map { ($0, lastActivity($0)) }, uniquingKeysWith: { first, _ in first })
        return Array(Set(repositories)).sorted { lhs, rhs in
            let left = dates[lhs] ?? .distantPast, right = dates[rhs] ?? .distantPast
            return left == right ? lhs < rhs : left > right
        }
    }
}

/// Homebrew and Worktrees keep separate state, so work in one never holds
/// up or hides the other. A request made while something runs joins it or
/// waits its turn; nothing is dropped. Leaving a screen never abandons a
/// running tool, and every long operation can be cancelled.
@MainActor @Observable final class DeveloperToolsModel {
    static let shared = DeveloperToolsModel()

    /// One section's feedback line.
    struct Status: Equatable {
        /// What's running, for the progress line.
        var activity: String?
        var message: String?
        var failure: String?
        /// A command to run in Terminal, when Ballast can't do it itself.
        var command: String?
        var canCancel = false
        var isEmpty: Bool { activity == nil && message == nil && failure == nil }
    }

    // MARK: Homebrew

    private(set) var packages: [BrewPackage] = [] {
        didSet {
            updateCount = packages.count(where: \.outdated)
            orphanCount = packages.count(where: \.orphaned)
        }
    }
    private(set) var updateCount = 0
    private(set) var orphanCount = 0
    /// The rows on screen are real: a saved inventory or the install
    /// receipts were read. Until then the screen shows progress, not "empty".
    private(set) var brewLoaded = false
    /// Package id → what's happening to it ("Updating…", "Waiting…").
    private(set) var pendingChanges: [String: String] = [:]
    private var loadActivity: String?
    private var refreshActivity: String?
    private var changeActivity: String?
    private var brewMessage: String?
    private var brewFailure: String?
    private var brewCommand: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshToken = UUID()
    @ObservationIgnored private var changeTail: Task<Void, Never>?
    @ObservationIgnored private var changeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var fingerprint: String?

    var brew: Status {
        Status(activity: changeActivity ?? loadActivity ?? refreshActivity, message: brewMessage, failure: brewFailure,
               command: brewCommand, canCancel: changeActivity != nil || refreshActivity != nil)
    }

    /// Shows the saved inventory at once, then re-reads install receipts if
    /// anything changed on disk, then checks updates, sizes and descriptions
    /// in the background. A call during a load joins it.
    func loadBrew(force: Bool = false) async {
        if let loadTask {
            await loadTask.value
            guard force else { return }
        }
        guard let executable = Homebrew.executable else {
            brewFailure = "Homebrew wasn't found in /opt/homebrew or /usr/local."
            brewLoaded = true
            return
        }
        let task = Task { await readInventory(prefix: Homebrew.prefix(for: executable), force: force) }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func readInventory(prefix: String, force: Bool) async {
        if !brewLoaded { loadActivity = "Reading installed packages…" }
        defer { loadActivity = nil }
        if !brewLoaded, let cache = await Task.detached(priority: .userInitiated, operation: { Homebrew.loadCache(prefix: prefix) }).value {
            packages = cache.packages
            fingerprint = cache.fingerprint
            brewLoaded = true
        }
        let previous = packages
        let known = force ? nil : fingerprint
        let (current, fresh) = await Task.detached(priority: .userInitiated) { () -> (String, [BrewPackage]?) in
            let current = Homebrew.fingerprint(prefix: prefix)
            guard current != known else { return (current, nil) }
            return (current, Homebrew.merge(Homebrew.inventory(prefix: prefix), keeping: previous))
        }.value
        if let fresh { packages = fresh }
        fingerprint = current
        brewLoaded = true
        refresh(prefix: prefix)
    }

    /// Contacts Homebrew for new versions (`brew update`), then rechecks.
    func checkForUpdates() {
        guard let executable = Homebrew.executable else { return }
        dismissBrewFeedback()
        refresh(prefix: Homebrew.prefix(for: executable), update: true)
    }

    /// Background enrichment. A new request replaces the running one.
    private func refresh(prefix: String, update: Bool = false) {
        refreshTask?.cancel()
        let token = UUID()
        refreshToken = token
        refreshTask = Task { await enrich(prefix: prefix, update: update, token: token) }
    }

    private func enrich(prefix: String, update: Bool, token: UUID) async {
        defer {
            if refreshToken == token {
                refreshActivity = nil
                refreshTask = nil
            }
        }
        guard let executable = Homebrew.executable else { return }
        refreshActivity = "Measuring package sizes…"
        let snapshot = packages
        let measured = await Task.detached(priority: .utility) { Homebrew.measure(snapshot, prefix: prefix) }.value
        guard !Task.isCancelled else { return }
        packages = Self.sizes(from: measured, into: packages)
        do {
            if update {
                refreshActivity = "Updating Homebrew's package list…"
                _ = try await ToolCommand.output(executable, ["update"], timeout: .seconds(300))
            }
            refreshActivity = "Checking for updates…"
            let result = try await CommandRunner.run(executable, ["outdated", "--json=v2"], timeout: .seconds(60))
            guard result.succeeded else {
                let detail = result.tail()
                throw ToolFailure(message: detail.isEmpty ? "brew exited with status \(result.status)." : detail)
            }
            packages = Homebrew.apply(try Homebrew.parseOutdated(result.stdout), to: packages)
            if update { brewMessage = updateCount == 0 ? "Everything is up to date." : "\(updateCount) update\(updateCount == 1 ? "" : "s") available." }
        } catch is CancellationError {
            return
        } catch {
            brewFailure = "Couldn't check for updates: \(error.localizedDescription)"
        }
        if packages.contains(where: { $0.description.isEmpty }) {
            refreshActivity = "Reading descriptions…"
            if let result = try? await CommandRunner.run(executable, ["info", "--json=v2", "--installed"], timeout: .seconds(120), quality: .utility),
               result.succeeded, let details = try? Homebrew.parse(result.stdout) {
                packages = Homebrew.apply(details: details, to: packages)
            }
            guard !Task.isCancelled else { return }
        }
        let rows = packages
        fingerprint = await Task.detached(priority: .utility) { () -> String in
            let current = Homebrew.fingerprint(prefix: prefix)
            Homebrew.saveCache(Homebrew.Cache(prefix: prefix, fingerprint: current, packages: rows))
            return current
        }.value
    }

    /// Sizes measured for a snapshot, applied to the rows as they are now.
    private static func sizes(from measured: [BrewPackage], into packages: [BrewPackage]) -> [BrewPackage] {
        let byID = Dictionary(measured.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return packages.map { package in
            guard let size = byID[package.id], size.installed == package.installed else { return package }
            var package = package
            package.bytes = size.bytes
            package.lastUsed = size.lastUsed
            if size.oldVersions == package.oldVersions { package.oldVersionBytes = size.oldVersionBytes }
            return package
        }
    }

    /// Queues an upgrade or uninstall; changes run one at a time.
    func changePackage(_ package: BrewPackage, uninstall: Bool) {
        guard let executable = Homebrew.executable, pendingChanges[package.id] == nil else { return }
        pendingChanges[package.id] = "Waiting…"
        let previous = changeTail
        let task = Task {
            await previous?.value
            await perform(package, uninstall: uninstall, executable: executable)
        }
        changeTail = task
        changeTasks[package.id] = task
    }

    private func perform(_ package: BrewPackage, uninstall: Bool, executable: String) async {
        defer {
            pendingChanges[package.id] = nil
            changeTasks[package.id] = nil
            if changeTasks.isEmpty { changeActivity = nil }
        }
        guard !Task.isCancelled else { return }
        let verb = uninstall ? "uninstall" : "upgrade"
        let prefix = Homebrew.prefix(for: executable)
        pendingChanges[package.id] = uninstall ? "Uninstalling…" : "Updating…"
        changeActivity = "\(uninstall ? "Uninstalling" : "Updating") \(package.name)…"
        dismissBrewFeedback()
        do {
            let result = try await CommandRunner.run(executable, Homebrew.arguments(verb, package: package), timeout: .seconds(1800))
            if result.succeeded {
                brewMessage = "\(package.name) \(uninstall ? "uninstalled" : "updated")."
            } else {
                let failure = Homebrew.failure(result.errors + "\n" + result.output, verb: verb, package: package)
                brewFailure = failure.message
                brewCommand = failure.command
            }
        } catch is CancellationError {
            brewMessage = "Stopped. Homebrew may have finished part of the \(verb); the list shows what's installed now."
        } catch {
            brewFailure = error.localizedDescription
        }
        // Only rows whose receipts changed are replaced (an upgrade can also
        // upgrade dependencies); everything else keeps what's known about it.
        let previous = packages
        packages = await Task.detached(priority: .userInitiated) {
            Homebrew.merge(Homebrew.inventory(prefix: prefix), keeping: previous)
        }.value
        refresh(prefix: prefix)
    }

    func cancelBrew() {
        refreshTask?.cancel()
        for task in changeTasks.values { task.cancel() }
    }

    func dismissBrewFeedback() {
        brewMessage = nil
        brewFailure = nil
        brewCommand = nil
    }

    // MARK: Worktrees

    enum WorktreeState: Equatable, Sendable {
        case checking
        case removable
        case blocked(String)
        case removing
    }

    private static let repositoriesKey = "worktreeRepositories"
    private static let addedKey = "worktreeRepositoriesAdded"
    private static let selectedKey = "worktreeRepository"

    /// Most recently used first.
    private(set) var repositories: [String]
    private(set) var repository: String
    private(set) var worktrees: [GitWorktree] = []
    private(set) var states: [String: WorktreeState] = [:]
    /// The current repository's list was read (or failed to read).
    private(set) var worktreesLoaded = false
    private(set) var discovered = false
    private var loadingWorktrees = false
    private var discovering = false
    private var removing: String?
    private var gitMessage: String?
    private var gitFailure: String?
    @ObservationIgnored private var added: Set<String>
    @ObservationIgnored private var worktreeTask: Task<Void, Never>?
    @ObservationIgnored private var discoverTask: Task<Void, Never>?
    @ObservationIgnored private var removeTail: Task<Void, Never>?
    @ObservationIgnored private var removeTasks: [String: Task<Void, Never>] = [:]

    init() {
        let defaults = UserDefaults.standard
        let added = Set(defaults.stringArray(forKey: Self.addedKey) ?? [])
        self.added = added
        // Earlier versions saved every indexed repository, taps and caches included.
        repositories = (defaults.stringArray(forKey: Self.repositoriesKey) ?? [])
            .filter { GitWorktrees.isCandidate($0) || added.contains($0) }
        repository = defaults.string(forKey: Self.selectedKey) ?? ""
    }

    var git: Status {
        let checking = states.values.count { $0 == .checking }
        let activity = removing.map { "Removing \($0)…" }
            ?? (loadingWorktrees ? "Reading worktrees…" : nil)
            ?? (checking > 0 ? "Checking \(checking) worktree\(checking == 1 ? "" : "s")…" : nil)
            ?? (discovering ? "Finding repositories in the disk index…" : nil)
        return Status(activity: activity, message: gitMessage, failure: gitFailure,
                      canCancel: removing != nil || loadingWorktrees || checking > 0)
    }

    /// Nothing to list yet, but something is on its way.
    var isReadingWorktrees: Bool { loadingWorktrees || (discovering && repository.isEmpty) }

    func state(of tree: GitWorktree) -> WorktreeState { states[tree.path] ?? .checking }

    /// Lists the repository's worktrees at once, then checks them a few at
    /// a time. Choosing another repository replaces a load in progress.
    func loadWorktrees(_ path: String, addedByUser: Bool = false) async {
        worktreeTask?.cancel()
        let task = Task { await readWorktrees(path, addedByUser: addedByUser) }
        worktreeTask = task
        await task.value
    }

    private func readWorktrees(_ path: String, addedByUser: Bool) async {
        if path != repository && !worktrees.contains(where: { $0.path == path }) {
            worktrees = []
            states = [:]
        }
        repository = path
        loadingWorktrees = true
        gitFailure = nil
        let trees: [GitWorktree]
        do {
            trees = try await GitWorktrees.listAsync(path)
        } catch is CancellationError {
            loadingWorktrees = false
            return
        } catch {
            gitFailure = error.localizedDescription
            worktrees = []
            states = [:]
            loadingWorktrees = false
            worktreesLoaded = true
            return
        }
        guard !Task.isCancelled else {
            loadingWorktrees = false
            return
        }
        worktrees = trees
        states = Dictionary(trees.map { ($0.path, WorktreeState.checking) }, uniquingKeysWith: { first, _ in first })
        repository = trees.first?.path ?? path
        remember(repository, addedByUser: addedByUser)
        loadingWorktrees = false
        worktreesLoaded = true
        await withTaskGroup(of: (String, WorktreeState).self) { group in
            var queue = trees.makeIterator()
            for _ in 0..<4 {
                guard let tree = queue.next() else { break }
                group.addTask { (tree.path, await Self.verdict(for: tree)) }
            }
            for await (path, state) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if states[path] == .checking { states[path] = state }
                if let tree = queue.next() { group.addTask { (tree.path, await Self.verdict(for: tree)) } }
            }
        }
    }

    nonisolated private static func verdict(for tree: GitWorktree) async -> WorktreeState {
        do {
            return try await GitWorktrees.checkAsync(tree).map(WorktreeState.blocked) ?? .removable
        } catch is CancellationError {
            return .checking
        } catch {
            return .blocked("Couldn't verify this worktree: \(error.localizedDescription)")
        }
    }

    private func remember(_ path: String, addedByUser: Bool) {
        if addedByUser { added.insert(path) }
        if let index = repositories.firstIndex(of: path) { repositories.remove(at: index) }
        repositories.insert(path, at: 0)
        save()
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(repositories, forKey: Self.repositoriesKey)
        defaults.set(Array(added).sorted(), forKey: Self.addedKey)
        defaults.set(repository, forKey: Self.selectedKey)
    }

    /// Finds repositories in the disk index and drops ones that are gone. A
    /// call during a search joins it. Never holds up a worktree load.
    func discover() async {
        if let discoverTask {
            await discoverTask.value
            return
        }
        let task = Task { await findRepositories() }
        discoverTask = task
        await task.value
        discoverTask = nil
    }

    private func findRepositories() async {
        discovering = true
        defer {
            discovering = false
            discovered = true
        }
        let known = repositories
        let added = added
        let found = await Task.detached(priority: .utility) { () -> Result<[String], any Error> in
            Result {
                let indexed = try GitWorktrees.indexedRepositories()
                let kept = known.filter { GitWorktrees.exists($0) && (GitWorktrees.isCandidate($0) || added.contains($0)) }
                return GitWorktrees.byActivity(kept + indexed)
            }
        }.value
        switch found {
        case .success(let list):
            // The open repository stays listed even if it's outside the index.
            repositories = list.contains(repository) || repository.isEmpty ? list : [repository] + list
            save()
        case .failure(let error):
            gitFailure = "Couldn't read the disk index: \(error.localizedDescription)"
        }
        if repository.isEmpty, let first = repositories.first { await loadWorktrees(first) }
    }

    /// Removals run one at a time, each re-checked by Git just before.
    func removeWorktree(_ tree: GitWorktree) {
        guard removeTasks[tree.path] == nil else { return }
        let path = repository
        states[tree.path] = .removing
        let previous = removeTail
        let task = Task {
            await previous?.value
            await performRemoval(tree, repository: path)
        }
        removeTail = task
        removeTasks[tree.path] = task
    }

    private func performRemoval(_ tree: GitWorktree, repository path: String) async {
        defer {
            removeTasks[tree.path] = nil
            if removeTasks.isEmpty { removing = nil }
        }
        guard !Task.isCancelled else {
            if states[tree.path] == .removing { states[tree.path] = .checking }
            return
        }
        removing = tree.label
        gitMessage = nil
        gitFailure = nil
        do {
            try await GitWorktrees.removeAsync(tree, repository: path)
            gitMessage = "Worktree removed. Its branch and commits were kept."
        } catch is CancellationError {
            gitMessage = "Stopped. Refresh to see the worktree's current state."
        } catch {
            gitFailure = error.localizedDescription
        }
        removing = nil
        if repository == path { await loadWorktrees(path) }
    }

    func cancelGit() {
        worktreeTask?.cancel()
        for task in removeTasks.values { task.cancel() }
    }

    /// Feedback from a view-level action (Clean Build Files).
    func reportGit(message: String? = nil, failure: String? = nil) {
        gitMessage = message
        gitFailure = failure
    }
}
