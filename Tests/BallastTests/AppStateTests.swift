import Foundation
import Testing
@testable import Ballast

/// One run at a time, and user work is never dropped without a word.
@Suite struct RunGateTests {
    private let update = RunGate.Running(kind: .background, title: "Checking what changed")
    private let cleaning = RunGate.Running(kind: .user, title: "Cleaning")

    @Test func idleStartsAnything() {
        #expect(RunGate.decide(running: nil, waiting: nil, incoming: .user) == .start)
        #expect(RunGate.decide(running: nil, waiting: nil, incoming: .background) == .start)
    }

    /// Clean Up during the five-minute refresh stops the refresh.
    @Test func userRunPreemptsBackgroundWork() {
        #expect(RunGate.decide(running: update, waiting: nil, incoming: .user) == .preempt)
    }

    /// A second button press while a cleanup runs is refused with a reason.
    @Test func userRunDuringUserRunIsRefusedWithAMessage() {
        let decision = RunGate.decide(running: cleaning, waiting: nil, incoming: .user)
        #expect(decision == .refuse(RunGate.busyMessage("Cleaning")))
        #expect(RunGate.busyMessage("Cleaning").contains("Cleaning"))
    }

    /// Background ticks never interrupt anything and never show an error:
    /// the next tick tries again.
    @Test func backgroundRunsAreDroppedQuietly() {
        #expect(RunGate.decide(running: update, waiting: nil, incoming: .background) == .refuse(nil))
        #expect(RunGate.decide(running: cleaning, waiting: nil, incoming: .background) == .refuse(nil))
        #expect(RunGate.decide(running: nil, waiting: "Cleaning", incoming: .background) == .refuse(nil))
    }

    /// While a user run waits for a background one to stop, it's next in
    /// line: another user request is told what's about to run.
    @Test func waitingUserRunHoldsItsPlace() {
        #expect(RunGate.decide(running: update, waiting: "Cleaning", incoming: .user)
            == .refuse(RunGate.busyMessage("Cleaning")))
        #expect(RunGate.decide(running: nil, waiting: "Cleaning", incoming: .user)
            == .refuse(RunGate.busyMessage("Cleaning")))
    }
}

@Suite struct UpdateBackoffTests {
    @Test func delaysDoubleThenCapAtAnHour() {
        let minutes = (1...6).map { UpdateBackoff.delay(afterFailures: $0) / 60 }
        #expect(minutes == [5, 10, 20, 60, 60, 60])
        #expect(UpdateBackoff.delay(afterFailures: 0) == 0)
    }

    @Test func failuresPostponeTheNextAttempt() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var backoff = UpdateBackoff()
        #expect(backoff.allowsAttempt(at: now))

        backoff.failed(at: now)
        #expect(!backoff.allowsAttempt(at: now.addingTimeInterval(4 * 60)))
        #expect(backoff.allowsAttempt(at: now.addingTimeInterval(5 * 60)))

        backoff.failed(at: now)
        #expect(!backoff.allowsAttempt(at: now.addingTimeInterval(9 * 60)))
        #expect(backoff.allowsAttempt(at: now.addingTimeInterval(10 * 60)))

        backoff.succeeded()
        #expect(backoff.failures == 0)
        #expect(backoff.allowsAttempt(at: now))
    }
}

/// Only the newest progress report crosses to the main thread, one hop at a time.
@Suite struct ProgressMailboxTests {
    @Test func coalescesReportsUntilTaken() {
        let mailbox = ProgressMailbox()
        #expect(mailbox.post(ScanStatus(title: "a")))
        #expect(!mailbox.post(ScanStatus(title: "b")))
        #expect(!mailbox.post(ScanStatus(title: "c")))
        #expect(mailbox.take()?.title == "c")
        #expect(mailbox.take() == nil)
        // Taken: the next report needs a new delivery.
        #expect(mailbox.post(ScanStatus(title: "d")))
    }
}

@Suite struct FullDiskAccessLossTests {
    @Test func lostOnlyWhenItWasGrantedBefore() {
        #expect(AppModel.accessWasLost(granted: false, hadAccess: true))
        #expect(!AppModel.accessWasLost(granted: false, hadAccess: false))
        #expect(!AppModel.accessWasLost(granted: true, hadAccess: true))
        #expect(!AppModel.accessWasLost(granted: true, hadAccess: false))
    }
}

