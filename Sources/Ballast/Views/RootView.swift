import AppKit
import QuickLook
import SwiftUI

enum Pane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview = "Overview"
    case explorer = "Explorer"
    case cleanup = "Suggestions"
    case homebrew = "Homebrew"
    case worktrees = "Git Worktrees"

    var id: Self { self }

    /// `ballast://overview`, `ballast://explorer` or `ballast://cleanup`,
    /// the links the widget opens.
    init?(link url: URL) {
        guard url.scheme == "ballast" else { return nil }
        switch url.host() {
        case "cleanup": self = .cleanup
        case "homebrew": self = .homebrew
        case "worktrees": self = .worktrees
        case "explorer": self = .explorer
        default: self = .overview
        }
    }

    var symbol: String {
        switch self {
        case .overview: "internaldrive"
        case .explorer: "square.grid.3x3.topleft.filled"
        case .cleanup: "lightbulb"
        case .homebrew: "shippingbox"
        case .worktrees: "arrow.triangle.branch"
        }
    }
}

/// A sidebar row: one of the screens, or a disk in the Disks section,
/// which opens that disk's Overview.
enum SidebarItem: Hashable {
    case pane(Pane)
    case disk(DiskID)
}

struct RootView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarItem? = .pane(.overview)
    @State private var export: FolderExport?
    @State private var exportName = ""
    @State private var isExporting = false
    /// The window's width, which caps how wide the Cleanup List may get.
    @State private var windowWidth: CGFloat = 0
    @Environment(\.openWindow) private var openWindow

    private static let sidebarMaxWidth: CGFloat = 220
    private static let listMinWidth: CGFloat = 300

    /// The widest the Cleanup List can be in this window. The detail
    /// column's minimum width, as the split views see it, includes the
    /// inspector's width, so AppKit loops (and throws) once the part of the
    /// detail left beside the inspector is narrower than the inspector
    /// itself: sidebar + 2 × list must fit the window. The sidebar's maximum
    /// is fixed, so this is the window width alone, which the columns can't
    /// change.
    private var listMaxWidth: CGFloat {
        let fits = ((windowWidth - Self.sidebarMaxWidth) / 2 - 10).rounded(.down)
        return min(480, max(Self.listMinWidth, fits))
    }

    /// The screen on show: a disk row shows that disk's Overview.
    private var pane: Pane? {
        switch selection {
        case .pane(let pane): pane
        case .disk: .overview
        case nil: nil
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Pane.allCases) { pane in
                    Label(pane.rawValue, systemImage: pane.symbol).tag(SidebarItem.pane(pane))
                }
                // Only once there's another disk to pick.
                if !model.sidebarDisks.isEmpty {
                    Section("Disks") {
                        DiskRow(name: Paths.volumeName, symbol: "internaldrive", current: model.selectedDisk == .startup,
                                detail: "\(model.freeBytes.bytes) available")
                            .tag(SidebarItem.disk(.startup))
                        ForEach(model.sidebarDisks) { disk in
                            DiskRow(disk: disk, current: model.selectedDisk == .volume(disk.uuid))
                                .tag(SidebarItem.disk(.volume(disk.uuid)))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: Self.sidebarMaxWidth)
            .safeAreaInset(edge: .bottom) { SidebarFooter(model: model) }
            .onChange(of: selection) {
                if case .disk(let disk) = selection { Task { await model.selectDisk(disk) } }
            }
            // A forgotten drive's row is gone: land on the Overview it switched to.
            .onChange(of: model.selectedDisk) {
                if case .disk(let disk) = selection, disk != model.selectedDisk { selection = .pane(.overview) }
            }
        } detail: {
            Group {
                if pane == .homebrew {
                    HomebrewView()
                } else if pane == .worktrees {
                    WorktreesView()
                } else if case .volume = model.selectedDisk, pane != .cleanup {
                    // Another disk: its Overview and Explorer, whether or
                    // not the startup disk has been scanned.
                    switch pane ?? .overview {
                    case .explorer: ExplorerView(model: model)
                    default: DiskOverviewView(model: model) { folder in navigate(.explorer, folder) }
                    }
                } else if model.hasIndex {
                    switch pane ?? .overview {
                    case .overview:
                        OverviewView(model: model, open: navigate) { path in
                            Task { await model.open(path: path) }
                            selection = .pane(.explorer)
                        }
                    case .explorer: ExplorerView(model: model)
                    case .homebrew: HomebrewView()
                    case .worktrees: WorktreesView()
                    case .cleanup:
                        CleanupView(model: model) { path in
                            Task { await model.open(path: path) }
                            selection = .pane(.explorer)
                        }
                    }
                } else {
                    WelcomeView(model: model)
                }
            }
            // No screen sets a minimum width for the detail column: SwiftUI
            // adds it to the sidebar and inspector widths in the split views'
            // constraints (see listMaxWidth).
            .frame(minWidth: 0, maxWidth: .infinity)
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            // Dropping onto any screen adds to the list and opens it.
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.add(urls: urls) }
                return true
            }
        }
        // On the split view, not inside its detail column: nested there, the
        // inspector's split view sized itself from its own width plus the
        // sidebar's, which crashed narrow windows.
        .inspector(isPresented: $model.isListShown) {
            CleanupListView(model: model)
                .inspectorColumnWidth(min: Self.listMinWidth, ideal: min(350, listMaxWidth), max: listMaxWidth)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .toolbar {
            ToolbarItemGroup { ScanControls(model: model, export: exportAction) }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button {
                    model.isListShown.toggle()
                } label: {
                    Label("Cleanup List", systemImage: model.plan.isEmpty ? "tray" : "tray.full.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .badge(model.plan.count)
                .help("Show the Cleanup List (\(model.plan.count) items)")
            }
        }
        .sheet(isPresented: $model.isHistoryShown) {
            CleanupHistorySheet(model: model)
        }
        .quickLookPreview($model.quickLookURL)
        // The save panel's format menu picks CSV or JSON.
        .fileExporter(isPresented: $isExporting, document: export, contentTypes: FolderExport.readableContentTypes,
                      defaultFilename: exportName) { _ in export = nil }
        .focusedSceneValue(\.exportAction, exportAction)
        .focusedSceneValue(\.findAction, FindAction {
            selection = .pane(.explorer)
            model.searchRequested = true
        })
        .alert(item: Binding(get: { model.refusal }, set: { _ in model.dismissRefusal() })) { refusal in
            Alert(title: Text("Can't add \(refusal.name)"), message: Text(refusal.reason))
        }
        .task { await model.start() }
        .onAppear {
            MainWindow.openWindow = openWindow
            showRequestedPane()
        }
        .onChange(of: model.requestedPane) { showRequestedPane() }
        // Widget links land in this window rather than a new one; with no
        // window open, SwiftUI opens one and delivers the link to it.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL { url in
            guard let linked = Pane(link: url) else { return }
            selection = .pane(linked)
            // Not MainWindow.show(): at launch this window isn't visible
            // yet, and that would open a second one.
            NSApp.activate()
        }
    }

    /// File › Export… for what the window shows: the open folder's
    /// children in Explorer, the largest folders on the Overview.
    private var exportAction: ExportAction? {
        guard model.activeOverview != nil else { return nil }
        switch pane ?? .overview {
        case .explorer:
            guard let folder = model.trail.last, !model.children.isEmpty else { return nil }
            let name = model.trail.count == 1 ? model.activeDiskName : folder.name
            return ExportAction(title: "Export Folder List…") { startExport(model.explorerExport, name: "\(name) folders") }
        case .overview:
            guard !model.activeHotspots.isEmpty else { return nil }
            return ExportAction(title: "Export Largest Folders…") { startExport(model.hotspotExport, name: "Largest folders") }
        case .cleanup, .homebrew, .worktrees:
            return nil
        }
    }

    private func startExport(_ rows: [ExportRow], name: String) {
        model.noteFeature(.export)
        export = FolderExport(rows: rows)
        exportName = name
        isExporting = true
    }

    /// E.g. Review Cleanup… in the menu bar item.
    private func showRequestedPane() {
        guard let requested = model.requestedPane else { return }
        selection = .pane(requested)
        model.requestedPane = nil
    }

    private func navigate(_ target: Pane, _ folder: Int64?) {
        if let folder { model.open(folder) }
        selection = .pane(target)
    }

    private var title: String {
        if case .disk = selection { return model.activeDiskName }
        return pane?.rawValue ?? "Ballast"
    }

    /// Status, and which disk Overview and Explorer are showing once there's
    /// more than one to choose from.
    private var subtitle: String {
        if pane == .homebrew { return "Manage installed formulae and casks" }
        if pane == .worktrees { return "Review working copies anywhere on disk" }
        let status = model.statusLine(for: model.selectedDisk)
        guard !model.sidebarDisks.isEmpty, pane != .cleanup, !model.isScanning else { return status }
        if case .disk = selection { return status }
        return status.isEmpty ? model.activeDiskName : "\(model.activeDiskName) · \(status)"
    }
}

