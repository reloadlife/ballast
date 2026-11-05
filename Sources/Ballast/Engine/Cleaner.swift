import Foundation
import os

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

extension PlanItem {
    /// A list item with its safety verdict. Shared by the app and the
    /// command-line status snapshot, so both judge items the same way.
    static func assess(
        name: String, path: String, bytes: Int64, action: CleanAction, isDirectory: Bool,
        apps: AppInventory, protected: [String]
    ) -> PlanItem {
        let safety: Safety
        switch action {
        case .remove:
            safety = SafetyCheck.assess(path, isDirectory: isDirectory, apps: apps, protected: protected)
        case .contents, .command:
            // Emptying a folder, or a tool's own cleanup, can't spare a
            // protected folder it's inside of. Protected folders inside one
            // being emptied are kept by the Cleaner.
            if protected.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                safety = .blocked("You protected this folder in Settings.")
            } else if case .command(let command) = action {
                safety = SafetyCheck.command(command)
            } else {
                safety = .safe("Empties the folder. Anything belonging to an open app is kept.")
            }
        case .emptyTrash:
            // Like Finder's, it also empties the Trash on connected drives: say so.
            safety = .safe(Drives.trashes().isEmpty ? "Permanently deletes what's in the Trash."
                : "Permanently deletes what's in the Trash, including the Trash on connected drives.")
        case .uninstall(let bundleID, let data):
            safety = SafetyCheck.uninstall(path, bundleID: bundleID, data: data, apps: apps, protected: protected)
        }
        return PlanItem(name: name, path: path, bytes: bytes, action: action, isDirectory: isDirectory,
                        safety: safety, included: safety.level == .safe)
    }

    /// Item for a suggestion, if it's something Ballast can clean.
    static func assess(_ result: ScanResult, apps: AppInventory, protected: [String]) -> PlanItem? {
        guard let action = result.target.action else { return nil }
        return assess(name: result.target.name, path: result.target.path, bytes: result.bytes,
                      action: action, isDirectory: true, apps: apps, protected: protected)
    }
}

struct CleanOutcome: Identifiable, Sendable {
    let item: PlanItem
    let error: String?
    /// Something worth knowing that isn't a failure ("skipped Chrome's cache").
    var note: String?
    /// What went to the Trash, and where, so it can be put back.
    var moves: [TrashMove] = []
    var id: String { item.id }
    var succeeded: Bool { error == nil }
}

/// Performs the list. The list's safety levels are the confirmation; the
/// checks here are the last line of defence.
enum Cleaner {
    /// Use the same location policy as review and execution. Outside-home
    /// items must remain discoverable when they are eligible for cleanup.
    static func canRemove(_ path: String) -> Bool {
        SafetyCheck.assess(path, isDirectory: true, apps: AppInventory(running: [], installed: []), protected: []).level != .blocked
    }

    /// Permanent deletes at least this big are moved aside at once and
    /// deleted in the background.
    static let stagingThreshold: Int64 = 256 << 20
    /// Same volume as the home folder, so moving into it is a rename.
    static let stagingRoot = Paths.supportDir + "/Deleting"
    /// A tool's cleanup command gets this long before it's stopped.
    static let commandTimeout: Duration = .seconds(600)

