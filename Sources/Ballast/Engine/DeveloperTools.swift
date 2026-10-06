import Foundation

struct ToolFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Arguments never pass through a shell. Files keep verbose tools from filling
/// a pipe and deadlocking; stdin is closed so password prompts fail visibly.
enum ToolCommand {
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ballast-tool-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "stdout")
        let errors = directory.appending(path: "stderr")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let out = try FileHandle(forWritingTo: output)
        let err = try FileHandle(forWritingTo: errors)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // A GUI launched from a developer shell must not inherit another repo.
        for key in Array(environment.keys) where key.hasPrefix("GIT_") && key != "GIT_TERMINAL_PROMPT" {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let stdout = try String(contentsOf: output, encoding: .utf8)
        let stderr = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            throw ToolFailure(message: String((stderr.isEmpty ? stdout : stderr).suffix(8000)).trimmingCharacters(in: .whitespacesAndNewlines).nonempty
                              ?? "\((executable as NSString).lastPathComponent) exited with status \(process.terminationStatus).")
        }
        return stdout
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}

struct BrewPackage: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case formula, cask }
    let name: String
    let kind: Kind
    let installed: String
    let available: String
    let description: String
    let outdated: Bool
    let pinned: Bool
    var id: String { "\(kind.rawValue):\(name)" }
}

enum Homebrew {
    static var executable: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", NSHomeDirectory() + "/.linuxbrew/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func packages(using executable: String) throws -> [BrewPackage] {
        try parse(Data(ToolCommand.run(executable, ["info", "--json=v2", "--installed"]).utf8))
    }

