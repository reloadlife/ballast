import BallastCore
import SwiftUI

/// The Overview for a drive other than the startup disk, in the same chart
/// grammar: how full it is, what's in folders and what isn't, and whether
/// its index is current. There are no app or cache categories here, only
/// what can be measured. One primary action at a time: Scan before the
/// first scan, Review once build folders are found.
struct DiskOverviewView: View {
    let model: AppModel
    let open: (Int64) -> Void
    @State private var confirmingForget = false

    var body: some View {
        if let disk = model.selectedDiskInfo {
            let builds = model.buildBytes(on: disk)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    VStack(alignment: .leading, spacing: 22) {
                        DiskHeader(model: model, disk: disk, builds: builds)
                            .background(alignment: .top) { HeaderContours() }
                        DiskState(model: model, disk: disk) { confirmingForget = true }
                        if disk.isConnected, !disk.isReadOnly, builds > 0 {
                            CleanablePanel(bytes: builds, title: "of build folders on this drive",
                                           detail: "node_modules and other build output that the next install or build recreates.") {
                                model.requestedPane = .cleanup
                            }
                        }
                    }

                    DiskContents(model: model, disk: disk, open: open)
                }
                .frame(maxWidth: Theme.Space.contentMax, alignment: .leading)
                .padding(.horizontal, Theme.Space.pageX)
                .padding(.vertical, Theme.Space.section)
                .frame(maxWidth: .infinity)
            }
            .confirmationDialog("Forget \(disk.name)?", isPresented: $confirmingForget) {
                Button("Forget \(disk.name)", role: .destructive) { Task { await model.forgetDisk(disk.uuid) } }
            } message: {
                Text("Ballast deletes its index of this drive. Nothing on the drive is touched; scan it again to see it here.")
            }
        } else {
            EmptyChart(symbol: "externaldrive", title: "No drive selected",
                       message: "Pick a drive under Disks in the sidebar to see what's on it.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Header

/// The drive's name, used and total space, free space as the hero, and
/// its bands: build folders, other folders, and used space no folder holds.
private struct DiskHeader: View {
    let model: AppModel
    let disk: Disk
    let builds: Int64

    private var used: Int64 {
        guard let mounted = disk.mounted else { return 0 }
        return max(mounted.total - mounted.free, 0)
    }

    private var formatLine: String {
        disk.isReadOnly ? "\(disk.format), read-only" : disk.format
    }

    var body: some View {
        let free = disk.mounted?.free
        StorageHeader(name: disk.name,
                      detail: disk.isConnected ? "\(used.bytes) of \(disk.total.bytes) used · \(formatLine)"
                                               : "\(disk.total.bytes) · \(formatLine) · not connected",
                      free: free, total: disk.mounted?.total ?? disk.total,
                      segments: AppModel.diskSegments(used: used, folders: model.diskOverview?.root.total, builds: builds),
                      isLow: disk.mounted.map { $0.total > 0 && $0.free * 10 < $0.total } ?? false,
                      systemNote: "Not in folders: used space that isn't in any folder Ballast measured, such as the file system's own bookkeeping and folders it couldn't read.")
    }
}

// MARK: Index state

/// Whether the drive's index is current and how it's kept that way, as a
/// quiet row; before the first scan, the Scan callout (the screen's ink).
private struct DiskState: View {
    let model: AppModel
    let disk: Disk
    let forget: () -> Void

    /// Display only: this drive's scan is the one running.
    private var isScanningThis: Bool { model.scanningDisk == disk.uuid }

    var body: some View {
        Group {
            if isScanningThis, let status = model.status {
                progress(status)
            } else if !disk.isScanned {
                firstScan
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.gap) {
                    state
                    if disk.isConnected && disk.isReadOnly {
                        QuietNotice(symbol: "lock", title: "This drive is read-only",
                                    detail: "You can see what's on it, but Ballast can't clean anything here.")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .animation(Motion.animation(Motion.state), value: isScanningThis)
    }

    @ViewBuilder
    private var state: some View {
        if !disk.isConnected {
            QuietNotice(symbol: "externaldrive.badge.xmark", title: "Not connected",
                        detail: "Last scanned \(scanned). Connect it to update the index, or forget it.") {
                Button("Forget…", action: forget)
                    .disabled(model.isBusyWithUserWork)
            }
        } else if disk.isJournaled {
            QuietNotice(symbol: "arrow.triangle.2.circlepath", title: "Ballast follows changes on this drive",
                        detail: "Scanned \(scanned). Update rechecks only what changed since then, even if the drive was unplugged in between.") {
                Button("Update") { Task { await model.scanDisk(disk.uuid) } }
                    .disabled(model.isBusyWithUserWork)
            }
        } else {
            QuietNotice(symbol: "arrow.clockwise", title: "Ballast rescans this drive each time",
                        detail: "Scanned \(scanned). It can't follow changes on \(disk.format) drives, so Rescan measures everything again.") {
                Button("Rescan") { Task { await model.scanDisk(disk.uuid, full: true) } }
                    .disabled(model.isBusyWithUserWork)
            }
        }
    }

    private var scanned: String {
        disk.scannedAt?.formatted(.relative(presentation: .named)) ?? "before"
    }

    /// Before the first scan: the one thing to do here, as a glass callout.
    private var firstScan: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.inset) {
                symbol
                message
                Spacer(minLength: Theme.Space.gap)
                scanButton
            }
            HStack(alignment: .top, spacing: Theme.Space.inset) {
                symbol
                VStack(alignment: .leading, spacing: Theme.Space.gap) {
                    message
                    scanButton
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Theme.Space.inset + 4)
        .padding(.vertical, Theme.Space.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chartGlass()
    }

    private var symbol: some View {
        Image(systemName: disk.isRemovable ? "externaldrive" : "internaldrive")
            .font(.title)
            .foregroundStyle(Theme.sea)
            .frame(width: 34)
            .accessibilityHidden(true)
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Ballast hasn't measured \(disk.name) yet")
                .font(.headline)
            Text(disk.isJournaled
                 ? "Other drives are only scanned when you ask. After the first scan, Update rechecks only what changed."
                 : "Other drives are only scanned when you ask. \(disk.format) drives are measured in full each time.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var scanButton: some View {
        if disk.isConnected {
            Button("Scan \(disk.name)") { Task { await model.scanDisk(disk.uuid, full: true) } }
                .buttonStyle(.ink)
                .disabled(model.isBusyWithUserWork)
        } else {
            Text("Connect it to scan")
                .foregroundStyle(.secondary)
        }
    }

    /// This drive's scan, quietly: what it's reading, a thin progress
    /// line, and Stop.
    private func progress(_ status: ScanStatus) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.gap) {
            ScanProgressView(status: status, fraction: model.progress, showsBar: true)
            Button("Stop") { model.cancelScan() }
                .buttonStyle(.bordered)
                .help("Stop; the saved index stays as it was")
        }
        .padding(.horizontal, Theme.Space.inset + 4)
        .padding(.vertical, Theme.Space.inset)
        .chartSurface()
    }
}

// MARK: Contents

/// The drive's largest folders and files, skeleton rows while its index
/// opens, and what couldn't be read.
private struct DiskContents: View {
    let model: AppModel
    let disk: Disk
    let open: (Int64) -> Void

    var body: some View {
        if let overview = model.diskOverview {
            let locked = overview.lockedByPrivacy + overview.lockedByPermissions
            if locked > 0 {
                QuietNotice(symbol: "hand.raised", title: "\(locked.formatted()) folder\(locked == 1 ? "" : "s") on \(disk.name) couldn't be read.",
                            detail: "They're shown as Locked. Full Disk Access lets Ballast read more of the drive; rescan after granting it.") {
                    Button("Open Settings") { Access.openFullDiskAccessSettings() }
                        .buttonStyle(.bordered)
                }
            }
            if !model.diskHotspots.isEmpty {
                LargestFoldersSection(model: model, spots: model.diskHotspots, open: open)
            }
            LargestFilesSection(model: model, list: model.diskLargeFiles, locked: locked,
                                rescan: disk.isConnected ? { Task { await model.scanDisk(disk.uuid, full: true) } } : nil,
                                canRescan: !model.isBusyWithUserWork)
        } else if disk.isScanned {
            // The index opens when the drive is picked; give it a moment,
            // then say what to do if it doesn't.
            OpeningIndex(disk: disk) {
                Task { await model.scanDisk(disk.uuid, full: true) }
            } canRescan: {
                disk.isConnected && !model.isBusyWithUserWork
            }
            .id(disk.uuid)
        }
    }
}

/// Skeleton rows for a few seconds while a drive's index opens; then, if
/// it still hasn't, what to do. Never an endless placeholder. The model
/// doesn't say whether the load failed or is just slow (a large drive's
/// folders and files take a while), so the copy is true either way, and
/// the lists replace it as soon as they arrive.
private struct OpeningIndex: View {
    let disk: Disk
    let rescan: () -> Void
    let canRescan: () -> Bool
    @State private var waited = false

    var body: some View {
        Group {
            if waited {
                EmptyChart(symbol: "externaldrive.badge.questionmark", title: "The index of \(disk.name) hasn't opened",
                           message: disk.isConnected
                               ? "A large drive can take a while. If its folders don't appear, scan the drive again to rebuild the index. Nothing on the drive is changed."
                               : "A large drive can take a while. If its folders don't appear, connect the drive and scan it again to rebuild the index.") {
                    if disk.isConnected {
                        Button("Scan Again", action: rescan)
                            .buttonStyle(.bordered)
                            .disabled(!canRescan())
                    }
                }
                .transition(.opacity)
            } else {
                ChartSection(title: "Largest folders") {
                    SkeletonRows(count: 5)
                }
                .transition(.opacity.animation(Motion.exit))
            }
        }
        .task {
            guard (try? await Task.sleep(for: .seconds(5))) != nil else { return }
            Motion.with(Motion.state) { waited = true }
        }
    }
}