/// A disk in the sidebar. The disk Overview and Explorer show has a filled
/// symbol; one that's unplugged is dimmed.
private struct DiskRow: View {
    let name: String
    let symbol: String
    let current: Bool
    let detail: String
    var connected = true

    init(name: String, symbol: String, current: Bool, detail: String) {
        self.name = name
        self.symbol = symbol
        self.current = current
        self.detail = detail
    }

    init(disk: Disk, current: Bool) {
        name = disk.name
        symbol = disk.isRemovable ? "externaldrive" : "internaldrive"
        self.current = current
        connected = disk.isConnected
        detail = !disk.isConnected ? "Not connected"
            : disk.isScanned ? "\((disk.mounted?.free ?? 0).bytes) available" : "Not scanned yet"
    }

    var body: some View {
        Label {
            Text(name).lineLimit(1)
        } icon: {
            Image(systemName: current ? symbol + ".fill" : symbol)
        }
        .foregroundStyle(connected ? .primary : .secondary)
        .help("\(name): \(detail)")
        .accessibilityValue(current ? "\(detail), shown" : detail)
    }
}

private struct ScanControls: View {
    let model: AppModel
    let export: ExportAction?

    /// Update acts on the disk on screen: a drive with a change log
    /// (APFS, Mac OS Extended) is updated, any other drive rescanned.
    private var updateHelp: String {
        guard let disk = model.selectedDiskInfo else { return "Rescan only folders that changed since last time" }
        if !disk.isConnected { return "\(disk.name) isn't connected" }
        return disk.isJournaled && disk.isScanned ? "Rescan only folders on \(disk.name) that changed since last time"
            : "Scan \(disk.name) again"
    }