    static func parse(_ data: Data) throws -> [BrewPackage] {
        struct Inventory: Decodable {
            struct Formula: Decodable {
                struct Installed: Decodable { let version: String }
                struct Versions: Decodable { let stable: String? }
                let name: String
                let full_name: String
                let desc: String?
                let installed: [Installed]
                let versions: Versions
                let outdated: Bool
                let pinned: Bool
            }
            struct Cask: Decodable {
                let token: String
                let full_token: String?
                let desc: String?
                let installed: String?
                let version: String
                let outdated: Bool
            }
            let formulae: [Formula]
            let casks: [Cask]
        }
        let inventory = try JSONDecoder().decode(Inventory.self, from: data)
        return (inventory.formulae.map {
            BrewPackage(name: $0.full_name, kind: .formula, installed: $0.installed.map(\.version).joined(separator: ", "),
                        available: $0.versions.stable ?? "HEAD", description: $0.desc ?? "", outdated: $0.outdated, pinned: $0.pinned)
        } + inventory.casks.map {
            BrewPackage(name: $0.full_token ?? $0.token, kind: .cask, installed: $0.installed ?? "Unknown",
                        available: $0.version, description: $0.desc ?? "", outdated: $0.outdated, pinned: false)
        }).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func arguments(_ verb: String, package: BrewPackage) -> [String] {
        [verb, "--\(package.kind.rawValue)", "--", package.name]
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
    static func git(_ repository: String, _ arguments: [String]) throws -> String {
        try ToolCommand.run("/usr/bin/git", ["-C", repository] + arguments)
    }

    static func list(_ repository: String) throws -> [GitWorktree] {
        parse(try git(repository, ["worktree", "list", "--porcelain", "-z"]))
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

    static func check(_ worktree: GitWorktree) throws -> String? {
        if worktree.isMain { return "The main working tree stays in place." }
        if worktree.locked { return "Locked by Git. Unlock it in your terminal after reviewing why it was locked." }
        if worktree.prunable { return "The directory is missing. Review and prune its registration with Git." }
        let status = try git(worktree.path, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"])
        if !status.isEmpty { return "Contains changed, untracked or ignored files. Review them before removing this worktree." }
        if worktree.branch == nil {
            let refs = try git(worktree.path, ["for-each-ref", "--contains", "HEAD", "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"])
            if refs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Detached commits have no branch or tag. Create a branch before removing this worktree."
            }
        }
        return nil
    }

    /// Re-list and re-check just before removal. Never force, delete branches,
    /// prune unrelated registrations, or bypass the generic cleaner's policy.
    static func remove(_ worktree: GitWorktree, repository: String) throws {
        guard let current = try list(repository).first(where: { $0.path == worktree.path }), current.head == worktree.head,
              current.branch == worktree.branch else {
            throw ToolFailure(message: "This worktree changed. Refresh and review it again.")
        }
        if let reason = try check(current) { throw ToolFailure(message: reason) }
        _ = try git(repository, ["worktree", "remove", "--", current.path])
    }

    static func indexedRepositories() throws -> [String] {
        guard FileManager.default.fileExists(atPath: Paths.index) else { return [] }
        let db = try IndexDB(path: Paths.index, mode: .read)
        return try db.rows(named: [".git"]).compactMap { row in
            guard let parent = row.parent else { return nil }
            return Paths.display(try db.path(of: parent))
        }.sorted()
    }
}

/// One operation across all windows; leaving a screen never abandons a running tool.
@MainActor @Observable final class DeveloperToolsModel {
    static let shared = DeveloperToolsModel()
    var packages: [BrewPackage] = []
    var repositories: [String] = UserDefaults.standard.stringArray(forKey: "worktreeRepositories") ?? []
    var repository = ""
    var worktrees: [GitWorktree] = []
    var blockers: [String: String] = [:]
    var busy = false
    var activity = ""
    var message: String?
    var failure: String?
    var brewLoaded = false
    var worktreesLoaded = false

    func loadBrew(update: Bool = false) async {
        guard !busy else { return }
        guard let executable = Homebrew.executable else { failure = "Homebrew wasn't found in /opt/homebrew or /usr/local."; return }
        await perform(update ? "Checking Homebrew for updates…" : "Reading installed packages…") {
            if update { _ = try ToolCommand.run(executable, ["update"]) }
            return try Homebrew.packages(using: executable)
        } apply: { packages = $0; brewLoaded = true }
    }

    func changePackage(_ package: BrewPackage, uninstall: Bool) async {
        guard !busy, let executable = Homebrew.executable else { return }
        await perform("\(uninstall ? "Uninstalling" : "Updating") \(package.name)…") {
            _ = try ToolCommand.run(executable, Homebrew.arguments(uninstall ? "uninstall" : "upgrade", package: package))
            return true
        } apply: { _ in message = "\(package.name) \(uninstall ? "uninstalled" : "updated")." }
        let operationError = failure
        let operationMessage = message
        await loadBrew()
        if let operationError { failure = operationError }
        else if failure == nil { message = operationMessage }
    }

    func discover() async {
        guard !busy else { return }
        await perform("Finding indexed repositories…") { try GitWorktrees.indexedRepositories() } apply: {
            repositories = Array(Set(repositories + $0)).sorted()
        }
        if repository.isEmpty { repository = repositories.first ?? "" }
        if !repository.isEmpty { await loadWorktrees(repository) }
        worktreesLoaded = true
    }

    func loadWorktrees(_ path: String) async {
        guard !busy else { return }
        repository = path
        worktrees = []; blockers = [:]
        await perform("Inspecting worktrees…") {
            let trees = try GitWorktrees.list(path)
            var reasons: [String: String] = [:]
            for tree in trees {
                do { reasons[tree.path] = try GitWorktrees.check(tree) }
                catch { reasons[tree.path] = "Couldn't verify this worktree: \(error.localizedDescription)" }
            }
            return (trees, reasons)
        } apply: {
            worktrees = $0.0; blockers = $0.1
            repository = worktrees.first?.path ?? path
            if !repositories.contains(repository) { repositories.append(repository); repositories.sort() }
            UserDefaults.standard.set(repositories, forKey: "worktreeRepositories")
        }
    }

    func removeWorktree(_ tree: GitWorktree) async {
        guard !busy else { return }
        let path = repository
        await perform("Removing \(tree.label)…") { try GitWorktrees.remove(tree, repository: path) } apply: { _ in
            message = "Worktree removed. Its branch and commits were kept."
        }
        let operationError = failure
        let operationMessage = message
        await loadWorktrees(path)
        if let operationError { failure = operationError }
        else if failure == nil { message = operationMessage }
    }

    private func perform<T: Sendable>(_ title: String, operation: @escaping @Sendable () throws -> T,
                                     apply: (T) -> Void) async {
        busy = true; activity = title; failure = nil; message = nil
        defer { busy = false; activity = "" }
        do { apply(try await Task.detached(priority: .userInitiated, operation: operation).value) }
        catch { failure = error.localizedDescription }
    }
}
