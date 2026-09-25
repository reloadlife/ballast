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

    struct Failed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Entry point of the root process: `Ballast --admin-scan <output> <paths…>`.
    static func main(output: String, paths: [String]) -> Int32 {
        var results: [AdminResult] = []
        for path in paths {
            var nodes: [WalkNode] = []
            try? Walker.walk(path) { nodes.append($0) }
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

    /// Blocks until the privileged scan finishes. Throws CancellationError if
    /// the user dismisses the password prompt.
    static func run(paths: [String]) throws -> [AdminResult] {
        guard let executable = Bundle.main.executablePath else { throw Failed(message: "Can't locate Ballast binary") }
        let output = FileManager.default.temporaryDirectory.appending(path: "ballast-admin-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: output) }

        let command = ([executable, flag, output.path] + paths).map(shellQuoted).joined(separator: " ")
        let script = "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
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