    private var canUpdate: Bool {
        guard let disk = model.selectedDiskInfo else { return model.hasIndex }
        return disk.isConnected && disk.isScanned
    }

    var body: some View {
        if model.isScanning {
            Button("Stop", systemImage: "stop.fill") { model.cancelScan() }
                .help("Stop scanning; the saved index stays as it was")
        } else {
            Button("Update", systemImage: "arrow.clockwise") { Task { await model.updateSelectedDisk() } }
                .help(updateHelp)
                .keyboardShortcut("r")
                .disabled(!canUpdate)
            Menu {
                Button("Full Rescan", systemImage: "internaldrive") { Task { await model.rescanSelectedDisk() } }
                    .disabled(model.selectedDiskInfo.map { !$0.isConnected } ?? false)
                Button("Scan Locked Folders as Admin…", systemImage: "lock.open") {
                    Task { await model.rescanLockedAsAdmin() }
                }
                .disabled(model.selectedDisk != .startup || (model.overview?.lockedByPermissions ?? 0) == 0)
                Divider()
                if let export {
                    Button(export.title, systemImage: "square.and.arrow.up", action: export.perform)
                }
                Button("Cleanup History…", systemImage: "clock.arrow.circlepath") { model.isHistoryShown = true }
                Button("Full Disk Access Settings…", systemImage: "hand.raised") { Access.openFullDiskAccessSettings() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

private struct SidebarFooter: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = model.status {
                VStack(alignment: .leading, spacing: 4) {
                    if let progress = model.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(status.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .transition(.opacity)
            } else if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            Divider().padding(.vertical, 2)
            Text("\(model.freeBytes.bytes) available")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(model.freeBytes)))
            SizeBar(fraction: model.totalBytes > 0 ? Double(model.usedBytes) / Double(model.totalBytes) : 0,
                    tint: model.freeBytes * 10 < model.totalBytes ? .red : .accentColor)
                .frame(height: 5)
            Text("of \(model.totalBytes.bytes)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(14)
        .animation(Motion.animation(.smooth), value: model.status == nil)
        .animation(Motion.animation(.smooth(duration: 0.6)), value: model.freeBytes)
    }
}

/// First run: one clear step.
private struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 8) {
                Text(model.isScanning ? "Measuring your disk…" : "See what's taking up space")
                    .font(.largeTitle.weight(.semibold))
                Text("Ballast measures every folder once, about two minutes. After that it only rechecks what changed, so it opens instantly.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
            }

            if let status = model.status {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView().progressViewStyle(.linear)
                    ScanProgressView(status: status)
                }
                .frame(width: 380)
            } else {
                Button("Scan Disk") { Task { await model.fullScan() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.defaultAction)
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }

            if !model.hasFullDiskAccess && !model.isScanning {
                HStack(spacing: 6) {
                    Text("For a complete picture, allow Full Disk Access first.")
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { Access.openFullDiskAccessSettings() }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
