import AppKit
import SwiftUI
import Testing
@testable import Ballast

/// Renders the Overview track's pieces with fake figures, light and dark,
/// for a visual check. Opt-in like ComponentSnapshots:
/// `BALLAST_SNAPSHOTS=/tmp/shots swift test --filter OverviewSnapshots`
/// Liquid Glass and native controls may not render; layout and colour do.
@MainActor @Suite struct OverviewSnapshots {
    static let total: Int64 = 994_000_000_000
    static let segments: [DepthBar.Segment] = [
        .init(category: .applications, bytes: 92_000_000_000),
        .init(category: .yourFiles, bytes: 310_000_000_000),
        .init(category: .caches, bytes: 48_000_000_000),
        .init(category: .build, bytes: 71_000_000_000),
        .init(category: .system, bytes: 118_000_000_000),
        .init(category: .trash, bytes: 26_000_000_000),
    ]
    static var free: Int64 { total - segments.reduce(0) { $0 + $1.bytes } }

    @Test(.enabled(if: ComponentSnapshots.folder != nil)) func renderOverview() throws {
        let page = VStack(alignment: .leading, spacing: Theme.Space.section) {
            VStack(alignment: .leading, spacing: 22) {
                StorageHeader(name: "Macintosh HD", detail: "\((Self.total - Self.free).bytes) of \(Self.total.bytes) used",
                              free: Self.free, total: Self.total, segments: Self.segments, systemData: {})
                .background(alignment: .top) { HeaderContours() }
                CleanablePanel(bytes: 18_400_000_000, trash: 26_000_000_000, review: {}, emptyTrash: {})
            }

            VStack(alignment: .leading, spacing: Theme.Space.gap) {
                QuietNotice(symbol: "hand.raised", title: "14 folders are hidden by macOS privacy settings.",
                            detail: "Allow Full Disk Access, then reopen Ballast.") {
                    Button("Open Settings") {}
                }
                QuietNotice(symbol: "lock", title: "3 system folders need an administrator to measure.",
                            detail: "Ballast asks for your password once and reads only these.") {
                    Button("Scan as Admin…") {}
                }
            }
            .buttonStyle(.bordered)

            Self.folders
            ChartSection(title: "What grew", note: "Since Nov 4, 9:12 AM") {
                ChartNote(symbol: "calendar", text: "Ballast needs a few days of history to show what grew.")
            }
        }
        .frame(width: Theme.Space.contentMax)
        .padding(.horizontal, Theme.Space.pageX)
        .padding(.vertical, Theme.Space.section)
        .background(Theme.water)
        try Self.both(page, name: "overview")
    }

    @Test(.enabled(if: ComponentSnapshots.folder != nil)) func renderNarrowAndLow() throws {
        let low: [DepthBar.Segment] = [
            .init(category: .applications, bytes: 60_000_000_000),
            .init(category: .yourFiles, bytes: 340_000_000_000),
            .init(category: .caches, bytes: 30_000_000_000),
            .init(category: .system, bytes: 60_000_000_000),
        ]
        let page = VStack(alignment: .leading, spacing: 22) {
            StorageHeader(name: "Macintosh HD", detail: "490 GB of 494 GB used", free: 4_000_000_000,
                          total: 494_000_000_000, segments: low, isLow: true, systemData: {})
            CleanablePanel(bytes: 0, review: {})
            CleanablePanel(bytes: 18_400_000_000, trash: 26_000_000_000, review: {}, emptyTrash: {})
            Self.folders
        }
        .frame(width: 420)
        .padding(20)
        .background(Theme.water)
        try Self.both(page, name: "overview-narrow-low")
    }

