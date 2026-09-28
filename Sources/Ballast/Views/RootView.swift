import AppKit
import SwiftUI

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case explorer = "Explorer"
    case cleanup = "Suggestions"

    var id: Self { self }

    /// `ballast://overview`, `ballast://explorer` or `ballast://cleanup`,
    /// the links the widget opens.
    init?(link url: URL) {
        guard url.scheme == "ballast" else { return nil }
        switch url.host() {
        case "cleanup": self = .cleanup
        case "explorer": self = .explorer
        default: self = .overview
        }
    }

    var symbol: String {
        switch self {
        case .overview: "internaldrive"
        case .explorer: "square.grid.3x3.topleft.filled"
        case .cleanup: "lightbulb"
        }
    }
}

struct RootView: View {
    @Bindable var model: AppModel
    @State private var pane: Pane? = .overview
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Label(pane.rawValue, systemImage: pane.symbol).tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) { SidebarFooter(model: model) }
        } detail: {
            Group {
                if model.hasIndex {
                    switch pane ?? .overview {
                    case .overview:
                        OverviewView(model: model, open: navigate) { path in
                            Task { await model.open(path: path) }
                            pane = .explorer
                        }
                    case .explorer: ExplorerView(model: model)
                    case .cleanup:
                        CleanupView(model: model) { path in
                            Task { await model.open(path: path) }
                            pane = .explorer
                        }
                    }
                } else {
                    WelcomeView(model: model)
                }
            }
            // No screen sets a minimum width for the detail column. SwiftUI
            // turns the content's minimum, plus the sidebar and inspector
            // insets, into constraints on the split views, and in a window
            // too narrow for all three those fed back into themselves until
            // AppKit gave up with a layout-loop exception.
            .frame(minWidth: 0, maxWidth: .infinity)
            .navigationTitle(pane?.rawValue ?? "Ballast")
            .navigationSubtitle(model.statusLine)
            // Dropping onto any screen adds to the list and opens it.
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.add(urls: urls) }
                return true
            }
        }
        // On the split view, not inside its detail column: nested there, the
        // inspector's split view sized itself from its own width plus the
        // sidebar's, which crashed narrow windows (see the frame above).
        .inspector(isPresented: $model.isListShown) {
            CleanupListView(model: model)
                .inspectorColumnWidth(min: 300, ideal: 350, max: 480)
        }
        .toolbar {
            ToolbarItemGroup { ScanControls(model: model) }
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
            pane = linked
            // Not MainWindow.show(): at launch this window isn't visible
            // yet, and that would open a second one.
            NSApp.activate()
        }
    }

    /// E.g. Review Cleanup… in the menu bar item.
    private func showRequestedPane() {
        guard let requested = model.requestedPane else { return }
        pane = requested
        model.requestedPane = nil
    }

    private func navigate(_ target: Pane, _ folder: Int64?) {
        if let folder { model.open(folder) }
        pane = target
    }
}

private struct ScanControls: View {
    let model: AppModel

    var body: some View {
        if model.isScanning {
            Button("Stop", systemImage: "stop.fill") { model.cancelScan() }
                .help("Stop scanning; the saved index stays as it was")
        } else {
            Button("Update", systemImage: "arrow.clockwise") { Task { await model.update() } }
                .help("Rescan only folders that changed since last time")
                .keyboardShortcut("r")
                .disabled(!model.hasIndex)
            Menu {
                Button("Full Rescan", systemImage: "internaldrive") { Task { await model.fullScan() } }
                Button("Scan Locked Folders as Admin…", systemImage: "lock.open") {
                    Task { await model.rescanLockedAsAdmin() }
                }
                .disabled((model.overview?.lockedByPermissions ?? 0) == 0)
                Divider()
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
