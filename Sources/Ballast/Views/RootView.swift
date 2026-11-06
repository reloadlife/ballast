import AppKit
import QuickLook
import SwiftUI

enum Pane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview = "Overview"
    case explorer = "Explorer"
    case cleanup = "Suggestions"
    case health = "Health"
    case homebrew = "Homebrew"
    case worktrees = "Git Worktrees"

    var id: Self { self }

    /// `ballast://overview`, `ballast://explorer` or `ballast://cleanup`,
    /// the links the widget opens.
    init?(link url: URL) {
        guard url.scheme == "ballast" else { return nil }
        switch url.host() {
        case "cleanup": self = .cleanup
        case "health": self = .health
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
        case .health: "heart.text.clipboard"
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

/// The screen the detail column shows. Its identity drives the pane
/// transition, so each distinct screen surfaces with its own blur-crossfade.
private enum DetailScreen: Hashable {
    case welcome
    case overview
    /// Another disk's Overview, whether or not the startup disk is scanned.
    case diskOverview
    case explorer(onOtherDisk: Bool)
    case suggestions
    case health
    case homebrew
    case worktrees
}

struct RootView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarItem? = .pane(.overview)
    @State private var export: FolderExport?
    @State private var exportName = ""
    @State private var isExporting = false
    /// How wide the Cleanup List may get in this window (see
    /// `listMaxWidth(windowWidth:)`). Stored instead of the window's width,
    /// so a live resize redraws the window only when this cap changes.
    @State private var listMaxWidth = RootView.listMaxWidth(windowWidth: 0)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated private static let sidebarMaxWidth: CGFloat = 220
    nonisolated private static let listMinWidth: CGFloat = 300

    /// The widest the Cleanup List can be in this window. The detail
    /// column's minimum width, as the split views see it, includes the
    /// inspector's width, so AppKit loops (and throws) once the part of the
    /// detail left beside the inspector is narrower than the inspector
    /// itself: sidebar + 2 × list must fit the window. The sidebar's maximum
    /// is fixed, so this is the window width alone, which the columns can't
    /// change. Rounded down to 8 pt steps, which only ever narrows the cap.
    nonisolated private static func listMaxWidth(windowWidth: CGFloat) -> CGFloat {
        let fits = (((windowWidth - sidebarMaxWidth) / 2 - 10) / 8).rounded(.down) * 8
        return min(480, max(listMinWidth, fits))
    }

    /// The screen on show: a disk row shows that disk's Overview.
    private var pane: Pane? {
        switch selection {
        case .pane(let pane): pane
        case .disk: .overview
        case nil: nil
        }
    }

    private var screen: DetailScreen {
        let onOtherDisk = if case .volume = model.selectedDisk { true } else { false }
        switch pane ?? .overview {
        case .health: return .health
        case .homebrew: return .homebrew
        case .worktrees: return .worktrees
        case .overview:
            if onOtherDisk { return .diskOverview }
            return model.hasIndex ? .overview : .welcome
        case .explorer:
            return onOtherDisk || model.hasIndex ? .explorer(onOtherDisk: onOtherDisk) : .welcome
        case .cleanup:
            // Suggestions are the startup disk's, on any disk.
            return model.hasIndex ? .suggestions : .welcome
        }
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: Self.sidebarMaxWidth)
        } detail: {
            // Keep a concrete detail host across destinations. A Group forwards
            // each destination's root (and toolbar preferences) directly to the
            // split view; switching to the developer lists can displace the
            // sidebar and header outside the window on macOS.
            ZStack(alignment: .topLeading) {
                detail(screen)
                    .id(screen)
                    .transition(.pane(reduceMotion: reduceMotion))
            }
            .animation(Motion.pane(reduceMotion: reduceMotion), value: screen)
            // The dock floats over the bottom of every screen; the inset
            // gives scrolling content a bottom margin so it never covers it,
            // and the margin eases in and out with the dock.
            .modifier(DockInset(model: model))
            // One plate per window: with the Cleanup List open and items
            // ready, its Clean Up is the primary action, so the screen's
            // own plate steps down.
            .environment(\.inkYields, model.isListShown && !model.readyItems.isEmpty)
            // No screen sets a minimum width for the detail column: SwiftUI
            // adds it to the sidebar and inspector widths in the split views'
            // constraints (see listMaxWidth). This flexible frame also keeps
            // the dock's own width out of those constraints.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background(Theme.water)
            .navigationTitle(title)
            .modifier(StatusSubtitle(model: model, pane: pane, diskRowSelected: isDiskRowSelected))
            // Dropping onto any screen adds to the list; the dock shows it.
            .modifier(ListDropTarget(model: model))
        }
        // On the split view, not inside its detail column: nested there, the
        // inspector's split view sized itself from its own width plus the
        // sidebar's, which crashed narrow windows.
        .inspector(isPresented: $model.isListShown) {
            CleanupListView(model: model)
                // Any height, like the detail column. Unclamped, the list's
                // header, rows and footer made the inspector's hosting view
                // ask for its content's full height (938 pt with two items).
                // When the window had less, the column's minimum height
                // flipped between that and that plus the toolbar on every
                // pass as the inspector opened, and AppKit threw "more
                // Update Constraints in Window passes than there are views".
                // The list scrolls inside whatever height it gets.
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .inspectorColumnWidth(min: Self.listMinWidth, ideal: min(350, listMaxWidth), max: listMaxWidth)
        }
        .onGeometryChange(for: CGFloat.self) { Self.listMaxWidth(windowWidth: $0.size.width) } action: {
            listMaxWidth = $0
        }
        .toolbar {
            ToolbarItemGroup { ScanControls(model: model, pane: pane, startExport: startExport) }
            ToolbarSpacer(.fixed)
            ToolbarItem { CleanupListButton(model: model) }
        }
        .sheet(isPresented: $model.isHistoryShown) {
            CleanupHistorySheet(model: model)
        }
        .quickLookPreview($model.quickLookURL)
        // The save panel's format menu picks CSV or JSON.
        .fileExporter(isPresented: $isExporting, document: export, contentTypes: FolderExport.readableContentTypes,
                      defaultFilename: exportName) { _ in export = nil }
        .modifier(ExportFocus(model: model, pane: pane, startExport: startExport))
        .focusedSceneValue(\.findAction, FindAction {
            selection = .pane(.explorer)
            model.searchRequested = true
        })
        .alert(model.refusal.map { "Can't add \($0.name)" } ?? "",
               isPresented: Binding(get: { model.refusal != nil }, set: { if !$0 { model.dismissRefusal() } }),
               presenting: model.refusal) { _ in
            Button("OK") {}
        } message: { refusal in
            Text(refusal.reason)
        }
        .modifier(DropRelay(model: model))
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

    @ViewBuilder
    private func detail(_ screen: DetailScreen) -> some View {
        switch screen {
        case .welcome: WelcomeView(model: model)
        case .overview: OverviewView(model: model, open: navigate) { path in explore(path) }
        case .diskOverview: DiskOverviewView(model: model) { folder in navigate(.explorer, folder) }
        case .explorer: ExplorerView(model: model)
        case .suggestions: CleanupView(model: model) { path in explore(path) }
        case .health: HealthView()
        case .homebrew: HomebrewView()
        case .worktrees: WorktreesView(model: model)
        }
    }

    private var isDiskRowSelected: Bool {
        if case .disk = selection { return true }
        return false
    }

    /// File › Export… for what the window shows: the open folder's
    /// children in Explorer, the largest folders on the Overview. Built
    /// where it's used (the More menu, the focused scene value), so the
    /// window doesn't redraw as Explorer opens folders.
    @MainActor
    fileprivate static func exportAction(model: AppModel, pane: Pane?,
                                         start: @escaping ([ExportRow], String) -> Void) -> ExportAction? {
        guard model.activeOverview != nil else { return nil }
        switch pane ?? .overview {
        case .explorer:
            guard let folder = model.trail.last, !model.children.isEmpty else { return nil }
            let name = model.trail.count == 1 ? model.activeDiskName : folder.name
            return ExportAction(id: "explorer:\(model.activeDiskName):\(folder.id)", title: "Export Folder List…") {
                start(model.explorerExport, "\(name) folders")
            }
        case .overview:
            guard !model.activeHotspots.isEmpty else { return nil }
            return ExportAction(id: "overview:\(model.activeDiskName)", title: "Export Largest Folders…") {
                start(model.hotspotExport, "Largest folders")
            }
        case .cleanup, .health, .homebrew, .worktrees:
            return nil
        }
    }

    private func startExport(_ rows: [ExportRow], _ name: String) {
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

    private func explore(_ path: String) {
        Task { await model.open(path: path) }
        selection = .pane(.explorer)
    }

    private var title: String {
        if isDiskRowSelected { return model.activeDiskName }
        return pane?.rawValue ?? "Ballast"
    }
}

// MARK: Toolbar subtitle

/// Status, and which disk Overview and Explorer are showing once there's
/// more than one to choose from. A modifier, so the status changing twice a
/// second during a scan redraws only this, not the window's screens.
private struct StatusSubtitle: ViewModifier {
    let model: AppModel
    let pane: Pane?
    let diskRowSelected: Bool

    func body(content: Content) -> some View {
        content.navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        if pane == .health { return "Storage, security, and known package vulnerabilities" }
        if pane == .homebrew { return "Manage installed formulae and casks" }
        if pane == .worktrees { return "Review working copies anywhere on disk" }
        let status = model.statusLine(for: model.selectedDisk)
        guard !model.sidebarDisks.isEmpty, pane != .cleanup, !model.isScanning else { return status }
        if diskRowSelected { return status }
        return status.isEmpty ? model.activeDiskName : "\(model.activeDiskName) · \(status)"
    }
}

/// The export action as a focused scene value, read here rather than in
/// RootView's body for the same reason as StatusSubtitle.
private struct ExportFocus: ViewModifier {
    let model: AppModel
    let pane: Pane?
    let startExport: ([ExportRow], String) -> Void

    func body(content: Content) -> some View {
        content.focusedSceneValue(\.exportAction, RootView.exportAction(model: model, pane: pane, start: startExport))
    }
}

// MARK: Drop ballast

/// Fires the drop moment's stage from each cleanup report: items moved to
/// the Trash drain into the Trash band (stage 1); space actually freed, by
/// Empty Trash or a permanent clean, drains into open water (stage 2). A
/// report that moved nothing still tells screens holding their figures to
/// let go. Which band the bytes leave is noted when the cleanup starts,
/// while the suggestions still list what it cleans.
private struct DropRelay: ViewModifier {
    let model: AppModel
    @Environment(\.ballastDrop) private var drop
    /// Cleanup List items' bands, from the start of the running cleanup.
    @State private var known: [String: DepthBar.Category] = [:]

    private struct Key: Equatable {
        let freed: Int64
        let trashed: Int64
        let outcomes: Int
        let record: UUID?
    }

    private var key: Key? {
        model.lastClean.map { Key(freed: $0.freed, trashed: $0.movedToTrash, outcomes: $0.outcomes.count, record: $0.record?.id) }
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: model.isDroppingBallast) { _, dropping in
                if dropping { known = model.depthCategories(of: model.readyItems) }
            }
            .onChange(of: key) { _, new in
                guard new != nil, let report = model.lastClean else { return }
                drop.play(model.dropStage(for: report, known: known))
                known = [:]
            }
    }
}