    @Test(.enabled(if: ComponentSnapshots.folder != nil)) func renderMenuAndStates() throws {
        let board = HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                MenuSummary(free: Self.free, total: Self.total, volume: "Macintosh HD", segments: Self.segments,
                            reclaimable: 18_400_000_000, grewToday: 2_100_000_000, isLow: false) {
                    Text("Updated 4 minutes ago")
                }
                Button {} label: { Text("Review Cleanup").frame(maxWidth: .infinity) }
                    .buttonStyle(.ink)
            }
            .frame(width: 272)
            .padding(14)
            VStack(alignment: .leading, spacing: 24) {
                DepthBar(segments: Self.segments, free: Self.free, total: Self.total, height: 44)
                FlowLayout(spacing: 14) {
                    ForEach(DepthBar.Category.allCases, id: \.self) { category in
                        HStack(spacing: 6) {
                            DepthSwatch(category: category).frame(width: 14, height: 14)
                            Text(category.title).font(.callout)
                        }
                    }
                }
                OverviewSkeleton().frame(height: 640)
            }
            .frame(width: 560)
        }
        .padding(24)
        .background(Theme.water)
        try Self.both(board, name: "overview-menu-states")
    }

    /// The panel alone at full width, and the row controls on their own,
    /// to tell renderer limits from layout faults.
    @Test(.enabled(if: ComponentSnapshots.folder != nil)) func renderPanelAndControls() throws {
        let board = VStack(alignment: .leading, spacing: 24) {
            CleanablePanel(bytes: 18_400_000_000, trash: 26_000_000_000, review: {}, emptyTrash: {})
            CleanablePanel(bytes: 18_400_000_000, review: {})
            HStack(spacing: 24) {
                WhatIsThisButton(path: "/Users/me/Library/Caches", level: .safe)
                Button {} label: { Image(systemName: "plus.circle") }.buttonStyle(.plain)
                Button {} label: { Image(systemName: "plus.circle") }.buttonStyle(.plain).help("Add")
                Image(systemName: "plus.circle").symbolEffect(.bounce, value: false)
                Button {} label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
            }
        }
        .frame(width: Theme.Space.contentMax)
        .padding(24)
        .background(Theme.water)
        try Self.both(board, name: "overview-panel-controls")
    }

    /// The other-drive states, the row variants (growth, a file with its
    /// icon), the notes with and without an action, and the history chart.
    @Test(.enabled(if: ComponentSnapshots.folder != nil)) func renderDiskRowsAndHistory() throws {
        let board = VStack(alignment: .leading, spacing: Theme.Space.section) {
            Self.diskHeaders
            Self.rowVariants
            HistorySection(points: Self.historyPoints)
            Self.stalledIndex
        }
        .frame(width: Theme.Space.contentMax)
        .padding(.horizontal, Theme.Space.pageX)
        .padding(.vertical, Theme.Space.section)
        .background(Theme.water)
        try Self.both(board, name: "overview-disk-rows-history")
    }

    static var historyPoints: [HistoryPoint] {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var points: [HistoryPoint] = []
        for day in 0..<8 {
            let freed: Int64? = day == 5 ? 40_000_000_000 : nil
            let free: Int64 = 300_000_000_000 - Int64(day) * 9_000_000_000 + (freed ?? 0)
            points.append(HistoryPoint(date: start.addingTimeInterval(Double(day) * 86_400), free: free, freed: freed))
        }
        return points
    }

    static var diskHeaders: some View {
        let segments = AppModel.diskSegments(used: 820_000_000_000, folders: 700_000_000_000, builds: 42_000_000_000)
        return VStack(alignment: .leading, spacing: Theme.Space.section) {
            StorageHeader(name: "Archive", detail: "2 TB · ExFAT · not connected", free: nil,
                          total: 2_000_000_000_000, segments: [])
            StorageHeader(name: "Studio SSD", detail: "820 GB of 1 TB used · APFS", free: 180_000_000_000,
                          total: 1_000_000_000_000, segments: segments, systemNote: "Not in folders")
            QuietNotice(symbol: "externaldrive.badge.xmark", title: "Not connected",
                        detail: "Last scanned 3 days ago. Connect it to update the index, or forget it.") {
                Button("Forget…") {}
            }
            .buttonStyle(.bordered)
        }
    }

    static var rowVariants: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            ChartSection(title: "What grew", note: "Since Nov 4, 9:12 AM · 3.2 GB freed", padded: false) {
                VStack(spacing: 0) {
                    growthRow
                    fileRow
                }
                .padding(6)
            }
            ChartSection(title: "Largest files", padded: false) {
                VStack(spacing: 0) {
                    ChartNote(symbol: "doc.text.magnifyingglass", text: "Largest files appear after the next full scan.",
                              action: ("Full Rescan", {}))
                    ChartNote(symbol: "checkmark.circle", text: "No file is 1 GB or more.")
                }
                .padding(6)
            }
        }
    }

    static var growthRow: some View {
        ChartRow(name: "Caches", path: "/Users/me/Library/Caches", level: .safe, add: .ready(isOn: false),
                 action: {}, toggle: {}) {
            ChartRowText(name: "Caches", detail: "~/Library", fraction: 1, bytes: 6_400_000_000, sign: "+")
        } menu: {
            EmptyView()
        }
    }

    static var fileRow: some View {
        ChartRow(name: "Movie.mov", path: "/Users/me/Movies/Movie.mov", level: .caution, add: .ready(isOn: true),
                 showsChevron: false, action: {}, toggle: {}) {
            ChartRowText(name: "Movie.mov", detail: "~/Movies · 2 weeks ago", fraction: 0.4, bytes: 2_600_000_000) {
                Image(systemName: "film").frame(width: 22, height: 22)
            }
        } menu: {
            EmptyView()
        }
    }

    static var stalledIndex: some View {
        EmptyChart(symbol: "externaldrive.badge.questionmark", title: "The index of Archive hasn't opened",
                   message: "A large drive can take a while. If its folders don't appear, scan the drive again to rebuild the index. Nothing on the drive is changed.") {
            Button("Scan Again") {}.buttonStyle(.bordered)
        }
    }

    /// Rows in each add state, with a long name and a growth row.
    static var folders: some View {
        ChartSection(title: "Largest folders", note: "Where the space sits: no folder inside holds most of it.",
                     padded: false) {
            VStack(spacing: 0) {
                row("DerivedData", "~/Library/Developer/Xcode", 64_000_000_000, 1, .ready(isOn: true), .safe)
                row("node_modules", "~/projects/a-very-long-project-name/packages/web-client", 21_500_000_000,
                    0.34, .ready(isOn: false), .caution)
                row("Photos Library.photoslibrary", "~/Pictures", 9_800_000_000, 0.15, .unavailable, .blocked)
                row("Simulator devices", "~/Library/Developer/CoreSimulator", 512_000_000, 0.01, .pending, nil)
            }
            .padding(6)
        }
    }

    static func row(_ name: String, _ detail: String, _ bytes: Int64, _ fraction: Double, _ add: AddState,
                    _ level: Safety.Level?) -> some View {
        ChartRow(name: name, path: "/Users/me/" + name, level: level, add: add, action: {}, toggle: {}) {
            ChartRowText(name: name, detail: detail, fraction: fraction, bytes: bytes)
        } menu: {
            EmptyView()
        }
    }

    static func both(_ view: some View, name: String) throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try ComponentSnapshots.render(view, name: "\(name)-\(appearance == .aqua ? "light" : "dark")",
                                          appearance: appearance)
        }
    }
}