    static func clean(
        _ items: [PlanItem],
        permanently: Bool,
        apps: AppInventory,
        protected: [String] = Preferences.current.protectedFolders,
        kept: [String] = Catalog.keptWhenEmptying,
        locations: AppLocations = .standard,
        stagingThreshold: Int64 = Cleaner.stagingThreshold,
        stagingRoot: String = Cleaner.stagingRoot,
        cancel: CancelFlag,
        progress: (Int, PlanItem) -> Void
    ) -> [CleanOutcome] {
        let run = Run(cancel: cancel, purge: Purge(root: stagingRoot), stagingThreshold: permanently ? stagingThreshold : .max)
        // What a crash or quit left behind last time.
        if permanently { run.purge.sweep() }
        var outcomes: [CleanOutcome] = []
        for (index, item) in items.enumerated() where item.isReady {
            if cancel.isSet { break }
            progress(index, item)
            var moves: [TrashMove] = []
            do {
                let note = try clean(item, permanently: permanently, apps: apps, protected: protected, kept: kept,
                                     locations: locations, run: run, moves: &moves)
                outcomes.append(CleanOutcome(item: item, error: nil, note: note, moves: moves))
            } catch {
                // Whatever did reach the Trash can still be put back.
                outcomes.append(CleanOutcome(item: item, error: error.localizedDescription, moves: moves))
            }
        }
        // Usually the background deletes finish in moments; the space they
        // free is then counted in this clean's result.
        let finished = run.purge.wait(seconds: 10)
        let failed = run.purge.failedItems
        return outcomes.map { outcome in
            guard run.purge.staged(outcome.item.id) else { return outcome }
            var outcome = outcome
            let extra = !finished ? "Still freeing space in the background"
                : failed.contains(outcome.item.id) ? "Some files couldn't be deleted; Ballast tries again next time it cleans" : nil
            if let extra { outcome.note = [outcome.note, extra].compactMap { $0 }.joined(separator: ". ") }
            return outcome
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// State shared by every item of one clean.
    private final class Run {
        let cancel: CancelFlag
        let purge: Purge
        let stagingThreshold: Int64
        private var images: [String: String]?

        init(cancel: CancelFlag, purge: Purge, stagingThreshold: Int64) {
            self.cancel = cancel
            self.purge = purge
            self.stagingThreshold = stagingThreshold
        }

        /// Mounted disk images, read at most once per clean; nil when
        /// hdiutil didn't answer, so a disk image is never assumed unmounted.
        var mountedImages: [String: String]? {
            if let images { return images }
            if checkedImages { return nil }
            checkedImages = true
            images = Installers.mountedImages()
            return images
        }
        private var checkedImages = false
    }

    /// Big permanent deletes: renamed into a hidden folder on the same
    /// volume (instant), then deleted at utility priority.
    final class Purge: Sendable {
        let root: String
        private let group = DispatchGroup()
        private let state = OSAllocatedUnfairLock(initialState: (staged: Set<String>(), failed: Set<String>()))
        private static let queue = DispatchQueue(label: "ballast.purge", qos: .utility)
        /// Staged names whose background delete hasn't finished, across runs.
        private static let inFlight = OSAllocatedUnfairLock(initialState: Set<String>())

        init(root: String) { self.root = root }

        /// False when the item can't be moved aside (another volume, no
        /// permission); the caller then deletes it directly.
        func stage(_ url: URL, item: String) -> Bool {
            let fm = FileManager.default
            guard (try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)) != nil else { return false }
            var source = stat(), destination = stat()
            guard lstat(url.path, &source) == 0, lstat(root, &destination) == 0, source.st_dev == destination.st_dev else { return false }
            let name = UUID().uuidString
            let target = root + "/" + name
            Self.inFlight.withLock { _ = $0.insert(name) }
            guard rename(url.path, target) == 0 else {
                Self.inFlight.withLock { _ = $0.remove(name) }
                return false
            }
            state.withLock { _ = $0.staged.insert(item) }
            group.enter()
            Self.queue.async { [self] in
                if (try? FileManager.default.removeItem(atPath: target)) == nil {
                    state.withLock { _ = $0.failed.insert(item) }
                }
                Self.inFlight.withLock { _ = $0.remove(name) }
                group.leave()
            }
            return true
        }

        /// Deletes what an earlier run didn't get to. Entries another clean
        /// running now (Auto Clean beside a manual clean) is deleting are its own.
        func sweep() {
            let busy = Self.inFlight.withLock { $0 }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where !busy.contains(name) {
                let path = root + "/" + name
                group.enter()
                Self.queue.async { [group] in
                    try? FileManager.default.removeItem(atPath: path)
                    group.leave()
                }
            }
        }

        func wait(seconds: Double) -> Bool { group.wait(timeout: .now() + seconds) == .success }
        func staged(_ item: String) -> Bool { state.withLock { $0.staged.contains(item) } }
        var failedItems: Set<String> { state.withLock { $0.failed } }
    }

    /// EPERM, EACCES, EROFS: macOS (SIP, privacy protection) or the file's
    /// permissions don't allow it. Not something trying again fixes.
    static func isPermissionDenied(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(error.code) {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, [EPERM, EACCES, EROFS].contains(Int32(error.code)) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionDenied(underlying) }
        return false
    }

    /// Returns an optional note for the result screen.
    private static func clean(
        _ item: PlanItem, permanently: Bool, apps: AppInventory, protected: [String], kept: [String],
        locations: AppLocations, run: Run, moves: inout [TrashMove]
    ) throws -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        func remove(_ url: URL, forever: Bool, big: Bool = false) throws {
            if forever {
                if big, run.purge.stage(url, item: item.id) { return }
                try fm.removeItem(at: url)
            } else {
                var trashed: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &trashed)
                if let trashed = trashed as URL? { moves.append(TrashMove(from: url.path, to: trashed.path)) }
            }
        }