// MARK: Dock

/// The dock's bottom inset on the detail column. The inset's height
/// changing moves every screen's content by the dock's height, so the
/// change animates with the dock (layout in, exit out) instead of jumping.
/// A modifier, so the plan changing redraws only this, not RootView.
private struct DockInset: ViewModifier {
    let model: AppModel

    private var isShown: Bool { DockHost.isShown(model) }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) { DockHost(model: model) }
            .animation(Motion.animation(isShown ? Motion.layout : Motion.exit), value: isShown)
    }
}

/// Files and folders dropped from Finder onto any screen join the Cleanup
/// List. While something is dragged over, a sea hairline marks the target.
private struct ListDropTarget: ViewModifier {
    let model: AppModel
    @State private var isTargeted = false
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                Task { await model.add(urls: files) }
                return true
            } isTargeted: { targeted in
                Motion.with(targeted ? Motion.feedback : Motion.exit) { isTargeted = targeted }
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.sea, lineWidth: 2)
                        .background(Theme.sea.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .padding(8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
    }
}

/// Places the Ballast dock while the Cleanup List has something in it and
/// the inspector, which would show the same, is closed.
private struct DockHost: View {
    let model: AppModel

    static func isShown(_ model: AppModel) -> Bool {
        (!model.plan.isEmpty || model.measuring > 0) && !model.isListShown
    }

