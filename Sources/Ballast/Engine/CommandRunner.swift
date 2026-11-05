import Darwin
import Foundation
import os

/// What a finished command produced. Output is kept as bytes; decoding is
/// lossy, so odd bytes (a filename in `git status -z`) never fail a read.
struct CommandResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    /// Output beyond the runner's limit was dropped.
    var truncated = false

    var succeeded: Bool { status == 0 }
    var output: String { String(decoding: stdout, as: UTF8.self) }
    var errors: String { String(decoding: stderr, as: UTF8.self) }

    /// The end of stderr (or of stdout when stderr is empty), trimmed: the
    /// part of a failing tool's output that usually says what went wrong.
    func tail(_ limit: Int = 500) -> String {
        let source = stderr.contains(where: { !isSpace($0) }) ? stderr : stdout
        return String(decoding: source.suffix(limit), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }
}

/// Why a command didn't produce a result.
struct CommandError: LocalizedError, Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        case launch(String)
        case timedOut(seconds: Int)
        case cancelled
    }

    let tool: String
    let reason: Reason

    var errorDescription: String? {
        switch reason {
        case .launch(let detail): "Couldn't start \(tool): \(detail)"
        case .timedOut(let seconds): "\(tool) didn't finish within \(Self.duration(seconds)) and was stopped."
        case .cancelled: "\(tool) was cancelled."
        }
    }

    private static func duration(_ seconds: Int) -> String {
        seconds < 60 ? "\(max(seconds, 1)) second\(seconds == 1 ? "" : "s")" : "\(seconds / 60) minute\(seconds / 60 == 1 ? "" : "s")"
    }
}

