import AppKit
import SwiftUI

/// Suggestion sections in reading order: what comes back on its own
/// first, then what needs a look before it goes.
enum SuggestionSection: String, CaseIterable, Hashable, Identifiable {
    case caches, artifacts, appCaches, media, installers, stale, duplicates, unusedApps, developer, appData, personal

    var id: Self { self }

    enum Tier: CaseIterable {
        case comesBack, needsLook

        var title: String {
            switch self {
            case .comesBack: "Comes back on its own"
            case .needsLook: "Look before you clean"
            }
        }

        var note: String {
            switch self {
            case .comesBack: "Caches and build files that apps and tools make again when they need them."
            case .needsLook: "Downloads, media, old folders and apps: they don't come back by themselves."
            }
        }
    }

    var tier: Tier {
        switch self {
        case .caches, .artifacts, .appCaches: .comesBack
        default: .needsLook
        }
    }

    /// The catalog category behind a section, for the index's suggestions.
    var category: Category? {
        switch self {
        case .caches: .caches
        case .artifacts: .artifacts
        case .stale: .stale
        case .developer: .developer
        case .appData: .appData
        case .personal: .personal
        case .appCaches, .media, .installers, .duplicates, .unusedApps: nil
        }
    }

    func title(staleMonths: Int) -> String {
        switch self {
        case .caches: "Caches"
        case .artifacts: "Build files"
        case .appCaches: "App caches"
        case .media: "Music & media"
        case .installers: "Installers & Disk Images"
        case .stale: Category.stale.title(staleMonths: staleMonths)
        case .duplicates: "Duplicate Files"
        case .unusedApps: "Unused Apps"
        case .developer: "Developer Tools"
        case .appData: "App Data"
        case .personal: "Personal Files"
        }
    }

    /// Counted once per run when a section scrolls in; the newer sections
    /// have no usage-data token yet.
    var telemetryID: SuggestionSectionID? {
        switch self {
        case .installers: .installers
        case .duplicates: .duplicates
        case .unusedApps: .unusedApps
        case .appCaches, .media: nil
        default: category.map(SuggestionSectionID.init)
        }
    }
}

/// Suggestions: known caches, build files, every app's own caches, music
/// and media, installers, big untouched folders and unused apps, each one
/// click away from the Cleanup List and each with what it is.
struct CleanupView: View {
    let model: AppModel
    let explore: (String) -> Void

    /// Nil shows every section.
    @State private var filter: SuggestionSection?
    /// Long sections showing every row.
    @State private var expanded: Set<SuggestionSection> = []
    /// Build folders grouped by kind, largest first: worked out when the
    /// suggestions change, not on every redraw.
    @State private var artifactGroups: [ArtifactGroup] = []
    /// What the knowledge base says about the listed places, by path.
    @State private var explanations: [String: KnowledgeExplanation] = [:]
    /// App caches and media locations being checked before they land on
    /// the list (`addToPlan` assesses off the main thread).
    @State private var adding: Set<String> = []
    /// How much of each app cache and media location is on the list.
    @State private var membership: [String: PlanMembership] = [:]
    @Environment(\.openSettings) private var openSettings

    /// Rows a long section shows before "Show All".
    private static let shortList = 8

