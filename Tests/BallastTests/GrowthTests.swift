import Foundation
import Testing
@testable import Ballast

private let MB: Int64 = 1 << 20
private let GB: Int64 = 1 << 30

@Suite struct GrowthTests {
    /// A consistent tree: every folder's size includes its subfolders.
    private let before: [String: Int64] = [
        "/": 100 * GB,
        "/Users": 60 * GB,
        "/Users/me": 60 * GB,
        "/Users/me/Library": 30 * GB,
        "/Users/me/Library/Caches": 10 * GB,
        "/Users/me/Library/Caches/com.app": 8 * GB,
        "/Users/me/projects": 20 * GB,
        "/Users/me/projects/web": 5 * GB,
        "/Users/me/projects/web/node_modules": 2 * GB,
        "/Users/me/Movies": 10 * GB,
    ]

    @Test func topGrowthIsTheDeepestFolderThatExplainsIt() {
        var after = before
        // 3 GB lands in one cache folder: every ancestor grows by the same.
        for path in ["/", "/Users", "/Users/me", "/Users/me/Library", "/Users/me/Library/Caches", "/Users/me/Library/Caches/com.app"] {
            after[path]! += 3 * GB
        }
        let rows = Growth.rank(Growth.changes(old: before, oldFloor: 20 * MB, new: after, newFloor: 20 * MB), sizes: after)
        #expect(rows.map(\.path) == ["/Users/me/Library/Caches/com.app"])
        #expect(rows.first?.bytes == 3 * GB)
        #expect(rows.first?.size == 11 * GB)
    }

    @Test func parentCollapsesWhenOneChildExplainsEightyPercent() {
        var after = before
        // Caches grows 1 GB: 850 MB in com.app, 150 MB loose in Caches itself.
        for path in ["/", "/Users", "/Users/me", "/Users/me/Library", "/Users/me/Library/Caches"] { after[path]! += GB }
        after["/Users/me/Library/Caches/com.app"]! += 850 * MB
        let rows = Growth.rank(Growth.changes(old: before, oldFloor: 20 * MB, new: after, newFloor: 20 * MB))
        // 150 MB is unexplained but under a fifth of Caches' 1 GB: not listed.
        #expect(rows.map(\.path) == ["/Users/me/Library/Caches/com.app"])
    }

    @Test func spreadGrowthListsTheParentForWhatChildrenDontExplain() {
        var after = before
        // Library grows 4 GB: 1 GB in com.app, 3 GB across folders under the floor.
        for path in ["/", "/Users", "/Users/me", "/Users/me/Library"] { after[path]! += 4 * GB }
        after["/Users/me/Library/Caches"]! += GB
        after["/Users/me/Library/Caches/com.app"]! += GB
        let rows = Growth.rank(Growth.changes(old: before, oldFloor: 20 * MB, new: after, newFloor: 20 * MB))
        #expect(rows.map(\.path) == ["/Users/me/Library", "/Users/me/Library/Caches/com.app"])
        let library = rows[0]
        #expect(library.bytes == 3 * GB)       // only what com.app doesn't explain
        #expect(library.change == 4 * GB)
        #expect(library.inside == ["/Users/me/Library/Caches/com.app"])
        // Listed rows never overlap in bytes: they add up to the real growth.
        #expect(rows.reduce(0) { $0 + $1.bytes } == 4 * GB)
    }

    @Test func newFolderCountsFromTheFloorNotFromZero() {
        var after = before
        // A new 500 MB folder: it wasn't recorded before, so it was under 20 MB.
        after["/Users/me/projects/api"] = 500 * MB
        for path in ["/", "/Users", "/Users/me", "/Users/me/projects"] { after[path]! += 500 * MB }
        let changes = Growth.changes(old: before, oldFloor: 20 * MB, new: after, newFloor: 20 * MB)
        #expect(changes["/Users/me/projects/api"] == 480 * MB)
        let rows = Growth.rank(changes)
        #expect(rows.map(\.path) == ["/Users/me/projects/api"])
    }

    @Test func shrinkingIsFreedSpaceNotGrowth() {
        var after = before
        // node_modules deleted (gone from the snapshot), Movies grew 2 GB.
        after["/Users/me/projects/web/node_modules"] = nil
        for path in ["/Users/me/projects/web", "/Users/me/projects"] { after[path]! -= 2 * GB }
        after["/Users/me/Movies"]! += 2 * GB
        let report = Growth.report(old: before, oldFloor: 20 * MB, new: after, newFloor: 20 * MB, since: .distantPast)
        #expect(report.grew.map(\.path) == ["/Users/me/Movies"])
        // Missing afterwards means under the floor: at least 2 GB − 20 MB went.
        #expect(report.freed == 2 * GB - 20 * MB)
        // Net zero above them: nothing else is listed.
        #expect(!report.grew.contains { $0.path == "/" || $0.path == "/Users/me" })
    }