/// The environment external tools run with. A GUI app launched from Finder
/// gets launchd's bare PATH, so the user's login-shell PATH is read once
/// and reused; Homebrew is told not to update, nag or wait for input.
enum CommandEnvironment {
    static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private static let cached = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The login shell's PATH merged with the usual tool folders. The first
    /// call may take up to 3 s; later calls return the cached value.
    static func path() -> String {
        if let path = cached.withLock({ $0 }) { return path }
        let shell = try? CommandRunner.runSync("/bin/zsh", ["-lc", #"printf %s "$PATH""#], timeout: .seconds(3),
                                               environment: bootstrap, outputLimit: 64 << 10)
        return store(shell?.succeeded == true ? shell?.output : nil)
    }

    /// Same as `path()`, without blocking a thread while the shell starts.
    static func resolvedPath() async -> String {
        if let path = cached.withLock({ $0 }) { return path }
        let shell = try? await CommandRunner.run("/bin/zsh", ["-lc", #"printf %s "$PATH""#], timeout: .seconds(3),
                                                 environment: bootstrap, outputLimit: 64 << 10)
        return store(shell?.succeeded == true ? shell?.output : nil)
    }

    private static func store(_ shellOutput: String?) -> String {
        let path = merge(shellOutput)
        return cached.withLock { current in
            if let current { return current }
            current = path
            return path
        }
    }

    /// Absolute folders from the shell's PATH (profile chatter before it is
    /// ignored), then any fallback folder it was missing.
    static func merge(_ shellOutput: String?) -> String {
        let line = shellOutput?.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        var folders: [String] = []
        for folder in line.split(separator: ":").map(String.init) + fallbackPath.split(separator: ":").map(String.init)
        where folder.hasPrefix("/") && !folders.contains(folder) {
            folders.append(folder)
        }
        return folders.joined(separator: ":")
    }

    /// What the login shell itself starts with: just enough to find its profile.
    private static var bootstrap: [String: String] {
        let current = ProcessInfo.processInfo.environment
        var environment = ["PATH": fallbackPath, "HOME": NSHomeDirectory()]
        for key in ["USER", "LOGNAME", "TMPDIR", "LANG"] { environment[key] = current[key] }
        return environment
    }

    /// For developer tools: brew, git, go, npm…
    static func tools(path: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        environment["NONINTERACTIVE"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // A GUI launched from a developer shell must not inherit another repo.
        for key in Array(environment.keys) where key.hasPrefix("GIT_") && key != "GIT_TERMINAL_PROMPT" {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    /// For macOS's own diagnostic tools: fixed locale, so their output can be matched.
    static var diagnostics: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
         "HOME": NSHomeDirectory(), "LC_ALL": "C", "LANG": "C",
         "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"]
    }

    /// Where `tool` lives on `path`, or nil. Names with a slash are checked as given.
    static func locate(_ tool: String, path: String) -> String? {
        let fm = FileManager.default
        if tool.contains("/") { return fm.isExecutableFile(atPath: tool) ? tool : nil }
        for folder in path.split(separator: ":") {
            let candidate = String(folder) + "/" + tool
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// Runs external tools without a shell: arguments are passed as given,
/// stdin is closed (password prompts fail instead of hanging), stdout and
/// stderr are drained as they arrive (a chatty tool can't fill a pipe and
/// deadlock), every run has a deadline, and a stopped run takes the tool's
/// child processes with it (SIGTERM, then SIGKILL).
enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String] = [], timeout: Duration = .seconds(30),
                    environment: [String: String]? = nil, directory: String? = nil,
                    quality: QualityOfService = .userInitiated, outputLimit: Int = 64 << 20) async throws -> CommandResult {
        try Task.checkCancellation()
        var resolved = environment ?? [:]
        if environment == nil { resolved = CommandEnvironment.tools(path: await CommandEnvironment.resolvedPath()) }
        let environment = resolved
        let execution = Execution(executable: executable, arguments: arguments, environment: environment, directory: directory,
                                  timeout: timeout, quality: quality, limit: outputLimit)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                execution.start { continuation.resume(returning: $0) }
            }
        } onCancel: {
            execution.stop(.cancelled)
        }
        switch result {
        case .success(let output): return output
        case .failure(let error) where error.reason == .cancelled: throw CancellationError()
        case .failure(let error): throw error
        }
    }

    /// Blocks the calling thread; for synchronous engine code (the Cleaner,
    /// System Data). Setting `cancel` stops the tool within a fraction of a second.
    static func runSync(_ executable: String, _ arguments: [String] = [], timeout: Duration = .seconds(30),
                        environment: [String: String]? = nil, directory: String? = nil,
                        quality: QualityOfService = .userInitiated, outputLimit: Int = 64 << 20,
                        cancel: CancelFlag? = nil) throws -> CommandResult {
        let environment = environment ?? CommandEnvironment.tools(path: CommandEnvironment.path())
        let execution = Execution(executable: executable, arguments: arguments, environment: environment, directory: directory,
                                  timeout: timeout, quality: quality, limit: outputLimit)
        let box = OSAllocatedUnfairLock<Result<CommandResult, CommandError>?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        execution.start { result in
            box.withLock { $0 = result }
            done.signal()
        }
        while done.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
            if cancel?.isSet == true { execution.stop(.cancelled) }
        }
        guard let result = box.withLock({ $0 }) else { throw CommandError(tool: execution.tool, reason: .cancelled) }
        return try result.get()
    }
}

/// One run of one tool. Thread-safe: callbacks arrive from Foundation's
/// and GCD's threads; all mutable state sits behind the lock.
private final class Execution: @unchecked Sendable {
    enum Stop { case cancelled, timedOut }

    private struct State {
        var stdout = Data()
        var stderr = Data()
        var truncated = false
        var stdoutOpen = true
        var stderrOpen = true
        var launched = false
        var exited = false
        var completed = false
        var pid: pid_t = 0
        var stop: Stop?
        var done: (@Sendable (Result<CommandResult, CommandError>) -> Void)?
    }

    let tool: String
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let pipes = DispatchGroup()
    /// Serial, so it's overcommit: its deadline and SIGKILL fire even when
    /// every pool thread is blocked in `runSync` (Swift Testing, or engine
    /// work on the cooperative pool). A concurrent queue could wait forever
    /// for a worker thread there. Its work items are tiny.
    private let queue = DispatchQueue(label: "ballast.command", qos: .userInitiated)
    private let timeout: Duration
    private let limit: Int