    private var isShown: Bool { Self.isShown(model) }

    var body: some View {
        ZStack {
            if isShown {
                BallastDock(count: model.plan.count, bytes: model.planBytes,
                            needsYou: model.plan.count(where: { !$0.isReady }), measuring: model.measuring) {
                    model.isListShown = true
                }
                .padding(.horizontal, Theme.Space.inset)
                .padding(.top, 8)
                .padding(.bottom, 14)
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)),
                                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))))
            }
        }
        .frame(maxWidth: .infinity)
        // Exits faster than entrances.
        .animation(Motion.animation(isShown ? Motion.layout : Motion.exit), value: isShown)
    }
}

/// The toolbar's Cleanup List toggle, a leaf so the plan changing redraws
/// only it.
private struct CleanupListButton: View {
    @Bindable var model: AppModel

    var body: some View {
        Button {
            model.isListShown.toggle()
        } label: {
            Label("Cleanup List", systemImage: model.plan.isEmpty ? "tray" : "tray.full.fill")
                .contentTransition(.symbolEffect(.replace))
        }
        .badge(model.plan.count)
        .keyboardShortcut("l", modifiers: [.command, .option])
        .help("Show the Cleanup List (\(model.plan.count) items)")
    }
}

// MARK: Sidebar

private struct Sidebar: View {
    let model: AppModel
    @Binding var selection: SidebarItem?

