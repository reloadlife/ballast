import Foundation
import Testing
@testable import Ballast

@Suite struct StatusSnapshotTests {
    private let snapshot = StatusSnapshot(
        date: Date(timeIntervalSince1970: 1_790_000_000),
        volumeName: "Macintosh HD",
        totalBytes: 1_000_000_000_000,
        freeBytes: 400_000_000_000,
        segments: [
            .init(kind: .applications, bytes: 100_000_000_000),
            .init(kind: .yourFiles, bytes: 300_000_000_000),
            .init(kind: .caches, bytes: 20_000_000_000),
            .init(kind: .system, bytes: 180_000_000_000),
        ],
        safeToClean: 12_500_000_000,
        freedLastWeek: 3_000_000_000,
        scannedAt: Date(timeIntervalSince1970: 1_789_990_000)
    )

    @Test func roundTripsThroughJSON() throws {
        let data = try StatusSnapshot.encoder.encode(snapshot)
        let decoded = try StatusSnapshot.decoder.decode(StatusSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }

    @Test func roundTripsWithoutAScan() throws {
        var bare = snapshot
        bare.segments = []
        bare.scannedAt = nil
        let data = try StatusSnapshot.encoder.encode(bare)
        #expect(try StatusSnapshot.decoder.decode(StatusSnapshot.self, from: data) == bare)
    }

    @Test func newReadingRebalancesSystemData() {
        // 10 GB less free: System Data absorbs it, so the bar still adds up.
        let updated = snapshot.updating(free: 390_000_000_000, total: 1_000_000_000_000)
        #expect(updated.freeBytes == 390_000_000_000)
        #expect(updated.segments.first { $0.kind == .system }?.bytes == 190_000_000_000)
        #expect(updated.segments.reduce(0) { $0 + $1.bytes } == updated.usedBytes)
        #expect(updated.safeToClean == snapshot.safeToClean)
        #expect(updated.scannedAt == snapshot.scannedAt)
    }

    @Test func livesInTheSupportFolder() {
        // Spelled out so the file compiles alone; it must not drift.
        #expect(StatusSnapshot.directory == Paths.supportDir)
    }
}

@Suite struct LowSpaceTests {
    private let gb: Int64 = 1_000_000_000
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func quietAboveTheThreshold() {
        #expect(!LowSpace.shouldNotify(free: 25 * gb, threshold: 20 * gb, last: nil, now: now))
        #expect(!LowSpace.shouldNotify(free: 20 * gb, threshold: 20 * gb, last: nil, now: now))
    }

    @Test func firstDropNotifies() {
        #expect(LowSpace.shouldNotify(free: 12 * gb, threshold: 20 * gb, last: nil, now: now))
    }

    @Test func onceADay() {
        let last = LowSpace.Notified(date: now.addingTimeInterval(-3600), free: 12 * gb)
        #expect(!LowSpace.shouldNotify(free: 12 * gb, threshold: 20 * gb, last: last, now: now))
        // 5 GB is not yet half the threshold (10 GB) below the 14 GB notified.
        let notifiedAt14 = LowSpace.Notified(date: last.date, free: 14 * gb)
        #expect(!LowSpace.shouldNotify(free: 5 * gb, threshold: 20 * gb, last: notifiedAt14, now: now))

        let yesterday = LowSpace.Notified(date: now.addingTimeInterval(-86_400), free: 12 * gb)
        #expect(LowSpace.shouldNotify(free: 12 * gb, threshold: 20 * gb, last: yesterday, now: now))
    }

    @Test func aFurtherHalfThresholdDropNotifiesAgain() {
        let last = LowSpace.Notified(date: now.addingTimeInterval(-3600), free: 15 * gb)
        #expect(!LowSpace.shouldNotify(free: 6 * gb, threshold: 20 * gb, last: last, now: now))
        #expect(LowSpace.shouldNotify(free: 5 * gb, threshold: 20 * gb, last: last, now: now))
    }

    @Test func messageNamesTheVolumeAndWhatCanGo() {
        let withSafe = LowSpace.message(free: 12 * gb, volume: "Macintosh HD", safeToClean: 8 * gb)
        #expect(withSafe.body == "Only 12 GB left on Macintosh HD. 8 GB is safe to clean.")
        let without = LowSpace.message(free: 12 * gb, volume: "Macintosh HD", safeToClean: 0)
        #expect(without.body == "Only 12 GB left on Macintosh HD.")
    }

    @Test func preferencesFromOlderFilesKeepDefaults() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"staleMonths": 12}"#.utf8))
        #expect(old.showMenuBarItem && old.lowSpaceAlert && old.lowSpaceThresholdGB == 20 && !old.menuBarShowsFreeSpace)

        var changed = Preferences()
        changed.showMenuBarItem = false
        changed.lowSpaceThresholdGB = 50
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(changed))
        #expect(decoded == changed)
    }

    @Test func freedCountsOnlyTheLastWeek() {
        let points = [
            HistoryPoint(date: now.addingTimeInterval(-10 * 86_400), free: 0, freed: 5 * gb),
            HistoryPoint(date: now.addingTimeInterval(-2 * 86_400), free: 0, freed: 2 * gb),
            HistoryPoint(date: now.addingTimeInterval(-3600), free: 0, freed: nil),
            HistoryPoint(date: now.addingTimeInterval(-60), free: 0, freed: 1 * gb),
        ]
        #expect(History.freed(in: points, now: now) == 3 * gb)
    }
}
