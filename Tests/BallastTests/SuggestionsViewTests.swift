import AppKit
import SwiftUI
import Testing
@testable import Ballast

/// Fake data for the Suggestions and Cleanup List views.
private enum Fake {
    static let home = NSHomeDirectory()

    static func item(_ name: String, _ path: String, _ bytes: Int64, _ safety: Safety,
                     action: CleanAction = .remove, included: Bool = false) -> PlanItem {
        PlanItem(name: name, path: path, bytes: bytes, action: action, isDirectory: true, safety: safety, included: included)
    }

    static let slack = RunningApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", pid: 1, bundlePath: "/Applications/Ballast Fake Slack.app")

    static let plan: [PlanItem] = [
        item("User caches", home + "/Library/Caches", 6_400_000_000, .safe("Rebuilt automatically when needed."), action: .contents),
        item("node_modules", home + "/projects/site/node_modules", 1_250_000_000, .safe("Comes back with npm install.")),
        item("Slack: Cache", home + "/Library/Application Support/Slack/Cache", 820_000_000,
             .quit(slack, "this folder")),
        item("Old exports", home + "/Movies/Old exports", 14_000_000_000,
             .caution("Big folder nothing has changed in for a year. Check it holds nothing you need.")),
        item("Uninstall Figma", "/Applications/Ballast Fake Figma.app", 610_000_000, .safe("Moved to the Trash with its data."),
             action: .uninstall(bundleID: "com.figma.Desktop", data: [home + "/Library/Application Support/Figma"])),
        item("npm cache", home + "/.npm", 2_100_000_000, .safe("npm downloads packages again when needed."),
             action: .command("npm cache clean --force")),
    ]

    static func result(_ name: String, _ path: String, _ bytes: Int64, _ category: Ballast.Category,
                       action: CleanAction? = .remove, newest: Int64 = 0) -> ScanResult {
        ScanResult(target: Target(name: name, path: path, category: category, action: action), bytes: bytes, newest: newest)
    }

    static let appCaches: [AppCacheBreakdown] = [
        AppCacheBreakdown(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", appPath: "/Applications/Ballast Fake Slack.app", folders: [
            AppCacheFolder(path: home + "/Library/Application Support/Slack/Cache", label: "Slack web cache",
                           bytes: 820_000_000, knowledgeID: nil),
            AppCacheFolder(path: home + "/Library/Caches/com.tinyspeck.slackmacgap", label: "Cache", bytes: 240_000_000,
                           knowledgeID: nil, coveredBy: home + "/Library/Caches"),
        ]),
        AppCacheBreakdown(bundleID: "com.spotify.client", name: "Spotify", appPath: "/Applications/Ballast Fake Spotify.app", folders: [
            AppCacheFolder(path: home + "/Library/Application Support/Spotify/PersistentCache", label: "Spotify's cache",
                           bytes: 1_900_000_000, knowledgeID: nil),
        ]),
    ]

    static let media: [MediaLocation] = [
        MediaLocation(id: "music.downloads|x", knowledgeID: "music.downloads", name: "Apple Music downloads",
                      path: home + "/Music/Music/Media.localized/Apple Music", bytes: 9_800_000_000, ownBytes: 9_800_000_000,
                      level: .blocked, reason: "Remove downloads in Music so the library stays in step.",
                      kind: .download, regenerates: "Downloaded songs stream again, or download again from your library.",
                      guidance: "In Music, select the songs or albums, then choose Remove Download.", appName: "Music",
                      action: nil, needsFullDiskAccess: false),
        MediaLocation(id: "fcp.render|x", knowledgeID: "video.fcp-render", name: "Final Cut Pro render files",
                      path: home + "/Movies/Final Cut Render Files", bytes: 4_200_000_000, ownBytes: 4_200_000_000,
                      level: .safe, reason: "Final Cut Pro renders them again when needed.",
                      kind: .cache, regenerates: "Final Cut Pro renders them again the next time you play the timeline.",
                      guidance: nil, appName: "Final Cut Pro", action: .remove, needsFullDiskAccess: false),
    ]

    static let report: CleanReport = {
        let done = plan[0...1].map { CleanOutcome(item: $0, error: nil, moves: [TrashMove(from: $0.path, to: home + "/.Trash/x")]) }
        let command = CleanOutcome(item: plan[5], error: nil, note: "Ran npm cache clean --force.")
        let failed = CleanOutcome(item: plan[3], error: "Permission denied. Ballast needs Full Disk Access to clean it.")
        return CleanReport(outcomes: done + [command, failed], freed: 9_750_000_000, movedToTrash: 7_650_000_000, record: nil)
    }()

    static let records: [CleanupRecord] = [
        CleanupRecord(permanent: false, items: [
            .init(name: "User caches", path: home + "/Library/Caches", bytes: 6_400_000_000,
                  moves: [TrashMove(from: "a", to: "b")]),
            .init(name: "node_modules", path: home + "/p/node_modules", bytes: 1_250_000_000, moves: [TrashMove(from: "c", to: "d")]),
        ]),
        CleanupRecord(permanent: true, auto: true, items: [
            .init(name: "target", path: home + "/rust/target", bytes: 3_300_000_000, moves: []),
        ]),
    ]
}