    var body: some View {
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
        .safeAreaInset(edge: .bottom) { SidebarFooter(model: model) }
        .onChange(of: selection) {
            if case .disk(let disk) = selection { Task { await model.selectDisk(disk) } }
        }
        // A forgotten drive's row is gone: land on the Overview it switched to.
        .onChange(of: model.selectedDisk) {
            if case .disk(let disk) = selection, disk != model.selectedDisk { selection = .pane(.overview) }
        }
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

// MARK: Scan controls

private struct ScanControls: View {
    let model: AppModel
    let pane: Pane?
    let startExport: ([ExportRow], String) -> Void

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
        // Only work the user started holds these back: a background update
        // leaves Update enabled, and pressing it takes over from that update.
        if model.isBusyWithUserWork {
            Button("Stop", systemImage: "stop.fill") { model.cancelScan() }
                .help("Stop; the saved index stays as it was")
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
                ExportMenuItem(model: model, pane: pane, startExport: startExport)
                Button("Cleanup History…", systemImage: "clock.arrow.circlepath") { model.isHistoryShown = true }
                Button("Full Disk Access Settings…", systemImage: "hand.raised") { Access.openFullDiskAccessSettings() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// The More menu's Export item, a leaf so Explorer opening folders redraws
/// only it, not the toolbar's scan controls.
private struct ExportMenuItem: View {
    let model: AppModel
    let pane: Pane?
    let startExport: ([ExportRow], String) -> Void

    var body: some View {
        if let export = RootView.exportAction(model: model, pane: pane, start: startExport) {
            Button(export.title, systemImage: "square.and.arrow.up", action: export.perform)
        }
    }
}

// MARK: Sidebar footer

private struct SidebarFooter: View {
    let model: AppModel

    private var isLow: Bool { model.totalBytes > 0 && model.freeBytes * 10 < model.totalBytes }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = model.status {
                VStack(alignment: .leading, spacing: 5) {
                    DepthProgress(fraction: model.progress)
                    Text(status.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .transition(.opacity)
            } else if let error = model.errorMessage {
                // Information, not a hazard to act on: no magenta.
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(error)
            }
            Divider().padding(.vertical, 2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Sounding(bytes: model.freeBytes, font: Theme.sounding.weight(.medium),
                         style: AnyShapeStyle(isLow ? Theme.hazard : Color.primary))
                Text("available").font(.callout).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            SizeBar(fraction: model.totalBytes > 0 ? Double(model.usedBytes) / Double(model.totalBytes) : 0,
                    tint: isLow ? Theme.hazard : Theme.sea)
                .frame(height: 5)
            Text("of \(model.totalBytes.bytes)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .animation(Motion.animation(model.status == nil ? Motion.exit : Motion.state), value: model.status == nil)
    }
}

// MARK: Welcome

/// First run: one clear step, on open water. While a saved index opens at
/// launch, the Overview's shape in skeleton instead, so the pitch and its
/// Scan button don't flash up for someone who has scanned before.
private struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        if model.hadIndexAtLaunch && model.status == nil {
            OpeningOverview { welcome }
        } else {
            welcome
        }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(model.isScanning ? "Measuring your disk…" : "See what's taking up space")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Ballast measures every folder once, about two minutes. After that it only rechecks what changed, so it opens instantly.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let status = model.status {
                ScanProgressView(status: status, fraction: model.progress, showsBar: true)
                    .frame(maxWidth: 380)
            } else {
                Button("Scan Disk") { Task { await model.fullScan() } }
                    .buttonStyle(.inkLarge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusyWithUserWork)
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                        .fixedSize(horizontal: false, vertical: true)
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
        .background { ContourField() }
    }
}
