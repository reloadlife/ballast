import SwiftUI

/// One Git worktree: branch, path (with What is this?), and its removal
/// status as a shape and a plain reason. Clean Build Files is the row's
/// everyday action; Remove sits beside it, and when it can't be used the
/// reason is on the row, not hidden in a tooltip.
struct WorktreeRow: View {
    let tree: GitWorktree
    let state: DeveloperToolsModel.WorktreeState
    /// Build folders are being looked for in some worktree.
    var isFindingBuildFiles = false
    /// Work the user started (a scan or cleanup) holds the Cleanup List.
    var isBusy = false
    var clean: () -> Void = {}
    var remove: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tree.isMain ? "house" : "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(tree.label)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    if tree.isMain { ToolTag(text: "Main worktree") }
                    if tree.locked { ToolTag(text: "Locked", symbol: "lock") }
                    if tree.prunable { ToolTag(text: "Folder missing") }
                }
                HStack(spacing: 4) {
                    Text(Paths.display(tree.path))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    WhatIsThisButton(path: tree.path, level: knownLevel)
                }
                WorktreeStatusLine(state: state)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button("Clean Build Files…", action: clean)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(cleanDisabledReason != nil)
                    .help(cleanDisabledReason ?? "Find this worktree's ignored build folders and add them to the Cleanup List")
                Button("Remove…", role: .destructive, action: remove)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(state != .removable)
                    .help(removeHelp)
                // Show in Finder and Copy Path, reachable without a
                // right-click (keyboard and VoiceOver).
                Menu {
                    Button("Show in Finder") { Finder.reveal(tree.path) }
                    Button("Copy Path") { Finder.copy(tree.path) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions for \(tree.label)")
                .accessibilityLabel("More actions for \(tree.label)")
            }
            .padding(.top, 1)
        }
        .padding(.vertical, Theme.Space.rowY + 2)
        .padding(.horizontal, Theme.Space.inset)
        .contentShape(.rect)
        .contextMenu {
            Button("Show in Finder") { Finder.reveal(tree.path) }
            Button("Copy Path") { Finder.copy(tree.path) }
            Divider()
            Button("Clean Build Files…", action: clean).disabled(cleanDisabledReason != nil)
            Button("Remove Worktree…", role: .destructive, action: remove).disabled(state != .removable)
        }
        .animation(Motion.animation(Motion.state), value: state)
        .accessibilityElement(children: .contain)
    }

    /// The popover says what the row says: protected, or (once Git has
    /// found a clean working copy) safe to remove.
    private var knownLevel: Safety.Level? {
        switch state {
        case .blocked: .blocked
        case .removable: .safe
        case .checking, .removing: nil
        }
    }

    private var cleanDisabledReason: String? {
        if tree.prunable { return "The worktree's folder is missing" }
        if tree.locked { return "Git has locked this worktree" }
        if isBusy { return "Wait for the current scan or cleanup to finish" }
        if isFindingBuildFiles { return "Already looking for build folders" }
        if state == .removing { return "This worktree is being removed" }
        return nil
    }

    private var removeHelp: String {
        switch state {
        case .removable: "Remove this worktree with Git. Its branch and commits stay."
        case .checking: "Checking the worktree for changes first"
        case .removing: "Removing…"
        case .blocked(let reason): reason
        }
    }
}

/// Removal status as a shape: checking (dotted circle), clean (checkmark
/// circle), removing (a progress line), protected (lock, with the reason).
struct WorktreeStatusLine: View {
    let state: DeveloperToolsModel.WorktreeState

    var body: some View {
        Group {
            switch state {
            case .checking:
                Label {
                    Text("Checking for changes…")
                } icon: {
                    Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            case .removing:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Removing…").foregroundStyle(.secondary)
                    DepthProgress(fraction: nil).frame(maxWidth: 200)
                }
            case .removable:
                // A removal verdict, so the verdict's own mark, like .blocked.
                Label {
                    Text("Clean working copy. Removing it keeps its branch and commits.").foregroundStyle(.secondary)
                } icon: {
                    SafetyMark(level: .safe)
                }
                .accessibilityElement(children: .combine)
            case .blocked(let reason):
                Label {
                    Text(reason).foregroundStyle(.secondary)
                } icon: {
                    SafetyMark(level: .blocked)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Can't remove: \(reason)")
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .transition(.opacity)
    }
}
