import BallastCore
import Foundation
import Testing
@testable import Ballast

/// The Overview track's logic: the drop moment's two stages, the hold that
/// keeps it in one frame, the Trash band and the bar's layout.
@Suite struct OverviewViewTests {
    // MARK: Stages

    @Test func movedToTrashPlaysStageOne() {
        let stage = BallastDrop.Stage.decide(movedToTrash: 12_000, freed: 300, emptiedTrash: false, dominant: .build)
        #expect(stage == BallastDrop.Stage(bytes: 12_000, from: .build, to: .trash))
    }

    @Test func freedSpacePlaysStageTwo() {
        let permanent = BallastDrop.Stage.decide(movedToTrash: 0, freed: 9_000, emptiedTrash: false, dominant: .caches)
        #expect(permanent == BallastDrop.Stage(bytes: 9_000, from: .caches, to: .free))
        let emptied = BallastDrop.Stage.decide(movedToTrash: 0, freed: 9_000, emptiedTrash: true, dominant: nil)
        #expect(emptied == BallastDrop.Stage(bytes: 9_000, from: .trash, to: .free))
    }

    @Test func nothingMovedPlaysNothing() {
        #expect(BallastDrop.Stage.decide(movedToTrash: 0, freed: 0, emptiedTrash: true, dominant: .caches) == nil)
        // Unknown bands fall back to caches.
        #expect(BallastDrop.Stage.decide(movedToTrash: 5, freed: 0, emptiedTrash: false, dominant: nil)?.from == .caches)
    }

    @Test func dominantBandHoldsMostBytes() {
        #expect(BallastDrop.Stage.dominant([.caches: 10, .build: 30, .yourFiles: 5]) == .build)
        #expect(BallastDrop.Stage.dominant([:]) == nil)
        #expect(BallastDrop.Stage.dominant([.caches: 0]) == nil)
    }

    @MainActor @Test func tokensSeparateTheStages() {
        let drop = BallastDrop()
        #expect(drop.latest == nil)
        drop.fire(moved: 4_000, to: .trash, from: .caches)
        #expect(drop.token == 1 && drop.freedToken == 0 && drop.reports == 1)
        #expect(drop.latest == DepthBar.Drain(bytes: 4_000, from: .caches, to: .trash, token: 1))
        drop.fire(moved: 4_000, to: .free, from: .trash)
        #expect(drop.token == 2 && drop.freedToken == 1 && drop.freed == 4_000)
        // A report with nothing in it only lets held figures go.
        drop.play(nil)
        #expect(drop.token == 2 && drop.reports == 3)
        drop.fire(moved: 0, to: .free)
        #expect(drop.token == 2 && drop.freedToken == 1 && drop.reports == 4)
    }

    // MARK: Hold

    @Test func holdReleasesWithTheDropOnItsReport() {
        var hold = DropHold()
        hold.cleanupStarted(token: 3)
        #expect(hold.isHolding)
        #expect(hold.runStarted(isCleanup: true) == nil)
        hold.runFinished()
        #expect(hold.waitsForTimeout)
        #expect(hold.reported(token: 4) == .drop)
        #expect(!hold.isHolding && !hold.waitsForTimeout)
        // Nothing held, nothing to release.
        #expect(hold.reported(token: 5) == nil)
    }

    @Test func holdReleasesQuietlyWithoutADrop() {
        var hold = DropHold()
        hold.cleanupStarted(token: 7)
        #expect(hold.reported(token: 7) == .quiet)
    }

    @Test func anotherRunEndsTheHold() {
        var hold = DropHold()
        hold.cleanupStarted(token: 0)
        #expect(hold.runStarted(isCleanup: false) == .quiet)
        #expect(!hold.isHolding)
    }

    /// Stopped before the first item: no report ever comes, so the grace
    /// period lets go, and only once the run has ended.
    @Test func holdTimesOutOnlyAfterTheRunEnds() {
        var hold = DropHold()
        hold.cleanupStarted(token: 1)
        #expect(hold.timedOut() == nil)
        hold.runFinished()
        #expect(hold.timedOut() == .quiet)
        #expect(!hold.isHolding)
    }

    @Test func aSecondCleanupKeepsTheFirstToken() {
        var hold = DropHold()
        hold.cleanupStarted(token: 2)
        hold.runFinished()
        hold.cleanupStarted(token: 9)
        #expect(!hold.waitsForTimeout)
        #expect(hold.reported(token: 2) == .quiet)
    }

    // MARK: Bands

