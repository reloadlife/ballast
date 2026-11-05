import SwiftUI

// The Homebrew screen's pieces. Each takes plain values (figures worked out
// once in the screen, not in a body), so the snapshot tests render them.

// MARK: Extras figures

/// What `brew autoremove` and `brew cleanup` would remove, worked out once
/// from the model's dry-run previews whenever they change.
struct HomebrewExtrasFigures: Equatable, Sendable {
    struct Item: Equatable, Sendable, Identifiable {
        let path: String
        let bytes: Int64?
        var id: String { path }
    }

    /// Nil until known (a saved copy or brew), [] when there are none.
    var orphans: [String]?
    /// `brew cleanup`: old versions plus outdated downloads. Nil until known.
    var cleanupBytes: Int64?
    /// `brew cleanup -s --prune=all`: the same plus every cached download.
    var fullBytes: Int64?
    var oldVersionCount = 0
    var downloadCount = 0
    /// The largest items the full cleanup removes, for "What's removed".
    var largest: [Item] = []

    /// Every byte the strongest cleanup frees.
    var reclaimable: Int64 { max(fullBytes ?? 0, cleanupBytes ?? 0) }
    /// What the downloads add on top of the old versions.
    var downloadBytes: Int64 { max((fullBytes ?? 0) - (cleanupBytes ?? 0), 0) }
    var isKnown: Bool { orphans != nil || cleanupBytes != nil }
    var isClear: Bool { (orphans?.isEmpty ?? false) && reclaimable == 0 && cleanupBytes != nil }

    init() {}

    init(orphans: [String]?, oldVersions: HomebrewCleanupPreview?, fullCleanup: HomebrewCleanupPreview?, prefix: String) {
        self.orphans = orphans
        cleanupBytes = oldVersions?.bytes
        fullBytes = fullCleanup?.bytes ?? oldVersions?.bytes
        let preview = fullCleanup ?? oldVersions
        let items = preview?.items ?? []
        oldVersionCount = items.count { $0.isOldVersion(prefix: prefix) }
        downloadCount = items.count - oldVersionCount
        largest = items
            .sorted { ($0.bytes ?? -1, $1.path) > ($1.bytes ?? -1, $0.path) }
            .prefix(40)
            .map { Item(path: $0.path, bytes: $0.bytes) }
    }
}

/// What the extras are doing right now (cheap to build in a body).
struct HomebrewExtrasActivity: Equatable, Sendable {
    var checkedAt: Date?
    var isLoadingOrphans = false
    var isLoadingCleanup = false
    var isRemovingOrphans = false
    var isCleaningUp = false
    var activity: String?
    var canCancel = false

    var isChecking: Bool { isLoadingOrphans || isLoadingCleanup }
    var isChanging: Bool { isRemovingOrphans || isCleaningUp }
}

// MARK: Extras panel