    @Test func smallChangesAreNotListed() {
        var after = before
        for path in ["/", "/Users", "/Users/me", "/Users/me/Movies"] { after[path]! += 60 * MB }
        let report = Growth.report(old: before, oldFloor: 20 * MB, new: after, newFloor: 20 * MB, since: .distantPast)
        #expect(report.grew.isEmpty)
        #expect(report.freed == 0)
    }

    @Test func topListIsLimited() {
        var old: [String: Int64] = ["/": 0]
        var new: [String: Int64] = ["/": 0]
        for i in 1...12 {
            old["/f\(i)"] = GB
            new["/f\(i)"] = GB + Int64(i) * 200 * MB
            new["/"]! += new["/f\(i)"]!
            old["/"]! += GB
        }
        let report = Growth.report(old: old, oldFloor: 20 * MB, new: new, newFloor: 20 * MB, since: .distantPast, limit: 8)
        #expect(report.grew.count == 8)
        #expect(report.grew.first?.path == "/f12")
        #expect(!report.grew.contains { $0.path == "/" })
    }

    // MARK: Periods

    private func snapshot(_ key: Int, hoursAgo: Double, now: Date) -> GrowthSnapshot {
        GrowthSnapshot(key: key, taken: now.addingTimeInterval(-hoursAgo * 3600), floor: 20 * MB)
    }

    @Test func onlyPeriodsWithHistoryAreOffered() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let today = GrowthStore.dayKey(now)
        let current = snapshot(today, hoursAgo: 0, now: now)
        // First day: nothing to compare with.
        #expect(Growth.periods(in: [current], current: current, now: now).isEmpty)

        // A session copy from this morning, and yesterday evening's reading.
        let session = snapshot(GrowthStore.sessionKey, hoursAgo: 5, now: now)
        let yesterday = snapshot(today - 1, hoursAgo: 20, now: now)
        #expect(Growth.periods(in: [session, yesterday, current], current: current, now: now) == [.lastOpen, .day])

        // 60 days old doesn't stand in for "7 days" or "30 days".
        let old = snapshot(today - 60, hoursAgo: 24 * 60, now: now)
        #expect(Growth.periods(in: [old, current], current: current, now: now).isEmpty)

        let week = snapshot(today - 8, hoursAgo: 24 * 8, now: now)
        let month = snapshot(today - 29, hoursAgo: 24 * 29, now: now)
        #expect(Growth.periods(in: [month, week, current], current: current, now: now) == [.week, .month])
        #expect(Growth.baseline(for: .week, in: [month, week, current], current: current, now: now) == week)
    }

    @Test func sessionCopyNewerThanTodayIsNotABaseline() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let current = snapshot(GrowthStore.dayKey(now), hoursAgo: 0, now: now)
        let session = GrowthSnapshot(key: GrowthStore.sessionKey, taken: current.taken, floor: 20 * MB)
        #expect(Growth.baseline(for: .lastOpen, in: [session, current], current: current, now: now) == nil)
    }

    // MARK: Store

    @Test func storeKeepsOneSnapshotPerDayAndTheLastOpenCopy() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "ballast-growth-\(UUID().uuidString).sqlite").path
        defer { GrowthStore.clear(path: path) }
        let store = try GrowthStore(path: path)
        let day = Date(timeIntervalSince1970: 2_000_000_000)

        try store.record(["/": 10 * GB, "/a": 5 * GB], at: day.addingTimeInterval(-86_400), newSession: true)
        try store.record(["/": 11 * GB, "/a": 6 * GB, "/tiny": MB], at: day, newSession: true)
        try store.record(["/": 12 * GB, "/a": 7 * GB], at: day.addingTimeInterval(60), newSession: false)

        let keys = try store.snapshots().map(\.key)
        #expect(keys == [GrowthStore.sessionKey, GrowthStore.dayKey(day) - 1, GrowthStore.dayKey(day)])
        #expect(try store.sizes(GrowthStore.dayKey(day)) == ["/": 12 * GB, "/a": 7 * GB])
        // The session copy is yesterday's, taken before today's first write.
        #expect(try store.sizes(GrowthStore.sessionKey) == ["/": 10 * GB, "/a": 5 * GB])

        let summary = try Growth.summary(store, period: nil, now: day.addingTimeInterval(60))
        #expect(summary.today == 2 * GB)
        #expect(summary.days == 2)
    }

    @Test func storeThinsOldDaysAndDropsExpiredOnes() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "ballast-growth-\(UUID().uuidString).sqlite").path
        defer { GrowthStore.clear(path: path) }
        let store = try GrowthStore(path: path)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for daysAgo in stride(from: 100, through: 0, by: -1) {
            try store.record(["/": GB, "/gone-\(daysAgo)": GB], at: now.addingTimeInterval(-Double(daysAgo) * 86_400), newSession: false)
        }
        let today = GrowthStore.dayKey(now)
        let keys = try store.snapshots().map(\.key)
        #expect(keys.allSatisfy { $0 >= today - GrowthStore.retentionDays })
        // Every one of the last 30 days, then about one a week.
        #expect(keys.filter { $0 >= today - GrowthStore.dailyDays }.count == GrowthStore.dailyDays + 1)
        #expect(keys.filter { $0 < today - GrowthStore.dailyDays }.count <= 10)
        // Paths only the dropped days had are gone too.
        #expect(try store.sizes(today - 99).isEmpty)
    }
}

