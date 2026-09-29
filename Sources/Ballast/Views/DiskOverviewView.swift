import BallastCore
import SwiftUI

/// The Overview for a drive other than the startup disk: how full it is,
/// what's in folders and what isn't, and whether its index is current.
/// There are no app or cache categories here, only what can be measured.
struct DiskOverviewView: View {
    let model: AppModel
    let open: (Int64) -> Void
    @State private var confirmingForget = false

    var body: some View {
        if let disk = model.selectedDiskInfo {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    DiskSummary(model: model, disk: disk)

                    DiskState(model: model, disk: disk) { confirmingForget = true }

                    let builds = model.buildBytes(on: disk)
                    if disk.isConnected, !disk.isReadOnly, builds > 0 {
                        ReadyToClean(bytes: builds, title: "\(builds.bytes) of build folders on this drive",
                                     detail: "node_modules and other build output that the next install or build recreates.") {
                            model.requestedPane = .cleanup
                        }
                    }

                    if let overview = model.diskOverview, overview.lockedByPrivacy + overview.lockedByPermissions > 0 {
                        LockedNote(count: overview.lockedByPrivacy + overview.lockedByPermissions, disk: disk)
                    }

                    if !model.diskHotspots.isEmpty {
                        LargestFolders(model: model, spots: model.diskHotspots, open: open)
                    }

                    if let overview = model.diskOverview {
                        LargestFiles(model: model, list: model.diskLargeFiles,
                                     locked: overview.lockedByPermissions + overview.lockedByPrivacy,
                                     rescan: disk.isConnected && !model.isScanning
                                        ? { Task { await model.scanDisk(disk.uuid, full: true) } } : nil)
                    }
                }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
            }
            .confirmationDialog("Forget \(disk.name)?", isPresented: $confirmingForget) {
                Button("Forget \(disk.name)", role: .destructive) { Task { await model.forgetDisk(disk.uuid) } }
            } message: {
                Text("Ballast deletes its index of this drive. Nothing on the drive is touched; scan it again to see it here.")
            }
        } else {
            ContentUnavailableView("No Disk", systemImage: "externaldrive", description: Text("Pick a disk in the sidebar."))
        }
    }
}

// MARK: Summary

private struct DiskSummary: View {
    let model: AppModel
    let disk: Disk

    private var used: Int64 {
        guard let mounted = disk.mounted else { return 0 }
        return max(mounted.total - mounted.free, 0)
    }

