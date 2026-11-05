import BallastCore
import SwiftUI

/// The startup disk read like a chart: how deep it's loaded and how much
/// open water is left, what can be dropped safely, then where the weight
/// sits. The first viewport is the storage header (free space as the one
/// hero figure, the depth bar) and the glass "can be cleaned safely" panel
/// with Review, the screen's one ink plate.
struct OverviewView: View {
    let model: AppModel
    let open: (Pane, Int64?) -> Void
    let explore: (String) -> Void
    @State private var showingSystemData = false
    @State private var confirmingEmptyTrash = false
    /// The bands, worked out when the index or the free space changes:
    /// building them filters the suggestions.
    @State private var segments: [DepthBar.Segment] = []
    /// The figures from just before a cleanup, while it runs (see DropHold).
    @State private var held: StorageFigures?
    @Environment(\.ballastDrop) private var drop

    private var live: StorageFigures {
        StorageFigures(segments: segments, free: model.freeBytes, total: model.totalBytes,
                       reclaimable: model.reclaimable, trash: model.trashBytes, drain: drop.latest)
    }

    var body: some View {
        let shown = held ?? live
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                VStack(alignment: .leading, spacing: 22) {
                    StorageHeader(name: Paths.volumeName,
                                  detail: "\(shown.used.bytes) of \(shown.total.bytes) used",
                                  free: shown.free, total: shown.total, segments: shown.segments,
                                  // Held: the drain from before the cleanup, so a new one
                                  // plays when the hold lets go and an old one never replays.
                                  drain: shown.drain,
                                  isLow: model.isLowOnSpace,
                                  systemData: { showingSystemData = true })
                    .background(alignment: .top) { HeaderContours() }
                    CleanablePanel(bytes: shown.reclaimable, trash: shown.trash, sweep: drop.freedToken,
                                   canEmptyTrash: !model.isBusyWithUserWork,
                                   review: { open(.cleanup, nil) },
                                   emptyTrash: { confirmingEmptyTrash = true })
                }

                OverviewNotices(model: model)

                if !model.hotspots.isEmpty {
                    LargestFoldersSection(model: model, spots: model.hotspots) { open(.explorer, $0) }
                }

                LargestFilesSection(model: model, list: model.largeFiles,
                                    locked: (model.overview?.lockedByPermissions ?? 0) + (model.overview?.lockedByPrivacy ?? 0),
                                    rescan: { Task { await model.fullScan() } },
                                    canRescan: !model.isBusyWithUserWork)

                GrowthSection(model: model, explore: explore)

                if model.history.count >= 2 {
                    HistorySection(points: model.history)
                }
            }
            .frame(maxWidth: Theme.Space.contentMax, alignment: .leading)
            .padding(.horizontal, Theme.Space.pageX)
            .padding(.vertical, Theme.Space.section)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: model.depthKey, initial: true) { segments = model.depthSegments }
        .modifier(DropHoldWatcher(model: model, held: $held, live: live))
        .sheet(isPresented: $showingSystemData) {
            SystemDataSheet(model: model) { action in
                showingSystemData = false
                switch action {
                case .explore(let path): explore(path)
                case .adminScan: Task { await model.rescanLockedAsAdmin() }
                case .none: break
                }
            }
            .ownsInkPlate()
        }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmingEmptyTrash) {
            Button("Empty Trash", role: .destructive) { Task { await model.emptyTrash() } }
        } message: {
            Text("Everything in the Trash is deleted for good, including what you put there yourself. Put Back won't work after this.")
        }
    }
}

// MARK: Notices

/// Folders Ballast couldn't measure and the one-time usage-data question,
/// as quiet rows on the water: what's going on, and what to do about it.
private struct OverviewNotices: View {
    let model: AppModel

    var body: some View {
        let privacy = model.overview?.lockedByPrivacy ?? 0
        let admin = model.overview?.lockedByPermissions ?? 0
        if privacy > 0 || admin > 0 || model.asksAboutUsageData {
            VStack(alignment: .leading, spacing: Theme.Space.gap) {
                if privacy > 0 && !model.hasFullDiskAccess {
                    QuietNotice(symbol: "hand.raised", title: "\(privacy.formatted()) folders are hidden by macOS privacy settings.",
                                detail: "Allow Full Disk Access, then reopen Ballast.") {
                        Button("Open Settings") { Access.openFullDiskAccessSettings() }
                    }
                } else if privacy > 0 {
                    QuietNotice(symbol: "arrow.clockwise", title: "\(privacy.formatted()) folders were skipped before access was granted.",
                                detail: "Scan them again now.") {
                        Button("Rescan") { Task { await model.rescanLocked() } }
                            .disabled(model.isBusyWithUserWork)
                    }
                }
                if admin > 0 {
                    QuietNotice(symbol: "lock", title: "\(admin.formatted()) system folders need an administrator to measure.",
                                detail: "Ballast asks for your password once and reads only these.") {
                        Button("Scan as Admin…") { Task { await model.rescanLockedAsAdmin() } }
                            .disabled(model.isBusyWithUserWork)
                    }
                }
                if model.asksAboutUsageData {
                    UsageDataQuestion(model: model)
                        .transition(.opacity.animation(Motion.exit))
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Asked once, on a launch after the first scan: a quiet row, not a
/// dialog. Either answer is final; Settings › Privacy can change it.
private struct UsageDataQuestion: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        QuietNotice(symbol: "chart.bar.xaxis", title: "Help improve Ballast?",
                    detail: "Share anonymous usage data: no file names, paths or exact sizes.") {
            Button("What's Sent") {
                SettingsTab.select(.privacy)
                openSettings()
            }
            .buttonStyle(.link)
            Button("No Thanks") { answer(false) }
            Button("Share") { answer(true) }
        }
    }

    private func answer(_ share: Bool) {
        Motion.with(Motion.state) { model.setSharesUsageData(share) }
    }
}