@Suite struct SearchQueryTests {
    @Test func wrapsInWildcards() {
        #expect(SearchQuery.pattern(for: "node") == "%node%")
        #expect(SearchQuery.pattern(for: "  node \n") == "%node%")
        #expect(SearchQuery.pattern(for: "   ") == nil)
        #expect(SearchQuery.pattern(for: "") == nil)
    }

    @Test func wildcardsInNamesAreLiteral() {
        #expect(SearchQuery.pattern(for: "100%") == "%100\\%%")
        #expect(SearchQuery.pattern(for: "__pycache__") == "%\\_\\_pycache\\_\\_%")
        #expect(SearchQuery.pattern(for: "a\\b") == "%a\\\\b%")
        // Quotes need nothing: the pattern is bound, never spliced into SQL.
        #expect(SearchQuery.pattern(for: "it's \"x\"") == "%it's \"x\"%")
    }

    @Test func matchesAgainstARealIndex() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "ballast-search-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let db = try IndexDB(path: path, mode: .build)
        func node(_ total: Int64) -> WalkNode {
            WalkNode(local: 0, parent: -1, name: "", own: 0, ownFiles: 0, total: total, files: 0, err: 0, newest: 0)
        }
        try db.upsert(id: 1, parent: nil, name: "/root", node: node(1000))
        let names = ["node_modules", "nodeXmodules", "100% done", "1000 done", "It's \"quoted\"", "NODE_MODULES"]
        for (i, name) in names.enumerated() {
            try db.upsert(id: Int64(i + 2), parent: 1, name: name, node: node(Int64(100 - i)))
        }
        try db.createIndexes()

        // `_` is literal: nodeXmodules doesn't match; case is ignored.
        #expect(try db.search("node_", limit: 10).map(\.name) == ["node_modules", "NODE_MODULES"])
        #expect(try db.search("100%", limit: 10).map(\.name) == ["100% done"])
        #expect(try db.search("'s \"q", limit: 10).map(\.name) == ["It's \"quoted\""])
        #expect(try db.search("done", limit: 1).map(\.name) == ["100% done"])  // biggest first, limited
        #expect(try db.search("root", limit: 10).isEmpty)                     // the volume root isn't a result
    }
}

@Suite struct ExportTests {
    @Test func csvQuotesOnlyWhatNeedsIt() {
        #expect(CSV.field("plain") == "plain")
        #expect(CSV.field("a,b") == "\"a,b\"")
        #expect(CSV.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSV.field("two\nlines") == "\"two\nlines\"")
        #expect(CSV.field("cr\rhere") == "\"cr\rhere\"")
        #expect(CSV.line(["a", "b,c", ""]) == "a,\"b,c\",")
    }

    @Test func documentHasAHeaderAndOneLinePerFolder() throws {
        let row = DirRow(id: 2, parent: 1, name: "odd, \"name\"", own: 0, ownFiles: 0, total: 512 << 20,
                         files: 3, err: 0, newest: 1_700_000_000)
        let locked = DirRow(id: 3, parent: 1, name: "Locked", own: 0, ownFiles: 0, total: 0, files: 0, err: 13, newest: 0)
        let rows = [ExportRow(path: "/Users/me/odd, \"name\"", row: row, of: 1 << 30),
                    ExportRow(path: "/Users/me/Locked", row: locked, of: 1 << 30)]
        let csv = CSV.document(rows)
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0] == "path,name,bytes,size,share,last_modified,locked")
        #expect(lines[1].hasPrefix("\"/Users/me/odd, \"\"name\"\"\",\"odd, \"\"name\"\"\",536870912,"))
        #expect(lines[1].contains(",0.5000,2023-11-14T22:13:20Z,false"))
        #expect(lines[2].hasSuffix(",0.0000,,true"))
        #expect(lines.count == 4 && lines[3].isEmpty)

        let json = try JSONDecoder().decode([ExportRow].self, from: FolderExport.data(rows, as: .json))
        #expect(json == rows)
    }
}