@Suite struct SuggestionsViewTests {
    @Test func groupsNeedsYouFirstThenByKind() {
        let groups = PlanGroup.make(Fake.plan)
        #expect(groups.map(\.kind) == [.needsYou, .caches, .build, .apps])
        let needsYou = groups[0]
        #expect(needsYou.items.map(\.name) == ["Slack: Cache", "Old exports"])
        #expect(needsYou.waiting == 2)
        #expect(groups[1].items.map(\.name) == ["User caches", "npm cache"])
        #expect(groups[1].bytes == 8_500_000_000)
    }

    @Test func tickingACautionItemDoesNotMoveIt() {
        var plan = Fake.plan
        plan[3].included = true
        let groups = PlanGroup.make(plan)
        #expect(groups[0].items.map(\.name) == ["Slack: Cache", "Old exports"])
        #expect(groups[0].waiting == 1)
    }

    @Test func addStateFollowsMembership() {
        #expect(AddState(.none, pending: false) == .add)
        #expect(AddState(.none, pending: true) == .pending)
        #expect(AddState(.partial, pending: true) == .pending)
        #expect(AddState(.all(removable: true), pending: true) == .added)
        #expect(AddState(.all(removable: false), pending: false) == .covered)
    }

    @Test func historyTrashCountsMovesWithoutTheDisk() {
        let trash = HistoryTrash(Fake.records[0])
        #expect(trash.trashed == 2)
        #expect(trash.pending == 0)
        #expect(HistoryTrash(Fake.records[1]).trashed == 0)
    }

    @Test func sectionsKeepEveryCategoryInReadingOrder() {
        let categories = SuggestionSection.allCases.compactMap(\.category)
        #expect(Set(categories) == Set(Ballast.Category.allCases))
        #expect(SuggestionSection.allCases.filter { $0.tier == .comesBack } == [.caches, .artifacts, .appCaches])
    }

    @Test func homeRelativeShortensOnlyTheHomeFolder() {
        #expect(homeRelative(Fake.home + "/Library/Caches") == "~/Library/Caches")
        #expect(homeRelative(Fake.home) == "~")
        #expect(homeRelative(Fake.home + "x/a") == Fake.home + "x/a")
        #expect(homeRelative("/opt/homebrew") == "/opt/homebrew")
    }
}