/// The Homebrew screen's callout, floating on glass like the Overview's
/// "can be cleaned safely": how much brew can free, from old versions,
/// downloads and dependencies nothing needs, with the screen's one ink
/// plate (Clean Up…). Shows the saved figures at once and says when brew
/// last confirmed them.
struct HomebrewExtrasPanel: View {
    let figures: HomebrewExtrasFigures
    let state: HomebrewExtrasActivity
    var refresh: () -> Void = {}
    var cancel: () -> Void = {}
    var cleanUp: () -> Void = {}
    var removeOrphans: () -> Void = {}
    @State private var showsItems = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.gap) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(figures.isClear ? "Homebrew has nothing to clean up" : "Homebrew can free")
                        .font(.headline)
                    Text("Old versions and downloads brew keeps, and dependencies nothing needs. Packages you use stay.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if figures.cleanupBytes != nil {
                    Sounding(bytes: figures.reclaimable, font: Theme.hero(30))
                        .accessibilityLabel("Can free \(figures.reclaimable.bytes)")
                } else if state.isLoadingCleanup {
                    Capsule().fill(Theme.depth[0]).frame(width: 110, height: 26).loadingShimmer(true)
                        .accessibilityLabel("Measuring")
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ExtrasLine(symbol: "clock.arrow.circlepath", title: "Old versions",
                           detail: figures.cleanupBytes == nil ? nil
                               : figures.oldVersionCount == 0 ? "No older versions kept"
                               : "\(figures.oldVersionCount) older \(figures.oldVersionCount == 1 ? "version" : "versions") of installed packages",
                           bytes: figures.cleanupBytes, isLoading: state.isLoadingCleanup)
                ChartHairline()
                ExtrasLine(symbol: "arrow.down.circle", title: "Downloads",
                           detail: figures.fullBytes == nil ? nil
                               : figures.downloadCount == 0 ? "Homebrew's download cache is empty"
                               : "\(figures.downloadCount) cached \(figures.downloadCount == 1 ? "download" : "downloads"); brew fetches them again if needed",
                           bytes: figures.fullBytes == nil ? nil : figures.downloadBytes, isLoading: state.isLoadingCleanup)
                ChartHairline()
                ExtrasLine(symbol: "shippingbox", title: "Unneeded dependencies",
                           detail: orphanDetail, bytes: nil, isLoading: state.isLoadingOrphans && figures.orphans == nil) {
                    if let orphans = figures.orphans, !orphans.isEmpty {
                        Button("Remove…", action: removeOrphans)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(state.isChanging)
                            .help("Uninstall the formulae nothing installed needs (brew autoremove)")
                    }
                }
            }

            if !figures.largest.isEmpty {
                DisclosureGroup("What's removed", isExpanded: $showsItems) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(figures.largest) { item in
                            HStack(spacing: 6) {
                                Text(Paths.display(item.path))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                WhatIsThisButton(path: item.path)
                                Spacer(minLength: 8)
                                if let bytes = item.bytes {
                                    Sounding(bytes: bytes, font: Theme.soundingSmall, style: AnyShapeStyle(.secondary))
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
            }

            ChartHairline()
            footer
        }
        .padding(Theme.Space.inset + 4)
        .chartGlass()
        .animation(Motion.animation(Motion.state), value: figures)
        .animation(Motion.animation(Motion.state), value: state)
        .accessibilityElement(children: .contain)
    }

    private var orphanDetail: String? {
        guard let orphans = figures.orphans else { return nil }
        guard !orphans.isEmpty else { return "Every dependency is still needed" }
        let names = orphans.prefix(3).joined(separator: ", ") + (orphans.count > 3 ? " and \(orphans.count - 3) more" : "")
        return "\(orphans.count) installed only for packages that are gone: \(names)"
    }

    @ViewBuilder private var footer: some View {
        if let activity = state.activity {
            ToolActivityLine(activity: activity, canCancel: state.canCancel, cancel: cancel)
        } else {
            if state.isChecking {
                DepthProgress(fraction: nil)
            }
            HStack(alignment: .center, spacing: 12) {
                checkedNote
                Spacer(minLength: 8)
                if state.isChecking {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.borderless)
                        .help("Stop asking Homebrew; the figures shown stay")
                } else {
                    Button("Refresh", action: refresh)
                        .buttonStyle(.borderless)
                        .help("Ask Homebrew again (a dry run; nothing is removed)")
                }
                Button("Clean Up…", action: cleanUp)
                    .buttonStyle(.ink)
                    .disabled(figures.reclaimable == 0 || state.isChanging)
                    .help(figures.reclaimable == 0 ? "Nothing to remove right now" : "Choose what brew cleanup removes")
            }
        }
    }

    private var checkedNote: some View {
        HStack(spacing: 8) {
            if state.isChecking {
                Text(figures.isKnown ? "Saved figures; checking with Homebrew…" : "Asking Homebrew (a dry run)…")
            } else if let date = state.checkedAt {
                TimelineView(.everyMinute) { _ in
                    Text("Checked \(date.formatted(.relative(presentation: .named)))")
                }
            } else if figures.isKnown {
                Text("From an earlier check")
            } else {
                Text("Not checked yet")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// One line of the extras panel: what it is, a plain detail, its size at
/// the trailing edge (or a placeholder while brew is asked).
private struct ExtrasLine<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String?
    let bytes: Int64?
    let isLoading: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.sea)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isLoading {
                    Capsule().fill(Theme.depth[0]).frame(width: 180, height: 9).loadingShimmer(true)
                        .accessibilityLabel("Checking")
                } else {
                    Text("Not known yet").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
            Group {
                if let bytes {
                    Sounding(bytes: bytes)
                } else {
                    Text(" ")
                }
            }
            .frame(minWidth: 84, alignment: .trailing)
        }
        .padding(.vertical, Theme.Space.rowY)
        .accessibilityElement(children: .combine)
    }
}

