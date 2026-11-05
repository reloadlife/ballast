import AppKit
import SwiftUI

// MARK: Homebrew

/// Installed formulae and casks, with what brew can clean up. The saved
/// inventory shows at once; sizes, updates and descriptions arrive in the
/// background under a quiet progress line, and nothing on screen waits
/// for brew. Every long brew run can be cancelled.
struct HomebrewView: View {
    @State private var tools = DeveloperToolsModel.shared
    @State private var query = ""
    @State private var updatesOnly = false
    @State private var sort: BrewPackage.Sort = .name
    @State private var pending: PackageChange?
    @State private var confirmingCleanup = false
    @State private var confirmingOrphans = false
    /// Filtered and sorted once per change, not on every render.
    @State private var visible: [BrewPackage] = []
    @State private var installedBytes: Int64 = 0
    @State private var figures = HomebrewExtrasFigures()

    private struct PackageChange: Identifiable {
        let package: BrewPackage
        let uninstall: Bool
        var id: String { package.id }
    }

    private var prefix: String? { Homebrew.executable.map(Homebrew.prefix(for:)) }

    var body: some View {
        Group {
            if Homebrew.executable == nil {
                EmptyChart(symbol: "shippingbox", title: "Homebrew isn't installed",
                           message: "Ballast looks for brew in /opt/homebrew and /usr/local. Install it from brew.sh, then open this screen again.") {
                    Link("Open brew.sh", destination: URL(string: "https://brew.sh")!)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ToolPage {
                    HomebrewExtrasPanel(figures: figures, state: extrasActivity,
                                        refresh: { Task { await tools.loadExtras(force: true) } },
                                        cancel: { tools.cancelExtras() },
                                        cleanUp: { confirmingCleanup = true },
                                        removeOrphans: { confirmingOrphans = true })
                    ToolOutcomeLine(message: tools.extras.message, failure: tools.extras.failure,
                                    command: tools.extras.command, dismiss: { tools.dismissExtrasFeedback() })
                    packages
                }
            }
        }
        .searchable(text: $query, prompt: "Search Packages")
        // The inventory reads only if it isn't on screen yet; the extras'
        // dry runs (several seconds of brew) run while the saved figures
        // show.
        .task { if !tools.brewLoaded { await tools.loadBrew() } }
        .task {
            // Brew's figures change only when packages do (and a package
            // change rereads them), so a recent check isn't repeated on
            // every visit. Refresh always asks again.
            let recent = tools.extrasCheckedAt.map { Date.now.timeIntervalSince($0) < 600 } ?? false
            if !recent { await tools.loadExtras() }
        }
        .onAppear {
            recompute()
            recountExtras()
        }
        .onChange(of: tools.packages) { recompute() }
        .onChange(of: query) { recompute() }
        .onChange(of: updatesOnly) { recompute() }
        .onChange(of: sort) { recompute() }
        .onChange(of: tools.orphans) { recountExtras() }
        .onChange(of: tools.oldVersions) { recountExtras() }
        .onChange(of: tools.fullCleanup) { recountExtras() }
        .confirmationDialog(pending.map { title(for: $0) } ?? "Package change",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { change in
            Button(change.uninstall ? "Uninstall" : "Update", role: change.uninstall ? .destructive : nil) {
                tools.changePackage(change.package, uninstall: change.uninstall)
            }
        } message: { change in
            Text(message(for: change))
        }
        .confirmationDialog("Remove what Homebrew no longer needs?", isPresented: $confirmingCleanup, titleVisibility: .visible) {
            if let bytes = figures.cleanupBytes, bytes > 0 {
                Button("Remove Old Versions (\(bytes.bytes))") { Task { await tools.cleanupOldVersions(downloads: false) } }
            }
            if figures.downloadBytes > 0 {
                Button("Remove Old Versions and Downloads (\(figures.reclaimable.bytes))") {
                    Task { await tools.cleanupOldVersions(downloads: true) }
                }
            }
        } message: {
            Text("brew cleanup deletes them; they don't go to the Trash. Installed packages keep working, and brew downloads an installer again if it needs one.")
        }
        .confirmationDialog(orphanTitle, isPresented: $confirmingOrphans, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { Task { await tools.removeOrphans() } }
        } message: {
            Text("\((tools.orphans ?? []).joined(separator: ", "))\n\nNothing installed needs them. brew autoremove uninstalls them; this doesn't use the Trash.")
        }
    }

    // MARK: Package list

    private var packages: some View {
        ChartSection(title: "Installed packages", note: summary, total: installedBytes, padded: false) {
            HStack(spacing: 10) {
                Picker("Show", selection: $updatesOnly) {
                    Text("All").tag(false)
                    Text(tools.updateCount > 0 ? "Updates (\(tools.updateCount))" : "Updates").tag(true)
                }
                .pickerStyle(.segmented)
                .tint(Theme.control)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Show")
                Picker("Sort", selection: $sort) {
                    ForEach(BrewPackage.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Sort")
                Button("Check for Updates", systemImage: "arrow.clockwise") { tools.checkForUpdates() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .help("Asks Homebrew for new versions (brew update). Package changes run through brew; uninstalling doesn't use the Trash.")
                    .accessibilityLabel("Check for Updates")
                Button("Reload Installed Packages", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await tools.loadBrew(force: true) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .help("Read the installed packages again from disk (no network)")
                .accessibilityLabel("Reload Installed Packages")
            }
            .controlSize(.small)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if tools.brew.activity != nil || !tools.brew.isEmpty || tools.brew.command != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        if let activity = tools.brew.activity {
                            ToolActivityLine(activity: activity, canCancel: tools.brew.canCancel, cancel: { tools.cancelBrew() })
                        }
                        ToolOutcomeLine(message: tools.brew.message, failure: tools.brew.failure,
                                        command: tools.brew.command, dismiss: { tools.dismissBrewFeedback() })
                    }
                    .padding(Theme.Space.inset)
                    ToolHairline()
                }
                list
            }
            .animation(Motion.animation(Motion.state), value: tools.brew)
        }
    }

    @ViewBuilder private var list: some View {
        if !tools.brewLoaded {
            SkeletonRows(count: 8)
                .padding(.horizontal, Theme.Space.inset)
        } else if visible.isEmpty {
            if !query.isEmpty {
                EmptyChart(symbol: "magnifyingglass", title: "No matching packages",
                           message: "Nothing installed matches \u{201C}\(query)\u{201D}\(updatesOnly ? " with an update waiting" : "").") {
                    Button("Show All Packages") {
                        query = ""
                        updatesOnly = false
                    }
                    .buttonStyle(.glass)
                }
            } else if updatesOnly {
                EmptyChart(symbol: "checkmark.circle", title: "Everything is up to date",
                           message: "Homebrew lists no newer versions. Check for Updates asks it for the latest list.") {
                    Button("Check for Updates") { tools.checkForUpdates() }
                        .buttonStyle(.glass)
                }
            } else {
                EmptyChart(symbol: "shippingbox", title: "No packages installed",
                           message: "Formulae and casks you install with brew show up here, with their sizes and updates.")
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visible) { package in
                    if package.id != visible.first?.id { ToolHairline().padding(.leading, Theme.Space.inset + 32) }
                    PackageRow(package: package, change: tools.pendingChanges[package.id], prefix: prefix) { uninstall in
                        pending = PackageChange(package: package, uninstall: uninstall)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var summary: String {
        guard tools.brewLoaded else { return "Reading installed packages…" }
        var parts = ["\(tools.packages.count) installed",
                     tools.updateCount == 0 ? "no updates listed" : "\(tools.updateCount) update\(tools.updateCount == 1 ? "" : "s") available"]
        if tools.orphanCount > 0 { parts.append("\(tools.orphanCount) unneeded") }
        return parts.joined(separator: " · ") + ". App use is recorded where macOS has it; command-line use isn't."
    }

    private var extrasActivity: HomebrewExtrasActivity {
        HomebrewExtrasActivity(checkedAt: tools.extrasCheckedAt,
                               isLoadingOrphans: tools.isLoadingOrphans, isLoadingCleanup: tools.isLoadingCleanup,
                               isRemovingOrphans: tools.isRemovingOrphans, isCleaningUp: tools.isCleaningUp,
                               activity: tools.extras.activity, canCancel: tools.extras.canCancel)
    }

    private var orphanTitle: String {
        let count = tools.orphans?.count ?? 0
        return "Uninstall \(count) unneeded \(count == 1 ? "dependency" : "dependencies")?"
    }

    private func title(for change: PackageChange) -> String {
        change.uninstall ? "Uninstall \(change.package.name) \(change.package.installed)?"
            : "Update \(change.package.name) to \(change.package.available)?"
    }

    private func message(for change: PackageChange) -> String {
        if change.uninstall {
            let size = change.package.bytes.map { " and its \($0.bytes)" } ?? ""
            return "Homebrew removes \(change.package.name)\(size). It doesn't go to the Trash and can't be put back from Cleanup History. brew refuses if another package needs it."
        }
        return "Homebrew downloads and installs it with any dependencies it needs. This can take several minutes; you can keep using Ballast, and Cancel stops it."
    }

    private func recompute() {
        visible = BrewPackage.visible(tools.packages, query: query, updatesOnly: updatesOnly, sort: sort)
        installedBytes = tools.packages.reduce(0) { $0 + ($1.bytes ?? 0) }
    }

    private func recountExtras() {
        figures = HomebrewExtrasFigures(orphans: tools.orphans, oldVersions: tools.oldVersions,
                                        fullCleanup: tools.fullCleanup, prefix: prefix ?? "")
    }
}

// MARK: Git worktrees

/// A repository's worktrees, each checked with Git before it can be
/// removed. The list shows as soon as Git lists it; checks run a few at a
/// time and can be cancelled.
struct WorktreesView: View {
    @Bindable var model: AppModel
    @State private var tools = DeveloperToolsModel.shared
    @State private var pending: GitWorktree?
    /// The running build-folder search, so it can be cancelled.
    @State private var cleaning: (tree: GitWorktree, task: Task<Void, Never>)?

    var body: some View {
        ToolPage {
            header
            if cleaning != nil || tools.git.activity != nil || !tools.git.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if let cleaning {
                        ToolActivityLine(activity: "Finding build folders in \(cleaning.tree.label)…", canCancel: true) {
                            cleaning.task.cancel()
                        }
                    } else if let activity = tools.git.activity {
                        ToolActivityLine(activity: activity, canCancel: tools.git.canCancel, cancel: { tools.cancelGit() })
                    }
                    ToolOutcomeLine(message: tools.git.message, failure: tools.git.failure, dismiss: { tools.reportGit() })
                }
                .transition(.opacity)
            }
            content
        }
        .animation(Motion.animation(Motion.state), value: tools.git)
        .task {
            // The last repository lists at once; the index search runs alongside.
            if !tools.repository.isEmpty && !tools.worktreesLoaded {
                let path = tools.repository
                Task { await tools.loadWorktrees(path) }
            }
            if !tools.discovered { await tools.discover() }
        }
        .confirmationDialog("Remove this worktree permanently?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { tree in
            Button("Remove Worktree", role: .destructive) { tools.removeWorktree(tree) }
        } message: { tree in
            Text("\(Paths.display(tree.path))\n\nGit checks the working copy again just before removing it. Its branch \(tree.branch == nil ? "" : "(\(tree.label)) ")stays. This doesn't use the Trash.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                if tools.repositories.isEmpty {
                    Text(tools.repository.isEmpty ? "No repository chosen" : Paths.display(tools.repository))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Picker("Repository", selection: Binding(get: { tools.repository },
                                                            set: { path in Task { await tools.loadWorktrees(path) } })) {
                        if tools.repository.isEmpty || !tools.repositories.contains(tools.repository) {
                            Text(tools.repository.isEmpty ? "Choose a repository" : Paths.display(tools.repository)).tag(tools.repository)
                        }
                        ForEach(tools.repositories, id: \.self) { Text(Paths.display($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 420)
                    .accessibilityLabel("Repository")
                }
                Spacer(minLength: 8)
                Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .help("Read the worktrees again and recheck them")
                    .accessibilityLabel("Refresh Worktrees")
                Button("Find Repositories", systemImage: "magnifyingglass") { Task { await tools.discover() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .help("Find repositories in the disk index")
                    .accessibilityLabel("Find Repositories in the Disk Index")
                Button("Add Repository…", systemImage: "folder.badge.plus", action: choose)
                    .buttonStyle(.glass)
            }
            Text("Pick any repository or worktree on disk. Removal uses Git and is permanent; worktrees with changes, untracked or locked files, or ignored files that aren't build output, stay protected.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var content: some View {
        if tools.worktrees.isEmpty {
            if tools.isReadingWorktrees || (!tools.discovered && tools.repository.isEmpty) {
                ChartSection(title: tools.repository.isEmpty ? "Finding repositories" : "Reading worktrees", padded: false) {
                    SkeletonRows(count: 4).padding(.horizontal, Theme.Space.inset)
                }
            } else if tools.repository.isEmpty {
                EmptyChart(symbol: "point.3.connected.trianglepath.dotted", title: "Choose a Git repository",
                           message: "Add a folder, including one outside your home folder. Repositories in the disk index show up here on their own.") {
                    Button("Add Repository…", action: choose).buttonStyle(.ink)
                }
            } else {
                EmptyChart(symbol: "point.3.connected.trianglepath.dotted", title: "No worktrees to show",
                           message: "Git didn't list any worktrees for this folder. Choose another repository, or refresh if it just changed.") {
                    Button("Refresh", action: refresh).buttonStyle(.glass)
                }
            }
        } else {
            ChartSection(title: (tools.repository as NSString).lastPathComponent,
                         note: "\(tools.worktrees.count) \(tools.worktrees.count == 1 ? "worktree" : "worktrees") · \(Paths.display(tools.repository))",
                         padded: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tools.worktrees) { tree in
                        if tree.id != tools.worktrees.first?.id { ToolHairline().padding(.leading, Theme.Space.inset + 32) }
                        WorktreeRow(tree: tree, state: tools.state(of: tree),
                                    isFindingBuildFiles: cleaning != nil, isBusy: model.isBusyWithUserWork,
                                    clean: { startCleaning(tree) }, remove: { pending = tree })
                            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                                                    removal: .opacity.animation(Motion.animation(Motion.exit))))
                    }
                }
                .padding(.vertical, 4)
                .animation(Motion.animation(Motion.layout), value: tools.worktrees.map(\.id))
            }
        }
    }

    private func refresh() {
        Task { if tools.repository.isEmpty { await tools.discover() } else { await tools.loadWorktrees(tools.repository) } }
    }

    private func startCleaning(_ tree: GitWorktree) {
        guard cleaning == nil else { return }
        let task = Task { await cleanBuildFiles(tree) }
        cleaning = (tree, task)
    }

    private func cleanBuildFiles(_ tree: GitWorktree) async {
        defer { cleaning = nil }
        tools.reportGit()
        do {
            let folders = try await GitWorktrees.buildFoldersAsync(tree)
            try Task.checkCancellation()
            if folders.isEmpty {
                tools.reportGit(message: "No ignored build folders Ballast recognizes in \(tree.label). Explorer shows everything else in it.")
            } else {
                await model.add(urls: folders)
                model.isListShown = true
                tools.reportGit(message: "Added \(folders.count) build \(folders.count == 1 ? "folder" : "folders") to the Cleanup List. Review them, then press Clean Up. The worktree and its source files stay.")
            }
        } catch is CancellationError {
            tools.reportGit(message: "Stopped looking for build folders. Nothing was added.")
        } catch {
            tools.reportGit(failure: "Couldn't look for build folders: \(error.localizedDescription)")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Inspect Worktrees"
        if panel.runModal() == .OK, let url = panel.url { Task { await tools.loadWorktrees(url.path, addedByUser: true) } }
    }
}
