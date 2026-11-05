import AppKit
import SwiftUI

struct HomebrewView: View {
    @State private var tools = DeveloperToolsModel.shared
    @State private var query = ""
    @State private var updatesOnly = false
    @State private var sort: BrewPackage.Sort = .name
    @State private var pending: BrewPackage?
    @State private var uninstall = false
    /// Filtered and sorted once per change, not on every render.
    @State private var visible: [BrewPackage] = []
    @State private var oldVersionBytes: Int64 = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Installed packages").font(.title2.weight(.semibold))
                        Text(summary).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Button("Check for Updates", systemImage: "arrow.clockwise") { tools.checkForUpdates() }
                        .disabled(Homebrew.executable == nil)
                        .help("Contacts Homebrew to refresh available versions. Package changes run through brew; uninstalling does not use the Trash.")
                }
                HStack {
                    Toggle("Updates only", isOn: $updatesOnly).toggleStyle(.checkbox)
                    Spacer()
                    Picker("Sort", selection: $sort) {
                        ForEach(BrewPackage.Sort.allCases) { Text($0.rawValue).tag($0) }
                    }.fixedSize()
                }.controlSize(.small)
                Text(footnote)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(14)
            ToolFeedback(status: tools.brew, cancel: tools.cancelBrew)
            Divider()
            if Homebrew.executable == nil {
                ContentUnavailableView("Homebrew not found", systemImage: "shippingbox", description: Text("Install Homebrew in /opt/homebrew or /usr/local, then refresh this screen."))
            } else if !tools.brewLoaded {
                ProgressView("Reading installed packages…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView(query.isEmpty ? (updatesOnly ? "No updates listed" : "No packages installed") : "No matching packages",
                                       systemImage: "shippingbox", description: Text("Refresh the inventory or change your filter."))
            } else {
                List(visible) { package in
                    PackageRow(package: package, change: tools.pendingChanges[package.id]) { removing in
                        uninstall = removing
                        pending = package
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $query, prompt: "Search Packages")
        .toolbar { Button("Refresh Inventory", systemImage: "arrow.triangle.2.circlepath") { Task { await tools.loadBrew(force: true) } } }
        .task { if !tools.brewLoaded { await tools.loadBrew() } }
        .onAppear(perform: recompute)
        .onChange(of: tools.packages) { recompute() }
        .onChange(of: query) { recompute() }
        .onChange(of: updatesOnly) { recompute() }
        .onChange(of: sort) { recompute() }
        .confirmationDialog(pending.map { "\(uninstall ? "Uninstall" : "Update") \($0.name)?" } ?? "Package change",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let package = pending {
                Button(uninstall ? "Uninstall Package" : "Update Package", role: uninstall ? .destructive : nil) {
                    tools.changePackage(package, uninstall: uninstall)
                }
            }
        } message: {
            Text(uninstall ? "Homebrew will remove this package. Dependent formulae remain protected by brew. This cannot be undone from Cleanup History."
                 : "Homebrew will download and install the update and any required dependencies. This may take several minutes.")
        }
    }

    private var summary: String {
        var parts = ["\(tools.packages.count) installed", "\(tools.updateCount) update\(tools.updateCount == 1 ? "" : "s") available"]
        if tools.orphanCount > 0 { parts.append("\(tools.orphanCount) unneeded dependenc\(tools.orphanCount == 1 ? "y" : "ies")") }
        return parts.joined(separator: " · ")
    }

    private var footnote: String {
        var text = "Last use is recorded for apps when available; command-line usage is not tracked."
        if oldVersionBytes > 0 { text += " Older versions take \(oldVersionBytes.bytes); `brew cleanup` removes them." }
        return text
    }

    private func recompute() {
        visible = BrewPackage.visible(tools.packages, query: query, updatesOnly: updatesOnly, sort: sort)
        oldVersionBytes = tools.packages.compactMap(\.oldVersionBytes).reduce(0, +)
    }
}

