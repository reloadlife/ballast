import Darwin
import Foundation

struct AdminResult: Codable, Sendable {
    let path: String
    let nodes: [WalkNode]
}

/// Measures folders the user can't read (EACCES) by running this same binary
/// as root. The standard macOS password prompt comes from `osascript`.
///
/// Root does not get past privacy protection (EPERM): that needs Full Disk
/// Access, and some system folders stay closed even then.
enum AdminScan {
    static let flag = "--admin-scan"
    /// An excluded folder, passed among the paths: `--skip=<volume path>`.
    static let skipPrefix = "--skip="
    /// A file that exists while the app still waits: `--alive=<path>`. The
    /// root process stops walking once it's gone (the user cancelled).
    static let alivePrefix = "--alive="

    struct Failed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// What the root process was asked to do, from its arguments after the
    /// output path.
    struct Request: Equatable {
        var paths: [String] = []
        var skip: [String] = []
        var alive: String?

        init(arguments: [String]) {
            for argument in arguments {
                if argument.hasPrefix(AdminScan.skipPrefix) {
                    skip.append(String(argument.dropFirst(AdminScan.skipPrefix.count)))
                } else if argument.hasPrefix(AdminScan.alivePrefix) {
                    alive = String(argument.dropFirst(AdminScan.alivePrefix.count))
                } else {
                    paths.append(argument)
                }
            }
        }

        var excluded: Exclusions { Exclusions(fingerprint: skip.joined(separator: "\n")) }
    }

    /// Entry point of the root process: `Ballast --admin-scan <output> <arguments…>`,
    /// the arguments being folders to measure plus `--skip=` and `--alive=` entries.
    static func main(output: String, paths arguments: [String]) -> Int32 {
        let request = Request(arguments: arguments)
        let excluded = request.excluded
        let cancelled = { request.alive.map { access($0, F_OK) != 0 } ?? false }
        var results: [AdminResult] = []
        for path in request.paths {
            if cancelled() { return 2 }
            var nodes: [WalkNode] = []
            do {
                try Walker.walk(path, skip: excluded, cancelled: cancelled) { nodes.append($0) }
            } catch is CancellationError {
                return 2
            } catch {
                continue
            }
            results.append(AdminResult(path: path, nodes: nodes))
        }
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(results).write(to: URL(fileURLWithPath: output))
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }

    /// The exclusions the startup disk's index was built with, which graft
    /// keeps to.
    static func indexExclusions(_ index: String = Paths.index) -> Exclusions {
        guard FileManager.default.fileExists(atPath: index),
              let db = try? IndexDB(path: index, mode: .read),
              let fingerprint = try? db.meta("excluded") else { return Exclusions([]) }
        return Exclusions(fingerprint: fingerprint)
    }

    /// Blocks until the privileged scan finishes. Throws CancellationError if
    /// the user dismisses the password prompt, or once `cancelled` returns
    /// true: the prompt or the walk is stopped. `excluded` defaults to the
    /// startup index's own, so folders excluded in Settings stay out.
    static func run(
        paths: [String], excluded: Exclusions? = nil, cancelled: @escaping () -> Bool = { false }
    ) throws -> [AdminResult] {
        guard let executable = Bundle.main.executablePath else { throw Failed(message: "Can't locate Ballast binary") }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appending(path: "ballast-admin-\(UUID().uuidString)")
        let output = base.appendingPathExtension("plist")
        let alive = base.appendingPathExtension("alive")
        let errors = base.appendingPathExtension("err")
        guard fm.createFile(atPath: alive.path, contents: nil), fm.createFile(atPath: errors.path, contents: nil) else {
            throw Failed(message: "Can't prepare the admin scan")
        }
        // Removing the marker also tells a root process still walking to stop.
        defer {
            for url in [alive, errors, output] { try? fm.removeItem(at: url) }
        }

        let skip = (excluded ?? indexExclusions()).paths.sorted().map { skipPrefix + $0 }
        let arguments = [executable, flag, output.path] + paths + skip + [alivePrefix + alive.path]
        let command = arguments.map(shellQuoted).joined(separator: " ")
        let script = "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        // A file, not a pipe: a pipe nobody reads fills up and blocks the child.
        let errorHandle = try FileHandle(forWritingTo: errors)
        defer { try? errorHandle.close() }
        process.standardError = errorHandle
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        while process.isRunning {
            if cancelled() {
                try? fm.removeItem(at: alive)
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            usleep(100_000)
        }

        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            if message.contains("-128") { throw CancellationError() }  // "User canceled."
            throw Failed(message: "Admin scan failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return try PropertyListDecoder().decode([AdminResult].self, from: Data(contentsOf: output))
    }

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