        switch item.action {
        case .remove:
            // Re-check: an app may have been opened since the item was added.
            let now = SafetyCheck.assess(item.path, isDirectory: item.isDirectory, apps: apps, protected: protected)
            if now.level == .blocked || now.level == .quitFirst {
                throw Failure(message: now.reason)
            }
            if now.level == .caution && item.safety.level != .caution {
                throw Failure(message: "This item now needs review. Remove it from the list and add it again.")
            }
            if item.path.lowercased().hasSuffix(".dmg") {
                guard let images = run.mountedImages else {
                    throw Failure(message: "Couldn't check whether this disk image is mounted. Try again in a moment.")
                }
                if Installers.isMounted(item.path, in: images) { throw Failure(message: "This disk image is mounted. Eject it first.") }
            }
            if item.isDirectory, let worktree = linkedWorktree(in: item.path) {
                throw Failure(message: "Holds Git worktrees (\(worktree)). Remove them in Git Worktrees, so each repository forgets them and uncommitted work is checked first.")
            }
            try remove(URL(fileURLWithPath: item.path), forever: permanently, big: item.bytes >= run.stagingThreshold)
            return nil

        case .contents:
            // Empty the folder, but leave alone whatever belongs to an app
            // that's running right now: pulling a cache out from under a
            // running app is how apps break.
            let knownCache = Catalog.targets.contains { $0.path == item.path && $0.action == .contents }
            let parentSafety = SafetyCheck.assess(item.path, isDirectory: true, apps: apps, protected: [])
            let resolved = Paths.canonical(item.path)
            if (!knownCache || resolved != item.path) && (parentSafety.level == .blocked || parentSafety.level == .quitFirst) {
                throw Failure(message: parentSafety.reason)
            }
            if SafetyCheck.userProtection(item.path, protected: protected.filter { item.path == $0 || item.path.hasPrefix($0 + "/") }) != nil {
                throw Failure(message: "You protected this folder in Settings.")
            }
            let url = URL(fileURLWithPath: item.path)
            var skipped: [String] = []
            var keptCount = 0
            var removed = 0
            var denied = 0
            var failed: [String] = []
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                if run.cancel.isSet { break }
                // Folders protected in Settings, or holding one, stay.
                if SafetyCheck.userProtection(child.path, protected: protected) != nil {
                    keptCount += 1
                    continue
                }
                // Listed on its own (pip's cache), or Ballast's own logs.
                if kept.contains(where: { $0 == child.path || $0.hasPrefix(child.path + "/") }) { continue }
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? true
                if let app = apps.runningOwner(of: [child.lastPathComponent] + vendorFolders(child, isDirectory: isDirectory)) {
                    if !skipped.contains(app.name) { skipped.append(app.name) }
                    continue
                }
                let childSafety = SafetyCheck.assess(child.path, isDirectory: isDirectory, apps: apps, protected: protected)
                if childSafety.level == .blocked || childSafety.level == .quitFirst { keptCount += 1; continue }
                do {
                    try remove(child, forever: permanently, big: item.bytes >= run.stagingThreshold)
                    removed += 1
                } catch where isPermissionDenied(error) {
                    denied += 1
                } catch {
                    failed.append(child.lastPathComponent)
                }
            }
            // A cancelled clean left the folder part-emptied: not a success.
            if run.cancel.isSet {
                throw Failure(message: "Stopped before this folder was emptied" + (removed > 0 ? " (\(removed) item\(removed == 1 ? "" : "s") removed)." : "."))
            }
            // Without Full Disk Access, ~/Library/Caches always has a few
            // entries macOS protects. That's not a failed clean; nothing
            // removed at all is.
            if removed == 0 && (denied > 0 || !failed.isEmpty) {
                if failed.isEmpty {
                    throw Failure(message: "macOS protects everything left in this folder" + (Access.hasFullDiskAccess ? "." : ". Giving Ballast Full Disk Access may allow more."))
                }
                throw Failure(message: "\(failed.count + denied) items couldn't be removed (\(failed.prefix(3).joined(separator: ", ")))")
            }
            var notes: [String] = []
            if !skipped.isEmpty { notes.append("Kept caches of open apps: \(skipped.joined(separator: ", "))") }
            if keptCount > 0 { notes.append("Kept \(keptCount) item\(keptCount == 1 ? "" : "s") protected by your settings or safety rules") }
            if denied > 0 { notes.append("Kept \(denied) item\(denied == 1 ? "" : "s") macOS protects") }
            if !failed.isEmpty {
                notes.append("Couldn't remove \(failed.count) item\(failed.count == 1 ? "" : "s"): \(failed.prefix(3).joined(separator: ", "))")
            }
            return notes.isEmpty ? nil : notes.joined(separator: ". ")