private struct PackageRow: View {
    let package: BrewPackage
    /// "Updating…", "Waiting…" while a change is queued or running.
    let change: String?
    let request: (_ uninstall: Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: package.kind == .cask ? "app" : "shippingbox")
                .foregroundStyle(.secondary).frame(width: 16).help(package.kind.rawValue.capitalized)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.name).fontWeight(.medium).lineLimit(1).textSelection(.enabled)
                    Text(package.outdated ? "\(package.installed) → \(package.available)" : package.installed)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if package.pinned { Image(systemName: "pin.fill").font(.caption).help("Pinned") }
                }
                if !package.description.isEmpty {
                    Text(package.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(package.description)
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(note) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(package.bytes?.bytes ?? "Not indexed").monospacedDigit()
                    .help("Indexed Cellar/Caskroom files plus linked app bundles. Excludes shared dependencies, caches, user data and installer payloads outside these locations.")
                Text(package.lastUsed.map { "Used " + $0.formatted(.relative(presentation: .named)) } ?? "Use not recorded")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(package.lastUsed.map { "Last opened: " + $0.formatted() } ?? "No reliable last-use record. This does not mean the package is unused.")
            }.frame(width: 130, alignment: .trailing)
            if let change {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(change).font(.caption).foregroundStyle(.secondary)
                }.frame(minWidth: 110, alignment: .trailing)
            } else {
                if package.outdated {
                    Button("Update") { request(false) }
                        .disabled(package.pinned)
                        .help(package.pinned ? "Unpin this formula in brew before updating it." : "Update \(package.name)")
                }
                Button("Uninstall…") { request(true) }
            }
        }.controlSize(.small).padding(.vertical, 3)
    }

    private var note: String? {
        var parts: [String] = []
        if package.orphaned { parts.append("Installed as a dependency; nothing installed needs it now (brew autoremove)") }
        if !package.oldVersions.isEmpty {
            let versions = package.oldVersions.joined(separator: ", ")
            parts.append("Older versions kept: \(versions)" + (package.oldVersionBytes.map { " · \($0.bytes)" } ?? ""))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct WorktreesView: View {
    @Bindable var model: AppModel
    @State private var findingBuildFiles = false
    @State private var tools = DeveloperToolsModel.shared
    @State private var pending: GitWorktree?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Git worktrees").font(.title2.weight(.semibold))
                        Text("Clean build files or remove unused working copies.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add Repository…", systemImage: "folder.badge.plus", action: choose)
                }
                if !tools.repositories.isEmpty {
                    Picker("Repository", selection: Binding(get: { tools.repository }, set: { path in Task { await tools.loadWorktrees(path) } })) {
                        if tools.repository.isEmpty || !tools.repositories.contains(tools.repository) {
                            Text(tools.repository.isEmpty ? "Choose a repository" : tools.repository).tag(tools.repository)
                        }
                        ForEach(tools.repositories, id: \.self) { Text($0).tag($0) }
                    }
                }
                Text("Choose a repository or any of its worktrees, anywhere on disk. Removal uses Git and is permanent; changed, untracked and locked worktrees, and ignored files that aren't build output, stay protected.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20)
            ToolFeedback(status: tools.git, cancel: tools.cancelGit)
            Divider()
            if tools.worktrees.isEmpty {
                if tools.isReadingWorktrees || (!tools.discovered && tools.repository.isEmpty) {
                    ProgressView(tools.repository.isEmpty ? "Finding repositories…" : "Reading worktrees…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tools.repository.isEmpty {
                    ContentUnavailableView("Choose a Git repository", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("Add a folder, including one outside your home folder. Repositories in the disk index also appear here."))
                } else {
                    ContentUnavailableView("No worktrees to show", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("Git didn't list any worktrees for this folder. Choose another repository or refresh."))
                }
            } else {
                List(tools.worktrees) { tree in
                    WorktreeRow(tree: tree, state: tools.state(of: tree), findingBuildFiles: findingBuildFiles,
                                clean: { Task { await cleanBuildFiles(tree) } }, remove: { pending = tree })
                }.listStyle(.inset)
            }
        }
        .toolbar {
            Button("Refresh Worktrees", systemImage: "arrow.clockwise") {
                Task { if tools.repository.isEmpty { await tools.discover() } else { await tools.loadWorktrees(tools.repository) } }
            }
            Button("Find Indexed Repositories", systemImage: "magnifyingglass") { Task { await tools.discover() } }
        }
        .task {
            // The last repository lists at once; the index search runs alongside.
            if !tools.repository.isEmpty && !tools.worktreesLoaded {
                let path = tools.repository
                Task { await tools.loadWorktrees(path) }
            }
            if !tools.discovered { await tools.discover() }
        }
        .confirmationDialog("Remove this worktree permanently?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let tree = pending {
                Button("Remove Worktree", role: .destructive) { tools.removeWorktree(tree) }
            }
        } message: {
            Text("\(pending?.path ?? "")\n\nGit will recheck the working copy before removal. Its branch stays available. This does not use the Trash.")
        }
    }

    private func cleanBuildFiles(_ tree: GitWorktree) async {
        findingBuildFiles = true
        defer { findingBuildFiles = false }
        tools.reportGit()
        do {
            let folders = try await GitWorktrees.buildFoldersAsync(tree)
            if folders.isEmpty {
                tools.reportGit(message: "No recognized ignored build folders found in this worktree. Use Explorer to review other files.")
            } else {
                await model.add(urls: folders)
                model.isListShown = true
                tools.reportGit(message: "Build folders checked. Review the Cleanup List, then press Clean. The worktree and source files stay in place.")
            }
        } catch is CancellationError {
            return
        } catch {
            tools.reportGit(failure: error.localizedDescription)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Inspect Worktrees"
        if panel.runModal() == .OK, let url = panel.url { Task { await tools.loadWorktrees(url.path, addedByUser: true) } }
    }
}

private struct WorktreeRow: View {
    let tree: GitWorktree
    let state: DeveloperToolsModel.WorktreeState
    let findingBuildFiles: Bool
    let clean: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(tree.label, systemImage: tree.isMain ? "house" : "arrow.triangle.branch").fontWeight(.medium)
                if tree.isMain { Text("Main worktree").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Show in Finder") { Finder.reveal(tree.path) }
                Button("Clean Build Files…", action: clean)
                    .disabled(findingBuildFiles || tree.locked || tree.prunable)
                Button("Remove Worktree…", role: .destructive, action: remove)
                    .disabled(state != .removable)
            }
            Text(tree.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            status.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 8)
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking for changes…") }
        case .removing:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Removing…") }
        case .removable:
            Label("Clean working copy. Removal keeps its branch and commits.", systemImage: "checkmark.shield")
        case .blocked(let reason):
            Label(reason, systemImage: "lock")
        }
    }
}

private struct ToolFeedback: View {
    let status: DeveloperToolsModel.Status
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let activity = status.activity {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(activity).font(.callout)
                    Spacer()
                    if status.canCancel { Button("Cancel", action: cancel).controlSize(.small) }
                }
            }
            if let failure = status.failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
            } else if let message = status.message {
                Label(message, systemImage: "checkmark.circle").font(.callout)
            }
            if let command = status.command {
                HStack {
                    Text(command).font(.callout.monospaced()).textSelection(.enabled)
                    Button("Copy") { Finder.copy(command) }.controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, status.isEmpty && status.command == nil ? 0 : 12)
    }
}
