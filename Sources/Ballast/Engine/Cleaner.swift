import Foundation

/// Something on the Cleanup List.
struct PlanItem: Identifiable, Hashable, Sendable {
    let name: String
    /// Display path, e.g. "/Users/me/projects/app/node_modules".
    let path: String
    let bytes: Int64
    let action: CleanAction
    let isDirectory: Bool
    var safety: Safety
    /// Caution items are only cleaned once the user ticks them.
    var included: Bool

    var id: String { path }

    /// Will be cleaned when the user presses Clean.
    var isReady: Bool {
        switch safety.level {
        case .safe: true
        case .caution: included
        case .quitFirst, .blocked: false
        }
    }
}

struct CleanOutcome: Identifiable, Sendable {
    let item: PlanItem
    let error: String?
    /// Something worth knowing that isn't a failure ("skipped Chrome's cache").
    var note: String?
    var id: String { item.id }
    var succeeded: Bool { error == nil }
}

/// Performs the list. The list's safety levels are the confirmation; the
/// checks here are the last line of defence.
enum Cleaner {
    /// Cheap structural test used to decide where ⊕ buttons appear: inside
    /// home, and not one of home's own top-level folders.
    static func canRemove(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/"), !path.contains("/../") else { return false }
        let parts = path.dropFirst(home.count + 1).split(separator: "/")
        guard parts.count >= 2 else { return false }
        if parts[0] == "Library" && parts.count < 3 { return false }
        return true
    }

    static func clean(
        _ items: [PlanItem],
        permanently: Bool,
        apps: AppInventory,
        cancel: CancelFlag,
        progress: (Int, PlanItem) -> Void
    ) -> [CleanOutcome] {
        var outcomes: [CleanOutcome] = []
        for (index, item) in items.enumerated() where item.isReady {
            if cancel.isSet { break }
            progress(index, item)
            do {
                let note = try clean(item, permanently: permanently, apps: apps)
                outcomes.append(CleanOutcome(item: item, error: nil, note: note))
            } catch {
                outcomes.append(CleanOutcome(item: item, error: error.localizedDescription))
            }
        }
        return outcomes
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Returns an optional note for the result screen.
    private static func clean(_ item: PlanItem, permanently: Bool, apps: AppInventory) throws -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        // Ballast only deletes files itself inside your home folder. Commands
        // (brew cleanup, go clean…) let the owning tool clean its own files,
        // wherever they live, so they aren't bound by this check.
        switch item.action {
        case .remove, .contents:
            guard item.path.hasPrefix(home + "/"), !item.path.contains("/../") else {
                throw Failure(message: "Ballast won't touch \(item.path)")
            }
        case .emptyTrash, .command:
            break
        }

        func remove(_ url: URL, forever: Bool) throws {
            if forever {
                try fm.removeItem(at: url)
            } else {
                try fm.trashItem(at: url, resultingItemURL: nil)
            }
        }

        switch item.action {
        case .remove:
            // Re-check: an app may have been opened since the item was added.
            let now = SafetyCheck.assess(item.path, isDirectory: item.isDirectory, apps: apps)
            if now.level == .blocked || now.level == .quitFirst {
                throw Failure(message: now.reason)
            }
            try remove(URL(fileURLWithPath: item.path), forever: permanently)
            return nil

        case .contents:
            // Empty the folder, but leave alone whatever belongs to an app
            // that's running right now: pulling a cache out from under a
            // running app is how apps break.
            let url = URL(fileURLWithPath: item.path)
            var skipped: [String] = []
            var failed: [String] = []
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                let nested = (try? fm.contentsOfDirectory(atPath: child.path).first) ?? nil
                if let app = apps.runningOwner(of: [child.lastPathComponent] + (nested.map { [$0] } ?? [])) {
                    if !skipped.contains(app.name) { skipped.append(app.name) }
                    continue
                }
                do { try remove(child, forever: permanently) } catch { failed.append(child.lastPathComponent) }
            }
            if !failed.isEmpty {
                throw Failure(message: "\(failed.count) items couldn't be removed (\(failed.prefix(3).joined(separator: ", ")))")
            }
            return skipped.isEmpty ? nil : "Kept caches of open apps: \(skipped.joined(separator: ", "))"

        case .emptyTrash:
            let trash = URL(fileURLWithPath: home + "/.Trash")
            var failed = 0
            for child in try fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) {
                do { try fm.removeItem(at: child) } catch { failed += 1 }
            }
            if failed > 0 { throw Failure(message: "\(failed) items in the Trash couldn't be removed") }
            return nil

        case .command(let command):
            try run(command)
            return nil
        }
    }

    /// Runs a cleanup command in an interactive login shell so it sees the
    /// same PATH (Homebrew, Go, Bun…) as the user's terminal.
    private static func run(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", command]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // Interactive shells print terminal escape sequences and plugin
            // chatter; keep only plain lines for the error message.
            let lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.contains("\u{1B}") && !$0.contains("\u{07}") && !$0.contains("zoxide") }
            throw Failure(message: "`\(command)` failed: \(lines.last ?? "exit status \(process.terminationStatus)")")
        }
    }

    /// Bytes on disk for a file or folder, for items dropped in from Finder.
    static func measure(_ path: String) -> (bytes: Int64, isDirectory: Bool) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return (0, false) }
        guard st.st_mode & S_IFMT == S_IFDIR else { return (Int64(st.st_blocks) * 512, false) }
        var total: Int64 = 0
        try? Walker.walk(path) { node in if node.local == 0 { total = node.total } }
        return (total, true)
    }
}