    /// Build folders, the rest of the folders, and what no folder holds:
    /// measured parts only. Before a scan, used space is one segment.
    private var segments: [StorageSegment] {
        guard disk.isConnected else { return [] }
        guard let root = model.diskOverview?.root else {
            return [StorageSegment(name: "Used", bytes: used, color: .accentColor)]
        }
        let builds = min(model.buildBytes(on: disk), root.total)
        return [
            StorageSegment(name: StatusSnapshot.Kind.buildFiles.title, bytes: builds, color: StatusSnapshot.Kind.buildFiles.color),
            StorageSegment(name: "Folders", bytes: root.total - builds, color: StatusSnapshot.Kind.yourFiles.color),
            StorageSegment(name: "Not in folders", bytes: max(used - root.total, 0), color: StatusSnapshot.Kind.system.color),
        ].filter { $0.bytes > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .lastTextBaseline) {
                    volume
                    Spacer()
                    available(alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 10) {
                    volume
                    available(alignment: .leading)
                }
            }

            if disk.isConnected, let mounted = disk.mounted {
                StorageBar(segments: segments, free: mounted.free, total: mounted.total)
                    .frame(height: 20)
                FlowLayout(spacing: 18, lineSpacing: 6) {
                    ForEach(segments) { segment in
                        if segment.name == "Not in folders" {
                            legendItem(segment)
                                .help("Used space that isn't in any folder Ballast measured: the file system's own bookkeeping, and anything in folders it couldn't read.")
                        } else {
                            legendItem(segment)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    private var volume: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(disk.name)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Group {
                if disk.isConnected {
                    Text("\(used.bytes) of \(disk.total.bytes) used · \(formatLine)")
                } else {
                    Text("\(disk.total.bytes) · \(formatLine)")
                }
            }
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
        .fixedSize()
    }

    private var formatLine: String {
        disk.isReadOnly ? "\(disk.format), read-only" : disk.format
    }

    @ViewBuilder
    private func available(alignment: HorizontalAlignment) -> some View {
        if let mounted = disk.mounted {
            VStack(alignment: alignment, spacing: 0) {
                Text(mounted.free.bytes)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(mounted.free)))
                Text("available")
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .animation(Motion.animation(.smooth(duration: 0.6)), value: mounted.free)
        }
    }
}

// MARK: Index state

/// Whether the drive's index is current and how it's kept that way: one
/// grouped card, or the Scan callout before the first scan.
private struct DiskState: View {
    let model: AppModel
    let disk: Disk
    let forget: () -> Void

    private var isScanningThis: Bool { model.scanningDisk == disk.uuid }

    var body: some View {
        if !disk.isScanned {
            firstScan
        } else {
            VStack(spacing: 0) {
                if !disk.isConnected {
                    note("externaldrive.badge.xmark", "Not connected",
                         "Last scanned \(scanned). Connect it to update the index, or forget it.") {
                        Button("Forget…", action: forget)
                    }
                } else if isScanningThis, let status = model.status {
                    progress(status)
                } else if disk.isJournaled {
                    note("arrow.triangle.2.circlepath", "Ballast follows changes on this drive",
                         "Scanned \(scanned). Update rechecks only what changed since then, even if the drive was unplugged in between.") {
                        Button("Update") { Task { await model.scanDisk(disk.uuid) } }
                            .disabled(model.isScanning)
                    }
                } else {
                    note("arrow.clockwise", "Ballast rescans this drive each time",
                         "Scanned \(scanned). It can't follow changes on \(disk.format) drives, so Rescan measures everything again.") {
                        Button("Rescan") { Task { await model.scanDisk(disk.uuid, full: true) } }
                            .disabled(model.isScanning)
                    }
                }
                if disk.isConnected && disk.isReadOnly {
                    Divider().padding(.leading, 44)
                    note("lock", "This drive is read-only",
                         "You can see what's on it, but Ballast can't clean anything here.") { EmptyView() }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var scanned: String {
        disk.scannedAt?.formatted(.relative(presentation: .named)) ?? "before"
    }

    /// Before the first scan: the one thing to do here, as a callout.
    @ViewBuilder
    private var firstScan: some View {
        if isScanningThis, let status = model.status {
            progress(status)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    symbol
                    message
                    Spacer(minLength: 12)
                    scanButton
                }
                HStack(alignment: .top, spacing: 16) {
                    symbol
                    VStack(alignment: .leading, spacing: 12) {
                        message
                        scanButton
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(18)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var symbol: some View {
        Image(systemName: disk.isRemovable ? "externaldrive" : "internaldrive")
            .font(.title)
            .foregroundStyle(.tint)
            .frame(width: 36)
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Ballast hasn't measured \(disk.name) yet")
                .font(.headline)
            Text(disk.isJournaled
                 ? "Other drives are only scanned when you ask. After the first scan, Update rechecks only what changed."
                 : "Other drives are only scanned when you ask. \(disk.format) drives are measured in full each time.")
                .foregroundStyle(.secondary)
        }
    }

    private var scanButton: some View {
        Button("Scan \(disk.name)") { Task { await model.scanDisk(disk.uuid, full: true) } }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isScanning)
    }

    private func progress(_ status: ScanStatus) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if let progress = model.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                ScanProgressView(status: status)
            }
            Button("Stop") { model.cancelScan() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func note<Action: View>(
        _ symbol: String, _ title: String, _ detail: String, @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// Folders on the drive Ballast couldn't read, named rather than hidden.
private struct LockedNote: View {
    let count: Int
    let disk: Disk

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count) folder\(count == 1 ? "" : "s") on \(disk.name) couldn't be read.")
                Text("They're shown as Locked. Full Disk Access lets Ballast read more of the drive; rescan after granting it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Open Settings") { Access.openFullDiskAccessSettings() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
