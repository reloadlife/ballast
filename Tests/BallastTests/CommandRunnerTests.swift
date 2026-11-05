import Foundation
import Testing
@testable import Ballast

@Suite struct CommandRunnerTests {
    /// Plain environment, so no test waits on the login shell's PATH.
    let environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]

    /// A fake tool that hangs, like brew waiting on the network.
    private func sleeper() throws -> (folder: URL, tool: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ballast-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = folder.appendingPathComponent("fake-tool")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (folder, tool.path)
    }

    @Test func outputAndExitStatusComeBackWithoutThrowing() throws {
        let ok = try CommandRunner.runSync("/bin/echo", ["hello"], environment: environment)
        #expect(ok.succeeded)
        #expect(ok.output == "hello\n")

        let failed = try CommandRunner.runSync("/bin/sh", ["-c", "echo partial; echo 'Error: broken' >&2; exit 3"], environment: environment)
        #expect(failed.status == 3)
        #expect(!failed.succeeded)
        #expect(failed.tail() == "Error: broken")
    }

    @Test func aMissingToolIsALaunchError() {
        #expect {
            try CommandRunner.runSync("/nonexistent/ballast-tool", environment: environment)
        } throws: { error in
            guard let error = error as? CommandError, case .launch = error.reason else { return false }
            return error.tool == "ballast-tool"
        }
    }

    @Test func aHangingToolIsStoppedAtItsDeadline() throws {
        let (folder, tool) = try sleeper()
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = ContinuousClock.now
        #expect {
            try CommandRunner.runSync(tool, timeout: .milliseconds(300), environment: environment)
        } throws: { error in
            guard let error = error as? CommandError, case .timedOut = error.reason else { return false }
            return true
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func asyncRunsTimeOutToo() async throws {
        let (folder, tool) = try sleeper()
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = ContinuousClock.now
        await #expect {
            try await CommandRunner.run(tool, timeout: .milliseconds(300), environment: environment)
        } throws: { error in
            guard let error = error as? CommandError, case .timedOut = error.reason else { return false }
            return true
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancellingTheTaskStopsTheTool() async throws {
        let (folder, tool) = try sleeper()
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = environment
        let task = Task { try await CommandRunner.run(tool, timeout: .seconds(30), environment: environment) }
        try await Task.sleep(for: .milliseconds(150))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func aToolThatIgnoresSIGTERMIsKilled() throws {
        let start = ContinuousClock.now
        #expect(throws: CommandError.self) {
            try CommandRunner.runSync("/bin/sh", ["-c", "trap '' TERM; /bin/sleep 30"], timeout: .milliseconds(200), environment: environment)
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func theCancelFlagStopsASynchronousRun() throws {
        let (folder, tool) = try sleeper()
        defer { try? FileManager.default.removeItem(at: folder) }
        let flag = CancelFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { flag.set() }
        let start = ContinuousClock.now
        #expect {
            try CommandRunner.runSync(tool, timeout: .seconds(30), environment: environment, cancel: flag)
        } throws: { error in
            (error as? CommandError)?.reason == .cancelled
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func outputPastTheLimitIsDroppedNotDeadlocked() throws {
        let result = try CommandRunner.runSync("/bin/sh", ["-c", "head -c 200000 /dev/zero"], timeout: .seconds(10),
                                               environment: environment, outputLimit: 1000)
        #expect(result.succeeded)
        #expect(result.truncated)
        #expect(result.stdout.count <= 1000)
    }

    /// A failed launch used to keep its Process and four pipe descriptors
    /// alive for good (a handler cycle and an unbalanced group).
    @Test func failedLaunchesReleaseTheirPipes() {
        func descriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
        let environment = environment
        autoreleasepool { _ = try? CommandRunner.runSync("/nonexistent/ballast-tool", environment: environment) }
        let before = descriptors()
        for _ in 0..<50 {
            autoreleasepool { _ = try? CommandRunner.runSync("/nonexistent/ballast-tool", environment: environment) }
        }
        // 200 leaked before the fix; leave room for other tests running alongside.
        #expect(descriptors() - before < 60)
    }

    @Test func userToolFoldersComeAfterTheShellsOwnPath() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ballast-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".bun/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".nvm/versions/node/v9.0.0/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".nvm/versions/node/v22.1.0/bin"), withIntermediateDirectories: true)
        let extras = CommandEnvironment.userToolFolders(home: home.path)
        #expect(extras == [home.path + "/.bun/bin", home.path + "/.nvm/versions/node/v22.1.0/bin"])
        let merged = CommandEnvironment.merge("/usr/bin", extras: extras).split(separator: ":").map(String.init)
        #expect(merged.first == "/usr/bin")
        #expect(merged.last == home.path + "/.nvm/versions/node/v22.1.0/bin")
    }

    @Test func theShellPathIsMergedWithTheUsualFolders() {
        let merged = CommandEnvironment.merge("Welcome to zsh\n/Users/me/.cargo/bin:relative/bin:/usr/bin")
        let folders = merged.split(separator: ":").map(String.init)
        #expect(folders.first == "/Users/me/.cargo/bin")
        #expect(!folders.contains("relative/bin"))
        #expect(folders.filter { $0 == "/usr/bin" }.count == 1)
        #expect(folders.contains("/opt/homebrew/bin"))
        #expect(CommandEnvironment.merge(nil) == CommandEnvironment.fallbackPath)
    }

    @Test func toolEnvironmentKeepsHomebrewQuietAndDropsOtherRepositories() {
        let environment = CommandEnvironment.tools(path: "/usr/bin")
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(!environment.keys.contains { $0.hasPrefix("GIT_") && $0 != "GIT_TERMINAL_PROMPT" })
        #expect(CommandEnvironment.locate("sh", path: "/nonexistent:/bin") == "/bin/sh")
        #expect(CommandEnvironment.locate("ballast-no-such-tool", path: "/bin") == nil)
    }
}

@Suite struct ToolEnvironmentTests {
    @Test func brewNeverAutoremovesBehindTheUsersBack() {
        #expect(CommandEnvironment.tools(path: "/usr/bin")["HOMEBREW_NO_AUTOREMOVE"] == "1")
        #expect(CommandEnvironment.diagnostics["HOMEBREW_NO_AUTOREMOVE"] == "1")
    }
}