    @Test func trashIsCarvedOutOfYourFiles() {
        let snapshot = [StatusSnapshot.Segment(kind: .applications, bytes: 50),
                        StatusSnapshot.Segment(kind: .yourFiles, bytes: 300),
                        StatusSnapshot.Segment(kind: .caches, bytes: 40),
                        StatusSnapshot.Segment(kind: .system, bytes: 100)]
        let bands = DepthBar.segments(snapshot, trash: 70)
        #expect(bands.first { $0.category == .yourFiles }?.bytes == 230)
        #expect(bands.last == DepthBar.Segment(category: .trash, bytes: 70))
        #expect(bands.reduce(0) { $0 + $1.bytes } == 490)
        // More "Trash" than Your files can't make a band negative.
        let capped = DepthBar.segments(snapshot, trash: 1_000)
        #expect(capped.first { $0.category == .yourFiles } == nil)
        #expect(capped.reduce(0) { $0 + $1.bytes } == 490)
        #expect(DepthBar.segments(snapshot, trash: 0).count == 4)
    }

    @Test func cleanedPathsFindTheirBand() {
        let home = "/Users/me"
        #expect(DepthBar.Category.of(path: "/Users/me/.Trash/old.zip", home: home) == .trash)
        #expect(DepthBar.Category.of(path: "/Users/me/.Trash", home: home) == .trash)
        #expect(DepthBar.Category.of(path: "/Users/me/.Trashy", home: home) == .yourFiles)
        #expect(DepthBar.Category.of(path: "/Users/me/Library/Caches/x", home: home, suggested: .caches) == .caches)
        #expect(DepthBar.Category.of(path: "/Users/me/app/node_modules", home: home, suggested: .build) == .build)
        #expect(DepthBar.Category.of(path: "/Users/me/Movies/a.mov", home: home) == .yourFiles)
        #expect(DepthBar.Category.of(path: "/Applications/Big.app", home: home) == .applications)
        // Caches outside home are counted in System Data, as the bar does.
        #expect(DepthBar.Category.of(path: "/Library/Caches/x", home: home, suggested: .caches) == .system)
    }

    @Test func otherDriveBands() {
        #expect(AppModel.diskSegments(used: 500, folders: nil, builds: 0)
            == [DepthBar.Segment(category: .other, name: "Used", bytes: 500)])
        let scanned = AppModel.diskSegments(used: 500, folders: 420, builds: 600)
        #expect(scanned.map(\.bytes) == [420, 80])
        #expect(scanned.map(\.category) == [.build, .system])
        #expect(AppModel.diskSegments(used: 0, folders: nil, builds: 0).isEmpty)
    }

    // MARK: Layout

    @Test func trashBandSitsAgainstTheWater() {
        let segments = [DepthBar.Segment(category: .trash, bytes: 100),
                        DepthBar.Segment(category: .yourFiles, bytes: 300),
                        DepthBar.Segment(category: .system, bytes: 100)]
        let bands = DepthBar.layout(segments, total: 1_000, width: 1_000)
        #expect(bands.map(\.segment.category) == [.yourFiles, .system, .trash])
        #expect(bands.allSatisfy { $0.width >= 2 })
        #expect((bands.last?.end ?? 0) <= 1_000)
    }

    @Test func tinyBandsStillShowAndFit() {
        let segments = (0..<40).map { DepthBar.Segment(category: .other, name: "s\($0)", bytes: 1) }
        let bands = DepthBar.layout(segments, total: 1_000_000, width: 100)
        #expect(bands.count == 40)
        #expect((bands.last?.end ?? 0) <= 100.5)
    }

    @Test func ghostTravelsTheRightWay() {
        let segments = [DepthBar.Segment(category: .caches, bytes: 200),
                        DepthBar.Segment(category: .system, bytes: 200),
                        DepthBar.Segment(category: .trash, bytes: 100)]
        let bands = DepthBar.layout(segments, total: 1_000, width: 1_000)
        let toTrash = DepthBar.ghostPath(drain: .init(bytes: 50, from: .caches, to: .trash, token: 1),
                                         bands: bands, total: 1_000, width: 1_000)
        #expect(toTrash.width == 50)
        #expect(toTrash.end > toTrash.start)
        #expect(toTrash.end + toTrash.width <= bands.last!.end + 0.5)
        // The Trash band is gone after emptying: the piece leaves the end of
        // the used area into the water.
        let emptied = DepthBar.layout(Array(segments.prefix(2)), total: 1_000, width: 1_000)
        let toWater = DepthBar.ghostPath(drain: .init(bytes: 100, from: .trash, to: .free, token: 2),
                                         bands: emptied, total: 1_000, width: 1_000)
        #expect(abs(toWater.start - emptied.last!.end) < 0.5)
        #expect(toWater.end > toWater.start)
        #expect(toWater.end <= 1_000 - toWater.width)
    }
}