    init(executable: String, arguments: [String], environment: [String: String], directory: String?,
         timeout: Duration, quality: QualityOfService, limit: Int) {
        tool = (executable as NSString).lastPathComponent
        self.timeout = timeout
        self.limit = limit
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.qualityOfService = quality
    }

    /// Launches the tool. `done` is called exactly once, on a background thread.
    func start(_ done: @escaping @Sendable (Result<CommandResult, CommandError>) -> Void) {
        let launch = state.withLock { state -> Bool in
            state.done = done
            guard state.stop == nil else { return false }
            state.launched = true
            return true
        }
        guard launch else { return finish(.failure(CommandError(tool: tool, reason: .cancelled))) }

        pipes.enter()
        pipes.enter()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] handle in drain(handle, error: false) }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] handle in drain(handle, error: true) }
        process.terminationHandler = { [self] _ in exited() }
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return finish(.failure(CommandError(tool: tool, reason: .launch(error.localizedDescription))))
        }
        let stopRequested = state.withLock { state -> Bool in
            state.pid = process.processIdentifier
            return state.stop != nil
        }
        if stopRequested { terminate() }
        let components = timeout.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        // Weak: a finished run is released without waiting for its deadline.
        queue.asyncAfter(deadline: .now() + max(seconds, 0)) { [weak self] in self?.stop(.timedOut) }
    }

    /// Stops a running tool: SIGTERM to its process group, SIGKILL half a
    /// second later if it's still there. A stop before launch prevents it.
    func stop(_ reason: Stop) {
        let running = state.withLock { state -> Bool in
            guard !state.exited, !state.completed else { return false }
            if state.stop == nil { state.stop = reason }
            return state.launched && state.pid > 0
        }
        if running { terminate() }
    }

    private func terminate() {
        signal(SIGTERM)
        queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [self] in signal(SIGKILL) }
    }

    private func signal(_ signal: Int32) {
        state.withLock { state in
            // Only while the process is unreaped, so its pid can't have been reused.
            guard !state.exited, state.pid > 0 else { return }
            // Process puts each child in its own process group: this reaches
            // the tools it started too (brew's git and curl, a shell's command).
            killpg(state.pid, signal)
            kill(state.pid, signal)
        }
    }

    private func drain(_ handle: FileHandle, error: Bool) {
        let data = handle.availableData
        let closed = state.withLock { state -> Bool in
            if data.isEmpty {
                guard error ? state.stderrOpen : state.stdoutOpen else { return false }
                if error { state.stderrOpen = false } else { state.stdoutOpen = false }
                return true
            }
            let room = limit - state.stdout.count - state.stderr.count
            if room < data.count { state.truncated = true }
            if room > 0 {
                if error { state.stderr.append(data.prefix(room)) } else { state.stdout.append(data.prefix(room)) }
            }
            return false
        }
        if closed {
            handle.readabilityHandler = nil
            pipes.leave()
        }
    }

    private func exited() {
        state.withLock { $0.exited = true }
        // Usually both pipes are at end of file by now. A grandchild that
        // kept them open mustn't hold up the result: wait a second at most.
        pipes.notify(queue: queue) { [self] in complete() }
        queue.asyncAfter(deadline: .now() + .seconds(1)) { [self] in complete() }
    }

    private func complete() {
        let snapshot = state.withLock { state -> State? in
            guard !state.completed else { return nil }
            state.completed = true
            return state
        }
        guard let snapshot else { return }
        process.terminationHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        switch snapshot.stop {
        case .cancelled: finish(.failure(CommandError(tool: tool, reason: .cancelled)))
        case .timedOut:
            finish(.failure(CommandError(tool: tool, reason: .timedOut(seconds: Int(timeout.components.seconds)))))
        case nil:
            finish(.success(CommandResult(status: process.terminationStatus, stdout: snapshot.stdout,
                                          stderr: snapshot.stderr, truncated: snapshot.truncated)))
        }
    }

    private func finish(_ result: Result<CommandResult, CommandError>) {
        let done = state.withLock { state in
            defer { state.done = nil }
            state.completed = true
            return state.done
        }
        done?(result)
    }
}