        case .emptyTrash:
            // Like Finder's Empty Trash: what went to the Trash from other
            // drives waits in each drive's own .Trashes folder.
            var failed = 0
            let trash = URL(fileURLWithPath: home + "/.Trash")
            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
            } catch where isPermissionDenied(error) {
                // Without Full Disk Access macOS hides the Trash's contents
                // from Ballast. Finder can still empty it.
                try emptyTrashInFinder(cancel: run.cancel)
                return "Emptied by Finder, since Ballast can't read the Trash without Full Disk Access."
            }
            for child in children {
                do { try fm.removeItem(at: child) } catch { failed += 1 }
            }
            for drive in Drives.trashes() {
                for child in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: drive), includingPropertiesForKeys: nil)) ?? [] {
                    do { try fm.removeItem(at: child) } catch { failed += 1 }
                }
            }
            if failed > 0 { throw Failure(message: "\(failed) items in the Trash couldn't be removed") }
            return nil

        case .command(let command):
            try runCommand(command, cancel: run.cancel)
            return nil

        case .uninstall(let bundleID, let data):
            // Re-check: still the same app, still closed, nothing protected.
            let now = SafetyCheck.uninstall(item.path, bundleID: bundleID, data: data, apps: apps,
                                            protected: protected, locations: locations)
            if now.level == .blocked || now.level == .quitFirst {
                throw Failure(message: now.reason)
            }
            // Only data the same rules still match; anything already gone
            // (a Caches item on the same list) is skipped.
            let others = AppScanner.bundles(in: locations.roots).filter { $0.path != item.path }
            let current = AppBundle.read(item.path).map {
                Set(AppData.folders(for: $0, others: others, locations: locations,
                                    readContainerMetadata: Access.hasFullDiskAccess))
            } ?? []
            // Always the Trash, whatever was chosen: an app's data deserves a way back.
            try remove(URL(fileURLWithPath: item.path), forever: false)
            var kept: [String] = []
            for path in data {
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                guard current.contains(path) else {
                    kept.append((path as NSString).lastPathComponent)
                    continue
                }
                do { try remove(URL(fileURLWithPath: path), forever: false) } catch {
                    kept.append((path as NSString).lastPathComponent)
                }
            }
            return kept.isEmpty ? nil : "Kept \(kept.count) data item\(kept.count == 1 ? "" : "s") that couldn't be moved: \(kept.prefix(3).joined(separator: ", "))"
        }
    }

    /// "Google", "JetBrains": a vendor folder's own folders name the apps
    /// ("Chrome", "IntelliJIdea2025.1"). A bundle-id name already says it all.
    private static func vendorFolders(_ child: URL, isDirectory: Bool) -> [String] {
        guard isDirectory, !child.lastPathComponent.contains(".") else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: child.path)) ?? []
        return Array(names.filter { !$0.hasPrefix(".") }.sorted().prefix(32))
    }

    /// A linked worktree marks itself with a `.git` *file*. A folder holding
    /// some (an agent's worktrees folder) must go through Git, or each
    /// repository keeps registrations for checkouts that no longer exist.
    static func linkedWorktree(in path: String) -> String? {
        let fm = FileManager.default
        func isMarker(_ folder: String) -> Bool {
            var st = stat()
            return lstat(folder + "/.git", &st) == 0 && st.st_mode & S_IFMT == S_IFREG
        }
        guard !fm.fileExists(atPath: path + "/.git") else { return nil }
        for child in ((try? fm.contentsOfDirectory(atPath: path)) ?? []).prefix(500) where !child.hasPrefix(".") {
            let folder = path + "/" + child
            if isMarker(folder) { return child }
            for grandchild in ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).prefix(50) where !grandchild.hasPrefix(".") {
                if isMarker(folder + "/" + grandchild) { return child + "/" + grandchild }
            }
        }
        return nil
    }

    /// Without Full Disk Access, asks Finder (over Apple Events) to empty
    /// the Trash, the way its own menu command does.
    private static func emptyTrashInFinder(cancel: CancelFlag) throws {
        let result: CommandResult
        do {
            result = try CommandRunner.runSync("/usr/bin/osascript", ["-e", "with timeout of 600 seconds",
                                                                      "-e", "tell application \"Finder\" to empty trash",
                                                                      "-e", "end timeout"],
                                               timeout: .seconds(660), environment: CommandEnvironment.diagnostics, cancel: cancel)
        } catch {
            throw Failure(message: "Finder didn't empty the Trash: \(error.localizedDescription)")
        }
        guard result.succeeded else {
            let detail = result.tail()
            if detail.contains("-1743") || detail.localizedCaseInsensitiveContains("not authorized") || detail.contains("-10004") {
                throw Failure(message: "macOS didn't let Ballast empty the Trash. Give Ballast Full Disk Access in System Settings › Privacy & Security, or allow it to control Finder under Automation, or empty the Trash from Finder.")
            }
            throw Failure(message: "Finder couldn't empty the Trash" + (detail.isEmpty ? "." : ": \(detail)"))
        }
    }

    /// Runs a cleanup command with the user's login PATH (read once, not by
    /// starting an interactive shell each time) and Homebrew kept from
    /// updating. Stopped after `commandTimeout`, or when the clean is cancelled.
    private static func runCommand(_ command: String, cancel: CancelFlag) throws {
        let path = CommandEnvironment.path()
        if let problem = missingTool(command, path: path) { throw Failure(message: problem) }
        let result: CommandResult
        do {
            result = try CommandRunner.runSync("/bin/zsh", ["-c", command], timeout: commandTimeout,
                                               environment: CommandEnvironment.tools(path: path), cancel: cancel)
        } catch let error as CommandError {
            switch error.reason {
            case .timedOut: throw Failure(message: "`\(command)` didn't finish within 10 minutes and was stopped.")
            case .cancelled: throw Failure(message: "Stopped before `\(command)` finished.")
            case .launch(let detail): throw Failure(message: "`\(command)` couldn't start: \(detail)")
            }
        }
        guard result.succeeded else {
            throw Failure(message: failure(command, status: result.status, output: result.output + "\n" + result.errors))
        }
    }

    /// /usr/bin shims that open an "install developer tools" dialog when
    /// the Command Line Tools aren't installed, instead of running.
    private static let developerShims: Set<String> = ["xcrun", "pip3", "python3", "git", "swift", "clang", "make"]
    private static let builtins: Set<String> = ["true", "false", ":", "echo", "printf", "test", "["]

    /// Why `command` can't run here, checked before starting it.
    static func missingTool(_ command: String, path: String) -> String? {
        guard let tool = command.split(separator: " ").first.map(String.init), !builtins.contains(tool) else { return nil }
        guard let located = CommandEnvironment.locate(tool, path: path) else { return failure(command, status: 127, output: "") }
        if located.hasPrefix("/usr/bin/"), developerShims.contains(tool), !hasDeveloperTools() {
            return "`\(tool)` needs Xcode or the Command Line Tools, which aren't installed, so `\(command)` couldn't run."
        }
        return nil
    }

    private static func hasDeveloperTools() -> Bool {
        guard let result = try? CommandRunner.runSync("/usr/bin/xcode-select", ["-p"], timeout: .seconds(5),
                                                      environment: CommandEnvironment.diagnostics),
              result.succeeded else { return false }
        let folder = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return !folder.isEmpty && FileManager.default.fileExists(atPath: folder)
    }

    /// Plain words for a failed cleanup command.
    static func failure(_ command: String, status: Int32, output: String) -> String {
        let tool = command.split(separator: " ").first.map(String.init) ?? command
        // The shell's "command not found".
        if status == 127 { return "`\(tool)` isn't installed, or isn't on your PATH, so `\(command)` couldn't run." }
        if tool == "docker", output.contains("Cannot connect to the Docker daemon") || output.contains("docker daemon running") {
            return "Docker isn't running. Open Docker Desktop or OrbStack, then try again."
        }
        // Shells and tools can print terminal escape sequences and plugin
        // chatter; keep only plain lines for the error message.
        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("\u{1B}") && !$0.contains("\u{07}") && !$0.contains("zoxide") }
        return "`\(command)` failed: \(lines.last ?? "exit status \(status)")"
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