/// Files the app and the agents share load even when they come from
/// another version or are partly damaged.
@Suite struct TolerantDecodingTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ballast-\(name)-\(UUID().uuidString).json")
    }

    @Test func trashLogSkipsUnreadableRecordsAndFillsMissingKeys() throws {
        let url = temporaryURL("log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let json = """
        [
          {"permanent": false, "items": [{"path": "/x/node_modules", "moves": [{"from": "/x/node_modules", "to": "/t/node_modules"}]}]},
          {"id": "not-a-uuid", "items": "nope"},
          {"items": [{"path": "/y/target", "bytes": 5, "moves": [{"from": "/y/target"}, {"from": "/y/target", "to": "/t/target", "restored": true}]}]}
        ]
        """
        try Data(json.utf8).write(to: url)
        let records = TrashLog(url: url).load()
        #expect(records.count == 2)
        #expect(records[0].items[0].name == "node_modules")
        #expect(records[0].items[0].bytes == 0)
        #expect(records[0].items[0].moves.first?.restored == false)
        #expect(records[0].auto == false)
        // The broken move is skipped, the good one kept.
        #expect(records[1].items[0].moves.count == 1)
        #expect(records[1].items[0].moves[0].restored)
        #expect(records[1].permanent == false)
    }

    /// A per-item log during a cleanup: the first write adds the record,
    /// later ones replace it.
    @Test func trashLogUpdateAddsAMissingRecord() {
        let url = temporaryURL("log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let log = TrashLog(url: url)
        var record = CleanupRecord(permanent: false, items: [.init(name: "a", path: "/x/a", bytes: 1, moves: [])])
        log.update(record)
        record.items.append(.init(name: "b", path: "/x/b", bytes: 2, moves: []))
        log.update(record)
        let records = log.load()
        #expect(records.count == 1)
        #expect(records.first?.items.count == 2)
    }

    /// A file this version can't read at all is kept aside, never overwritten.
    @Test func unreadableTrashLogIsKeptAside() throws {
        let url = temporaryURL("log")
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
        defer {
            for path in [url.path, aside.path, url.path + ".lock"] { try? FileManager.default.removeItem(atPath: path) }
        }
        try Data("{\"version\": 9}".utf8).write(to: url)
        let log = TrashLog(url: url)
        log.append(CleanupRecord(permanent: true, items: [.init(name: "a", path: "/x/a", bytes: 1, moves: [])]))
        #expect(log.load().count == 1)
        #expect(FileManager.default.fileExists(atPath: aside.path))
    }

    @Test func autoCleanSettingsToleratesUnknownKindsAndMissingKeys() {
        let json = """
        {"rules": [
          {"kind": "nodeModules", "enabled": true},
          {"kind": "somethingNew", "enabled": true, "days": 3},
          {"kind": "nodeModules", "enabled": false},
          {"kind": "rustTarget", "days": 30, "permanent": true}
        ]}
        """
        let settings = AutoCleanSettings.decode(Data(json.utf8))
        #expect(settings.background == false)
        #expect(settings.rules.count == ArtifactKind.allCases.count)
        let node = settings.rules.first { $0.kind == .nodeModules }
        #expect(node?.enabled == true)
        #expect(node?.days == AutoCleanRule(kind: .nodeModules).days)
        // Moving to the Trash is the default: Put Back can undo it.
        #expect(node?.permanent == false)
        let rust = settings.rules.first { $0.kind == .rustTarget }
        #expect(rust?.days == 30)
        #expect(rust?.permanent == true)
    }

    @Test func garbledAutoCleanSettingsGiveDefaults() {
        let settings = AutoCleanSettings.decode(Data("not json".utf8))
        #expect(settings == AutoCleanSettings.decode(Data()))
        #expect(settings.rules.count == ArtifactKind.allCases.count)
        #expect(settings.rules.allSatisfy { !$0.enabled && !$0.permanent })
    }
}

@Suite struct FileLockTests {
    @Test func tryLockFailsWhileHeld() {
        let url = FileManager.default.temporaryDirectory.appending(path: "ballast-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: url.path + ".lock") }
        let nested = FileLock.withLock(url) {
            // flock locks belong to the open file: a second open conflicts.
            FileLock.tryLock(url) { true }
        }
        #expect(nested == nil)
        #expect(FileLock.tryLock(url) { true } == true)
    }
}

/// An update that finds nothing new still reloads when someone else (the
/// auto-clean agent, `Ballast --index`) moved the index on: the app tells
/// by the change-log position the index was brought up to.
@Suite struct IndexEventIDTests {
    @Test func readsThePositionAndSeesOtherWritersWithoutReopening() async throws {
        let fm = FileManager.default
        let path = fm.temporaryDirectory.appending(path: "ballast-event-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: path + suffix) } }
        #expect(IndexReader.eventID(index: path) == nil)

        let build = try IndexDB(path: path, mode: .build)
        try build.createIndexes()
        try build.setMeta("eventId", "100")
        #expect(IndexReader.eventID(index: path) == "100")

        let reader = IndexReader(index: path, isStartup: false)
        await reader.reopen()
        #expect(await reader.eventID() == "100")

        // Another process brings the index up to date.
        try IndexDB(path: path, mode: .write).setMeta("eventId", "200")
        #expect(IndexReader.eventID(index: path) == "200")
        #expect(await reader.eventID() == "200")
    }
}
