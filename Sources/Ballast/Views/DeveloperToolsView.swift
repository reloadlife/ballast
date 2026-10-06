import AppKit
import SwiftUI

struct HomebrewView: View {
    @State private var tools = DeveloperToolsModel.shared
    @State private var query = ""
    @State private var updatesOnly = false
    @State private var pending: BrewPackage?
    @State private var uninstall = false

    private var visible: [BrewPackage] {
        tools.packages.filter { (!updatesOnly || $0.outdated) && (query.isEmpty || "\($0.name) \($0.description)".localizedStandardContains(query)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Installed packages").font(.title2.weight(.semibold))
                        Text("\(tools.packages.count) installed · \(tools.packages.count { $0.outdated }) updates available")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Button("Check for Updates", systemImage: "arrow.clockwise") { Task { await tools.loadBrew(update: true) } }
                        .disabled(tools.busy || Homebrew.executable == nil)
                }
                Text("Check for Updates contacts Homebrew. Package changes run through brew; uninstalling does not move packages to the Trash.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Updates only", isOn: $updatesOnly).toggleStyle(.checkbox)
            }.padding(20)
            ToolFeedback(tools: tools)
            Divider()
            if Homebrew.executable == nil {
                ContentUnavailableView("Homebrew not found", systemImage: "shippingbox", description: Text("Install Homebrew in /opt/homebrew or /usr/local, then refresh this screen."))
            } else if visible.isEmpty && !tools.busy {
                ContentUnavailableView(query.isEmpty ? (updatesOnly ? "No updates listed" : "No packages installed") : "No matching packages",
                                       systemImage: "shippingbox", description: Text("Refresh the inventory or change your filter."))
            } else {
                List(visible) { package in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: package.kind == .cask ? "app" : "shippingbox").foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(package.name).fontWeight(.medium).textSelection(.enabled)
                                Text(package.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                if package.pinned { Label("Pinned", systemImage: "pin").font(.caption) }
                            }
                            Text(package.description).font(.callout).foregroundStyle(.secondary)
                            Text(package.outdated ? "\(package.installed) → \(package.available)" : "Installed: \(package.installed)")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if package.outdated {
                            Button("Update") { uninstall = false; pending = package }
                                .disabled(package.pinned || tools.busy)
                                .help(package.pinned ? "Unpin this formula in brew before updating it." : "Update \(package.name)")
                        }
                        Button("Uninstall…") { uninstall = true; pending = package }.disabled(tools.busy)
                    }.padding(.vertical, 8)
                }.listStyle(.inset)
            }
        }
        .searchable(text: $query, prompt: "Search Packages")
        .toolbar { Button("Refresh Inventory", systemImage: "arrow.triangle.2.circlepath") { Task { await tools.loadBrew() } }.disabled(tools.busy) }
        .task { if !tools.brewLoaded { await tools.loadBrew() } }
        .confirmationDialog(pending.map { "\(uninstall ? "Uninstall" : "Update") \($0.name)?" } ?? "Package change",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let package = pending {
                Button(uninstall ? "Uninstall Package" : "Update Package", role: uninstall ? .destructive : nil) {
                    let removing = uninstall
                    Task { await tools.changePackage(package, uninstall: removing) }
                }
            }
        } message: {
            Text(uninstall ? "Homebrew will remove this package. Dependent formulae remain protected by brew. This cannot be undone from Cleanup History."
                 : "Homebrew will download and install the update and any required dependencies. This may take several minutes.")
        }
    }
}

struct WorktreesView: View {
    @State private var tools = DeveloperToolsModel.shared
    @State private var pending: GitWorktree?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Git worktrees").font(.title2.weight(.semibold))
                        Text("Remove clean working copies. Keep their branches and commits.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add Repository…", systemImage: "folder.badge.plus", action: choose).disabled(tools.busy)
                }
                if !tools.repositories.isEmpty {
                    Picker("Repository", selection: Binding(get: { tools.repository }, set: { path in Task { await tools.loadWorktrees(path) } })) {
                        if tools.repository.isEmpty { Text("Choose a repository").tag("") }
                        ForEach(tools.repositories, id: \.self) { Text($0).tag($0) }
                    }.disabled(tools.busy)
                }
                Text("Choose a repository or any of its worktrees, anywhere on disk. Removal uses Git and is permanent; changed, untracked, ignored and locked worktrees stay protected.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20)
            ToolFeedback(tools: tools)
            Divider()
            if tools.worktrees.isEmpty && !tools.busy {
                ContentUnavailableView("Choose a Git repository", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Add a folder, including one outside your home folder. Repositories in the disk index also appear here."))
            } else {
                List(tools.worktrees) { tree in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(tree.label, systemImage: tree.isMain ? "house" : "arrow.triangle.branch").fontWeight(.medium)
                            if tree.isMain { Text("Main worktree").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Show in Finder") { Finder.reveal(tree.path) }
                            Button("Remove…", role: .destructive) { pending = tree }
                                .disabled(tools.busy || tools.blockers[tree.path] != nil)
                        }
                        Text(tree.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Label(tools.blockers[tree.path] ?? "Clean working copy. Removal keeps its branch and commits.",
                              systemImage: tools.blockers[tree.path] == nil ? "checkmark.shield" : "lock")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 8)
                }.listStyle(.inset)
            }
        }
        .toolbar {
            Button("Refresh Worktrees", systemImage: "arrow.clockwise") {
                Task { if tools.repository.isEmpty { await tools.discover() } else { await tools.loadWorktrees(tools.repository) } }
            }.disabled(tools.busy)
            Button("Find Indexed Repositories", systemImage: "magnifyingglass") { Task { await tools.discover() } }.disabled(tools.busy)
        }
        .task { if !tools.worktreesLoaded { await tools.discover() } }
        .confirmationDialog("Remove this worktree permanently?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let tree = pending {
                Button("Remove Worktree", role: .destructive) { Task { await tools.removeWorktree(tree) } }
            }
        } message: {
            Text("\(pending?.path ?? "")\n\nGit will recheck the working copy before removal. Its branch stays available. This does not use the Trash.")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Inspect Worktrees"
        if panel.runModal() == .OK, let url = panel.url { Task { await tools.loadWorktrees(url.path) } }
    }
}

private struct ToolFeedback: View {
    let tools: DeveloperToolsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tools.busy {
                HStack { ProgressView().controlSize(.small); Text(tools.activity).font(.callout) }
            }
            if let failure = tools.failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
            } else if let message = tools.message {
                Label(message, systemImage: "checkmark.circle").font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, tools.busy || tools.failure != nil || tools.message != nil ? 12 : 0)
    }
}