extension ExtrasLine where Trailing == EmptyView {
    init(symbol: String, title: String, detail: String?, bytes: Int64?, isLoading: Bool) {
        self.init(symbol: symbol, title: title, detail: detail, bytes: bytes, isLoading: isLoading) { EmptyView() }
    }
}

// MARK: Package row

/// One installed package: kind, name, version (or the update waiting),
/// what it is, its size as a sounding on the list's trailing column edge,
/// and its actions. Update shows only when there is one; the rest is in
/// the row's menu, so a long list stays calm.
struct PackageRow: View {
    let package: BrewPackage
    /// "Updating…", "Waiting…" while a change is queued or running.
    let change: String?
    var prefix: String?
    var request: (_ uninstall: Bool) -> Void = { _ in }

    /// The trailing figure column, the same width on every row.
    static let figureWidth: CGFloat = 112

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: package.kind == .cask ? "app.dashed" : "shippingbox")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .help(package.kind == .cask ? "Cask (an app)" : "Formula (a command-line package)")
                .accessibilityLabel(package.kind == .cask ? "Cask" : "Formula")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    if package.outdated {
                        ToolTag(text: "\(package.installed) → \(package.available)", symbol: "arrow.up.circle", prominent: true)
                            .help("Version \(package.available) is available")
                            .accessibilityLabel("Update available: \(package.installed) to \(package.available)")
                    } else {
                        ToolTag(text: package.installed)
                    }
                    if package.pinned {
                        ToolTag(text: "Pinned", symbol: "pin.fill")
                            .help("Pinned in brew: it isn't updated until you unpin it")
                    }
                    if package.orphaned {
                        ToolTag(text: "Unneeded")
                            .help("Installed as a dependency; nothing installed needs it now (brew autoremove)")
                    }
                }
                if !package.description.isEmpty {
                    Text(package.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(package.description)
                }
                if let note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(note)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                if let bytes = package.bytes {
                    Sounding(bytes: bytes)
                        .help("Its Cellar or Caskroom folder plus a linked app. Shared dependencies, caches and user data aren't counted.")
                } else {
                    Text("Not measured")
                        .font(Theme.soundingSmall)
                        .foregroundStyle(.secondary)
                }
                Text(package.lastUsed.map { "Used " + $0.formatted(.relative(presentation: .named)) } ?? "Use not recorded")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(package.lastUsed.map { "Last opened \($0.formatted())" }
                          ?? "No reliable last-use record. That doesn't mean it's unused.")
            }
            .frame(width: Self.figureWidth, alignment: .trailing)

            actions
                .frame(width: 104, alignment: .trailing)
        }
        .padding(.vertical, Theme.Space.rowY)
        .padding(.horizontal, Theme.Space.inset)
        .contentShape(.rect)
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var actions: some View {
        if let change {
            VStack(alignment: .trailing, spacing: 4) {
                Text(change)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                DepthProgress(fraction: nil).frame(width: 72)
            }
            .transition(.opacity)
        } else {
            HStack(spacing: 6) {
                if package.outdated {
                    Button("Update") { request(false) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(package.pinned)
                        .help(package.pinned ? "Unpin this formula in brew before updating it" : "Update \(package.name) to \(package.available)")
                }
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions for \(package.name)")
                .accessibilityLabel("More actions for \(package.name)")
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private var menuItems: some View {
        if package.outdated {
            Button("Update to \(package.available)…") { request(false) }
                .disabled(package.pinned || change != nil)
        }
        Button("Uninstall…", role: .destructive) { request(true) }
            .disabled(change != nil)
        Divider()
        if let folder {
            Button("Show in Finder") { Finder.reveal(folder) }
        }
        Button("Copy Name") { Finder.copy(package.name) }
    }

    /// Where brew keeps it: the Cellar or Caskroom folder.
    private var folder: String? {
        prefix.map { $0 + (package.kind == .cask ? "/Caskroom/" : "/Cellar/") + package.token }
    }

    private var note: String? {
        guard !package.oldVersions.isEmpty else { return nil }
        let versions = package.oldVersions.joined(separator: ", ")
        return "Older versions kept: \(versions)" + (package.oldVersionBytes.map { " · \($0.bytes)" } ?? "")
    }
}