    var body: some View {
        let key = SuggestionsKey(totals: model.groupTotals, count: model.cleanup.count)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                SuggestionsSummary(reclaimable: model.reclaimable, appCaches: model.appCachesUncoveredBytes,
                                   media: model.mediaUncoveredBytes, canAddAll: model.hasUnplannedSafeSuggestions,
                                   loading: model.isLoadingSuggestions) {
                    Motion.with(Motion.feedback) { model.addAllSafeSuggestions() }
                }
                ForEach(SuggestionSection.Tier.allCases, id: \.self) { tier in
                    tierView(tier)
                }
            }
            .frame(maxWidth: Theme.Space.contentMax, alignment: .leading)
            .padding(.horizontal, Theme.Space.pageX)
            .padding(.top, 20)
            .padding(.bottom, Theme.Space.section)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .onChange(of: key, initial: true) { regroup() }
        .task(id: key) {
            let paths = model.cleanup.filter { $0.target.category != .artifacts }.map(\.target.path)
            let found = await Knowledge.explainAsync(paths: paths)
            guard !Task.isCancelled else { return }
            explanations = found
        }
        .onChange(of: MembershipKey(planned: model.plannedPaths, appCaches: model.appCaches, media: model.media),
                  initial: true) { updateMembership() }
        .onChange(of: model.refusal?.id) { adding.removeAll() }
    }

    // MARK: Filter

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $filter) {
                Text("All Suggestions").tag(nil as SuggestionSection?)
                Divider()
                ForEach(SuggestionSection.allCases) { section in
                    Text(section.title(staleMonths: model.preferences.staleMonths)).tag(section as SuggestionSection?)
                }
            }
            .pickerStyle(.menu)
            .menuStyle(.borderlessButton)
            .fixedSize()
            if filter != nil {
                Button("Show All", systemImage: "xmark.circle.fill") {
                    Motion.with(Motion.layout) { filter = nil }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Show every section")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .chartCapsule(interactive: false)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .animation(Motion.animation(Motion.layout), value: filter)
    }

    // MARK: Tiers

    @ViewBuilder
    private func tierView(_ tier: SuggestionSection.Tier) -> some View {
        let sections = SuggestionSection.allCases.filter { $0.tier == tier && (filter == nil || filter == $0) }
        if !sections.isEmpty {
            let shown = sections.filter { isShown($0) }
            VStack(alignment: .leading, spacing: Theme.Space.gap + 12) {
                if filter == nil {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tier.title).font(.title2.weight(.semibold))
                        Text(tier.note).foregroundStyle(.secondary)
                    }
                    .accessibilityAddTraits(.isHeader)
                }
                if shown.isEmpty {
                    tierAllClear(tier, single: filter)
                } else {
                    ForEach(shown) { section in
                        sectionView(section)
                            .onAppear { if let id = section.telemetryID { model.noteSectionViewed(id) } }
                            .transition(.row)
                    }
                }
            }
            .animation(Motion.animation(Motion.layout), value: shown)
        }
    }

    @ViewBuilder
    private func tierAllClear(_ tier: SuggestionSection.Tier, single: SuggestionSection?) -> some View {
        if let single {
            EmptyChart(symbol: "checkmark.seal", title: "Nothing in \(single.title(staleMonths: model.preferences.staleMonths)) right now",
                       message: "Ballast checks again with every update, about every five minutes while it's open.") {
                Button("Show All Suggestions") { Motion.with(Motion.layout) { filter = nil } }
                    .buttonStyle(.bordered)
            }
        } else if tier == .comesBack {
            EmptyChart(symbol: "checkmark.seal", title: "Nothing to clean right now",
                       message: "Caches and build files show up here as apps and tools make them. Ballast checks again with every update, about every five minutes while it's open.")
        } else {
            EmptyChart(symbol: "checkmark.seal", title: "Nothing to look at right now",
                       message: "No big installers, untouched folders or unused apps. Ballast checks again with every update.")
        }
    }

    /// Whether a section has something to show (rows, loading, or the
    /// result of a check worth saying out loud).
    private func isShown(_ section: SuggestionSection) -> Bool {
        switch section {
        case .artifacts: !artifactGroups.isEmpty || model.isLoadingSuggestions
        case .appCaches: model.appCaches != nil || model.isLoadingAppCaches
        case .media: model.media.map { !$0.isEmpty } ?? model.isLoadingMedia
        case .installers: !model.installers.isEmpty
        case .unusedApps: !model.unusedApps.isEmpty
        case .duplicates: true
        default:
            section.category.map { !model.cleanup(in: $0).isEmpty } ?? false
                || (section == .caches && model.isLoadingSuggestions)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: SuggestionSection) -> some View {
        switch section {
        case .artifacts: artifactsSection
        case .appCaches: appCachesSection
        case .media: mediaSection
        case .installers: installersSection
        case .unusedApps: unusedAppsSection
        case .duplicates:
            // Explorer's section, still shaped as a List section.
            VStack(alignment: .leading, spacing: 10) { DuplicatesSection(model: model) }
                .padding(.horizontal, 4)
        default:
            if let category = section.category { categorySection(section, category) }
        }
    }

    // MARK: Catalog sections

    private func categorySection(_ section: SuggestionSection, _ category: Category) -> some View {
        let rows = model.cleanup(in: category)
        return ChartSection(title: section.title(staleMonths: model.preferences.staleMonths), note: category.advice,
                            total: model.total(in: category), padded: false) {
            EmptyView()
        } content: {
            if rows.isEmpty && model.isLoadingSuggestions {
                SkeletonRows(count: 4).padding(.horizontal, Theme.Space.inset)
            } else {
                rowList(section, rows) { result in
                    SuggestionRow(result: result, largest: rows.first?.bytes ?? 0,
                                  item: model.listItem(for: result), planned: model.isPlanned(result.target.path),
                                  explanation: explanations[result.target.path], showsAge: category == .stale,
                                  toggle: { Motion.with(Motion.feedback) { model.toggle(result) } },
                                  explore: { explore(result.target.path) })
                }
            }
        }
    }

    private var artifactsSection: some View {
        ChartSection(title: SuggestionSection.artifacts.title(staleMonths: model.preferences.staleMonths),
                     note: Category.artifacts.advice, total: model.total(in: .artifacts), padded: false) {
            if !artifactGroups.isEmpty {
                Button("Add Ones Older Than 3 Months") {
                    Motion.with(Motion.feedback) { addArtifacts(olderThan: 90) }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.sea)
                .help("Add build folders whose project hasn't changed in 3 months")
            }
        } content: {
            if artifactGroups.isEmpty {
                SkeletonRows(count: 3).padding(.horizontal, Theme.Space.inset)
            } else {
                let largest = artifactGroups.first?.bytes ?? 0
                VStack(spacing: 0) {
                    ForEach(Array(artifactGroups.enumerated()), id: \.element.id) { index, group in
                        VStack(spacing: 0) {
                            if index > 0 { Hairline(leading: 46) }
                            kindGroup(group, largest: largest)
                        }
                        .transition(.row)
                    }
                }
                .padding(.horizontal, Theme.Space.inset)
            }
        }
    }

    private func kindGroup(_ group: ArtifactGroup, largest: Int64) -> some View {
        let rule = model.autoClean.rule(for: group.kind)
        return KindGroupRow(
            kind: group.kind, count: group.rows.count, bytes: group.bytes, largest: largest,
            ruleTitle: rule.enabled ? "Auto: after \(rule.days) day\(rule.days == 1 ? "" : "s")" : "Auto-clean…",
            ruleHelp: rule.enabled ? "Change this rule in Settings" : "Clean these automatically when a project goes unused",
            openRule: {
                SettingsTab.select(.autoClean)
                openSettings()
            },
            addAll: {
                Motion.with(Motion.feedback) {
                    for result in group.rows where !model.isPlannedOrCovered(result.target.path) {
                        if let item = model.listItem(for: result), item.safety.level != .blocked { model.toggle(item) }
                    }
                }
            }
        ) {
            ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, result in
                VStack(spacing: 0) {
                    Hairline(leading: 34)
                    SuggestionRow(result: result, largest: group.rows.first?.bytes ?? 0,
                                  item: model.listItem(for: result), planned: model.isPlanned(result.target.path),
                                  toggle: { Motion.with(Motion.feedback) { model.toggle(result) } },
                                  explore: { explore(result.target.path) })
                }
                .transition(.row)
            }
        }
    }

    // MARK: App caches

    private var appCachesSection: some View {
        let caches = model.appCaches
        return ChartSection(title: "App caches",
                            note: "What each app rebuilds on its own. Folders already counted under Caches are left out of this total.",
                            total: model.appCachesUncoveredBytes, padded: false) {
            EmptyView()
        } content: {
            if let caches, !caches.isEmpty {
                rowList(.appCaches, caches) { breakdown in
                    AppCacheRow(breakdown: breakdown, state: state(for: breakdown.id), largest: caches.first?.bytes ?? 0) {
                        toggleAppCache(breakdown)
                    }
                }
            } else if caches == nil || model.isLoadingAppCaches {
                SkeletonRows(count: 4).padding(.horizontal, Theme.Space.inset)
            } else {
                SectionAllClear(text: "No app keeps a cache worth clearing right now.",
                                action: ("Check Again", { Task { await model.loadAppCaches() } }))
                    .padding(.horizontal, Theme.Space.inset)
            }
        }
    }

    private func toggleAppCache(_ breakdown: AppCacheBreakdown) {
        switch membership[breakdown.id] ?? .none {
        case .all(removable: true):
            Motion.with(Motion.exit) { model.removeFromPlan(paths: breakdown.folders.map(\.path)) }
        case .all(removable: false):
            break
        case .none, .partial:
            beginAdding(breakdown.id) { model.addToPlan(breakdown) }
        }
    }

    // MARK: Music & media

    private var mediaSection: some View {
        let locations = model.media
        return ChartSection(title: "Music & media",
                            note: "Downloads, caches and libraries of music, video and photo apps, and how each one comes back.",
                            total: model.mediaUncoveredBytes, padded: false) {
            EmptyView()
        } content: {
            if let locations, !locations.isEmpty {
                rowList(.media, locations) { location in
                    MediaRow(location: location, state: location.canAddToPlan ? state(for: location.id) : .unavailable,
                             largest: locations.first?.ownBytes ?? 0,
                             add: { toggleMedia(location) },
                             reveal: { Finder.reveal(location.path) },
                             openApp: { location.appName.map { AppOpener.open($0, fallback: location.path) } })
                }
            } else {
                SkeletonRows(count: 3).padding(.horizontal, Theme.Space.inset)
            }
        }
    }

    private func toggleMedia(_ location: MediaLocation) {
        switch membership[location.id] ?? .none {
        case .all(removable: true):
            Motion.with(Motion.exit) { model.removeFromPlan(paths: [location.path]) }
        case .all(removable: false):
            break
        case .none, .partial:
            beginAdding(location.id) { model.addToPlan(location) }
        }
    }

    // MARK: Installers & apps

    private var installersSection: some View {
        let rows = model.installers
        return ChartSection(title: SuggestionSection.installers.title(staleMonths: 0),
                            note: "You can download them again if you need them.",
                            total: rows.reduce(0) { $0 + $1.bytes }, padded: false) {
            Button("Add All") {
                Motion.with(Motion.feedback) {
                    for installer in rows where installer.mountedAs == nil && !model.isPlanned(installer.path) {
                        model.toggle(model.listItem(for: installer))
                    }
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.sea)
            .help("Add every installer and disk image that isn't mounted")
        } content: {
            rowList(.installers, rows) { installer in
                InstallerRow(installer: installer, largest: rows.first?.bytes ?? 0,
                             item: model.listItem(for: installer), planned: model.isPlanned(installer.path),
                             toggle: { Motion.with(Motion.feedback) { model.toggle(model.listItem(for: installer)) } },
                             eject: { Task { await model.eject(installer) } })
            }
        }
    }

    private var unusedAppsSection: some View {
        let rows = model.unusedApps
        return ChartSection(title: SuggestionSection.unusedApps.title(staleMonths: 0),
                            note: "Not opened for \(staleSpan). Uninstalling moves the app and its data to the Trash.",
                            total: rows.reduce(0) { $0 + $1.bytes }, padded: false) {
            rowList(.unusedApps, rows) { unused in
                UnusedAppRow(unused: unused, largest: rows.first?.bytes ?? 0,
                             item: model.listItem(for: unused), planned: model.isPlanned(unused.app.path),
                             staleSpan: staleSpan,
                             toggle: { Motion.with(Motion.feedback) { model.toggle(model.listItem(for: unused)) } })
            }
        }
    }

    /// "6+ months", "1+ year": the stale threshold from Settings.
    private var staleSpan: String {
        let months = model.preferences.staleMonths
        guard months % 12 == 0 else { return "\(months)+ months" }
        return "\(months / 12)+ year\(months == 12 ? "" : "s")"
    }

    // MARK: Rows

    /// A section's rows with hairlines between them, the first few only
    /// until "Show All".
    private func rowList<Data: RandomAccessCollection, Row: View>(
        _ section: SuggestionSection, _ data: Data, @ViewBuilder row: @escaping (Data.Element) -> Row
    ) -> some View where Data.Element: Identifiable, Data.Index == Int {
        let showsAll = expanded.contains(section) || data.count <= Self.shortList + 2
        let shown = showsAll ? Array(data) : Array(data.prefix(Self.shortList))
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, element in
                VStack(spacing: 0) {
                    if index > 0 { Hairline(leading: 34) }
                    row(element)
                }
                .transition(.row)
            }
            if data.count > Self.shortList + 2 {
                Hairline(leading: 34)
                ShowMoreButton(total: data.count, expanded: showsAll) {
                    Motion.with(showsAll ? Motion.exit : Motion.layout) {
                        if showsAll { expanded.remove(section) } else { expanded.insert(section) }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.inset)
    }

    // MARK: Adding

    private func state(for id: String) -> AddState {
        AddState(membership[id] ?? .none, pending: adding.contains(id))
    }

    /// Shows the row as being checked right away; it settles when the
    /// list changes, an add is refused, or after a few seconds at most.
    private func beginAdding(_ id: String, _ add: () -> Void) {
        Motion.with(Motion.feedback) { _ = adding.insert(id) }
        add()
        Task {
            try? await Task.sleep(for: .seconds(4))
            adding.remove(id)
        }
    }

    private func updateMembership() {
        var next: [String: PlanMembership] = [:]
        for breakdown in model.appCaches ?? [] { next[breakdown.id] = model.membership(of: breakdown) }
        for location in model.media ?? [] { next[location.id] = model.membership(of: location) }
        if next != membership { Motion.with(Motion.feedback) { membership = next } }
        let settled = adding.filter { next[$0].map { $0 != .none } ?? true }
        if !settled.isEmpty { adding.subtract(settled) }
    }

    // MARK: Build files

    private func regroup() {
        let rows = model.cleanup(in: .artifacts)
        let next = Dictionary(grouping: rows.filter { $0.kind != nil }, by: { $0.kind! })
            .map { ArtifactGroup(kind: $0.key, rows: $0.value) }
            .sorted { $0.bytes > $1.bytes }
        if artifactGroups.isEmpty {
            artifactGroups = next
        } else {
            Motion.with(Motion.layout) { artifactGroups = next }
        }
    }

    private func addArtifacts(olderThan days: Double) {
        let cutoff = Int64(Date.now.addingTimeInterval(-days * 86_400).timeIntervalSince1970)
        for result in model.cleanup(in: .artifacts) where result.newest < cutoff && !model.isPlannedOrCovered(result.target.path) {
            model.toggle(result)
        }
    }
}

/// One kind of build folder and its folders, largest first.
struct ArtifactGroup: Identifiable {
    let kind: ArtifactKind
    let rows: [ScanResult]
    let bytes: Int64
    var id: ArtifactKind { kind }

    init(kind: ArtifactKind, rows: [ScanResult]) {
        self.kind = kind
        self.rows = rows
        bytes = rows.reduce(0) { $0 + $1.bytes }
    }
}

/// Changes when the index's suggestions do.
private struct SuggestionsKey: Equatable {
    let totals: [Category: Int64]
    let count: Int
}

private struct MembershipKey: Equatable {
    let planned: Set<String>
    let appCaches: [AppCacheBreakdown]?
    let media: [MediaLocation]?
}