/// Renders the Suggestions and Cleanup List pieces to PNGs for a visual
/// check. Opt-in: `BALLAST_SNAPSHOTS=/tmp/shots swift test --filter SuggestionsSnapshots`
@MainActor @Suite struct SuggestionsSnapshots {
    nonisolated static let folder = ProcessInfo.processInfo.environment["BALLAST_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderSuggestions() throws {
        let catalog = [
            Fake.result("User caches", Fake.home + "/Library/Caches", 6_400_000_000, .caches, action: .contents),
            Fake.result("npm cache", Fake.home + "/.npm", 2_100_000_000, .caches, action: .command("npm cache clean --force")),
            Fake.result("Xcode DerivedData", Fake.home + "/Library/Developer/Xcode/DerivedData", 11_200_000_000, .caches),
        ]
        let board = VStack(alignment: .leading, spacing: Theme.Space.section) {
            SuggestionsSummary(reclaimable: 19_700_000_000, appCaches: 2_720_000_000, media: 4_200_000_000, canAddAll: true)
            ChartSection(title: "Caches", note: Ballast.Category.caches.advice, total: 19_700_000_000, padded: false) {
                VStack(spacing: 0) {
                    ForEach(Array(catalog.enumerated()), id: \.element.id) { index, result in
                        if index > 0 { Hairline(leading: 34) }
                        SuggestionRow(result: result, largest: 11_200_000_000,
                                      item: Fake.item(result.target.name, result.target.path, result.bytes,
                                                      index == 2 ? .caution("Xcode is building. Check first.") : .safe("Rebuilt automatically when needed.")),
                                      planned: index == 0)
                    }
                }
                .padding(.horizontal, Theme.Space.inset)
            }
            ChartSection(title: "App caches", note: "What each app rebuilds on its own.", total: 2_720_000_000, padded: false) {
                VStack(spacing: 0) {
                    AppCacheRow(breakdown: Fake.appCaches[1], state: .pending, largest: 1_900_000_000)
                    Hairline(leading: 34)
                    AppCacheRow(breakdown: Fake.appCaches[0], state: .add, largest: 1_900_000_000)
                }
                .padding(.horizontal, Theme.Space.inset)
            }
            ChartSection(title: "Music & media", note: "How each one comes back.", total: 14_000_000_000, padded: false) {
                VStack(spacing: 0) {
                    MediaRow(location: Fake.media[0], state: .unavailable, largest: 9_800_000_000)
                    Hairline(leading: 34)
                    MediaRow(location: Fake.media[1], state: .added, largest: 9_800_000_000)
                }
                .padding(.horizontal, Theme.Space.inset)
            }
            ChartSection(title: "App caches", total: nil, padded: false) {
                SectionAllClear(text: "No app keeps a cache worth clearing right now.", action: ("Check Again", {}))
                    .padding(.horizontal, Theme.Space.inset)
            }
            ChartSection(title: "Build files", padded: false) { SkeletonRows(count: 2).padding(.horizontal, Theme.Space.inset) }
            EmptyChart(symbol: "checkmark.seal", title: "Nothing to clean right now",
                       message: "Caches and build files show up here as apps and tools make them. Ballast checks again with every update, about every five minutes while it's open.")
        }
        .padding(Theme.Space.pageX)
        .frame(width: 860)
        .background(Theme.water)
        try render(board, name: "suggestions")
    }

    @Test(.enabled(if: folder != nil)) func renderCleanupList() throws {
        let groups = PlanGroup.make(Fake.plan)
        let list = VStack(alignment: .leading, spacing: Theme.Space.gap + 6) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    PlanGroupHeader(group: group)
                    VStack(spacing: 0) {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Hairline(leading: 36) }
                            PlanRow(item: item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .chartSurface(radius: Theme.Radius.row)
                }
            }
            Button { } label: { Label("Clean Up 10.4 GB", systemImage: "trash.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.inkLarge)
        }
        .padding(14)
        .frame(width: 360)
        .background(Theme.water)

        let working = CleaningProgressContent(title: "Cleaning 2 of 4", current: 1, measuring: false,
                                              items: Array(Fake.plan.filter(\.isReady).prefix(4)), stop: {}, scrolls: false)
            .frame(width: 360, height: 360)
            .background(Theme.water)
        let result = CleanResultView(report: Fake.report, canPutBack: true, putBackReport: nil, scrolls: false)
            .frame(width: 360, height: 760)
            .background(Theme.water)
        let empty = VStack(spacing: 8) {
            EmptyChart(symbol: "tray.and.arrow.down", title: "Drop files or folders here",
                       message: "Or press the plus button next to anything in Explorer, Suggestions or Largest folders.") {
                Button("Choose Files…") {}.buttonStyle(.bordered)
            }
            VerdictLegend().padding(.horizontal, 16)
        }
        .frame(width: 360)
        .background(Theme.water)

        try render(list, name: "cleanup-list")
        try render(working, name: "cleanup-working")
        try render(result, name: "cleanup-result")
        try render(empty, name: "cleanup-empty")
    }

    @Test(.enabled(if: folder != nil)) func renderHistory() throws {
        let board = VStack(spacing: 0) {
            HistoryRow(record: Fake.records[0], trash: HistoryTrash(trashed: 2, pending: 2), putBackReport: nil)
            Hairline(leading: 46)
            HistoryRow(record: Fake.records[1], trash: HistoryTrash(Fake.records[1]),
                       putBackReport: PutBackReport(recordID: Fake.records[1].id, restored: 0,
                                                    problems: ["target is no longer in the Trash."]))
            Hairline(leading: 46)
            HistoryRow(record: Fake.records[0], trash: nil, putBackReport: nil)
        }
        .chartSurface(radius: Theme.Radius.row)
        .padding(24)
        .frame(width: 580)
        .background(Theme.water)
        try render(board, name: "cleanup-history")
    }

    private func render(_ view: some View, name: String) throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try ComponentSnapshots.render(view, name: "\(name)-\(appearance == .aqua ? "light" : "dark")", appearance: appearance)
        }
    }
}
