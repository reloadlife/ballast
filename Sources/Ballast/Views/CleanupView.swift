import AppKit
import SwiftUI

/// Suggestion sections in reading order: what comes back on its own
/// first, then what needs a decision.
private enum SuggestionSection: Hashable, Identifiable {
    case category(Category)
    case installers
    case unusedApps

    var id: Self { self }

    static let order: [SuggestionSection] = [
        .category(.caches), .category(.artifacts), .installers, .category(.stale),
        .unusedApps, .category(.developer), .category(.appData), .category(.personal),
    ]
}

/// Suggestions: known caches, build files, installers, big untouched
/// folders and unused apps, each one click away from the Cleanup List.
struct CleanupView: View {
    let model: AppModel
    let explore: (String) -> Void

    var body: some View {
        List {
            Section { summary }
                .listRowSeparator(.hidden)

            ForEach(SuggestionSection.order) { section in
                switch section {
                case .category(let category): categorySection(category)
                case .installers: installersSection
                case .unusedApps: unusedAppsSection
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func categorySection(_ category: Category) -> some View {
        let rows = model.cleanup(in: category)
        if !rows.isEmpty {
            Section {
                if category == .artifacts {
                    // Build folders, one group per kind.
                    ForEach(kindGroups(rows), id: \.kind) { group in
                        KindGroup(model: model, kind: group.kind, rows: group.rows, explore: explore)
                    }
                } else {
                    ForEach(rows) { suggestionRow($0, largest: rows[0].bytes) }
                }
            } header: {
                header(category.title(staleMonths: model.preferences.staleMonths), advice: category.advice,
                       total: model.total(in: category)) {
                    if category == .artifacts {
                        Button("Add Ones Older Than 3 Months") {
                            withAnimation(Motion.animation(.snappy)) { addArtifacts(olderThan: 90) }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var installersSection: some View {
        let rows = model.installers
        if !rows.isEmpty {
            Section {
                ForEach(rows) { installer in
                    InstallerRow(
                        installer: installer, largest: rows[0].bytes,
                        item: model.listItem(for: installer),
                        planned: model.isPlanned(installer.path),
                        toggle: { withAnimation(Motion.animation(.snappy)) { model.toggle(model.listItem(for: installer)) } },
                        eject: { Task { await model.eject(installer) } }
                    )
                }
            } header: {
                header("Installers & Disk Images", advice: "You can download them again if you need them.",
                       total: rows.reduce(0) { $0 + $1.bytes }) {
                    Button("Add All") {
                        withAnimation(Motion.animation(.snappy)) {
                            for installer in rows where installer.mountedAs == nil && !model.isPlanned(installer.path) {
                                model.toggle(model.listItem(for: installer))
                            }
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder
    private var unusedAppsSection: some View {
        let rows = model.unusedApps
        if !rows.isEmpty {
            Section {
                ForEach(rows) { unused in
                    UnusedAppRow(
                        unused: unused, largest: rows[0].bytes,
                        item: model.listItem(for: unused),
                        planned: model.isPlanned(unused.app.path),
                        toggle: { withAnimation(Motion.animation(.snappy)) { model.toggle(model.listItem(for: unused)) } }
                    )
                }
            } header: {
                header("Unused Apps", advice: "Not opened for \(staleSpan). Uninstalling moves the app and its data to the Trash.",
                       total: rows.reduce(0) { $0 + $1.bytes }) { EmptyView() }
            }
        }
    }

    /// "6+ months", "1+ year": the stale threshold from Settings.
    private var staleSpan: String {
        let months = model.preferences.staleMonths
        guard months % 12 == 0 else { return "\(months)+ months" }
        return "\(months / 12)+ year\(months == 12 ? "" : "s")"
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.reclaimable.bytes) can be cleaned safely")
                    .font(.title2.weight(.semibold))
                Text("Add items to the Cleanup List with \(Image(systemName: "plus.circle")), then press Clean Up. Nothing is removed until you do.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Add All Safe Items") {
                withAnimation(Motion.animation(.snappy)) { addSafe() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("Add every cache and build folder to the Cleanup List")
        }
        .padding(.vertical, 12)
    }

    private func suggestionRow(_ result: ScanResult, largest: Int64) -> some View {
        SuggestionRow(
            result: result, largest: largest,
            item: model.listItem(for: result),
            planned: model.isPlanned(result.target.path),
            toggle: { withAnimation(Motion.animation(.snappy)) { model.toggle(result) } },
            explore: { explore(result.target.path) }
        )
    }

    private func kindGroups(_ rows: [ScanResult]) -> [(kind: ArtifactKind, rows: [ScanResult])] {
        Dictionary(grouping: rows.filter { $0.kind != nil }, by: { $0.kind! })
            .map { (kind: $0.key, rows: $0.value) }
            .sorted { $0.rows.reduce(0) { $0 + $1.bytes } > $1.rows.reduce(0) { $0 + $1.bytes } }
    }

    private func header<Accessory: View>(
        _ title: String, advice: String, total: Int64, @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.headline)
            Text(advice).foregroundStyle(.secondary)
            Spacer()
            accessory()
            Text(total.bytes)
                .font(.headline)
                .monospacedDigit()
        }
        .padding(.top, 10)
    }

    private func addSafe() {
        for result in model.safeSuggestions where !model.isPlanned(result.target.path) {
            model.toggle(result)
        }
    }

    private func addArtifacts(olderThan days: Double) {
        let cutoff = Int64(Date.now.addingTimeInterval(-days * 86_400).timeIntervalSince1970)
        for result in model.cleanup(in: .artifacts) where result.newest < cutoff && !model.isPlanned(result.target.path) {
            model.toggle(result)
        }
    }
}

private struct SuggestionRow: View {
    let result: ScanResult
    let largest: Int64
    let item: PlanItem?
    let planned: Bool
    let toggle: () -> Void
    let explore: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            if item != nil {
                ListToggle(item: item, isOn: planned, action: toggle)
            } else {
                Image(systemName: "eye")
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)
                    .help("Review this one yourself in Explorer")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(result.target.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hovered {
                Button(action: explore) { Image(systemName: "arrow.right.circle") }
                    .buttonStyle(.borderless)
                    .help("Open in Explorer")
            }
            AgeBadge(newest: result.newest)
                .frame(width: 80, alignment: .trailing)
            SizeBar(fraction: largest > 0 ? Double(result.bytes) / Double(largest) : 0)
                .frame(width: 80, height: 5)
            Text(result.bytes.bytes)
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .draggable(URL(fileURLWithPath: result.target.path))
        .contextMenu {
            Button("Open in Explorer", action: explore)
            Button("Show in Finder") { Finder.reveal(result.target.path) }
            if let hint = result.target.hint {
                Button("Copy Command") { Finder.copy(hint) }
            }
        }
    }

    private var detail: String {
        let path = result.target.path.replacingOccurrences(of: Catalog.home, with: "~")
        if let action = result.target.action, case .command(let command) = action {
            return "\(path) · runs \(command)"
        }
        return path
    }
}

/// One kind of build folder: a summary line that expands to the folders.
private struct KindGroup: View {
    let model: AppModel
    let kind: ArtifactKind
    let rows: [ScanResult]
    let explore: (String) -> Void
    @State private var expanded = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let total = rows.reduce(0) { $0 + $1.bytes }
        let rule = model.autoClean.rule(for: kind)
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(rows) { result in
                SuggestionRow(
                    result: result, largest: rows[0].bytes,
                    item: model.listItem(for: result),
                    planned: model.isPlanned(result.target.path),
                    toggle: { withAnimation(Motion.animation(.snappy)) { model.toggle(result) } },
                    explore: { explore(result.target.path) }
                )
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.title)
                    Text("\(rows.count) folder\(rows.count == 1 ? "" : "s") · back with \(kind.rebuild)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(rule.enabled ? "Auto: after \(rule.days) day\(rule.days == 1 ? "" : "s")" : "Auto-clean…") {
                    SettingsTab.select(.autoClean)
                    openSettings()
                }
                .buttonStyle(.link)
                .help(rule.enabled ? "Change this rule in Settings" : "Clean these automatically when a project goes unused")
                Button("Add All") {
                    withAnimation(Motion.animation(.snappy)) {
                        for result in rows where !model.isPlanned(result.target.path) {
                            if let item = model.listItem(for: result), item.safety.level != .blocked { model.toggle(item) }
                        }
                    }
                }
                .controlSize(.small)
                Text(total.bytes)
                    .monospacedDigit()
                    .frame(width: 76, alignment: .trailing)
            }
            .padding(.vertical, 2)
        }
    }
}

/// An app nobody has opened in a while: what uninstalling it would free.
private struct UnusedAppRow: View {
    let unused: UnusedApp
    let largest: Int64
    let item: PlanItem
    let planned: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ListToggle(item: item, isOn: planned, action: toggle)
                .frame(width: 20)

            Image(nsImage: Icons.icon(for: unused.app.path))
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(unused.app.name)
                    .lineLimit(1)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SizeBar(fraction: largest > 0 ? Double(unused.bytes) / Double(largest) : 0)
                .frame(width: 80, height: 5)
            Text(unused.bytes.bytes)
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(item.safety.reason)
        .contextMenu {
            Button("Show in Finder") { Finder.reveal(unused.app.path) }
            if unused.lock == .appManagement {
                Button("Open App Management Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!)
                }
            }
            if !unused.data.isEmpty {
                Button("Show Data in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(unused.data.map { URL(fileURLWithPath: $0) })
                }
            }
        }
    }

    private var detail: String {
        let opened = unused.lastUsed.map { "Last opened \($0.formatted(.relative(presentation: .named)))" }
            ?? "No record of being opened"
        let sizes = unused.dataBytes > 0
            ? "App \(unused.appBytes.bytes) + data \(unused.dataBytes.bytes)"
            : "App \(unused.appBytes.bytes)"
        // Apps of the same name in different folders (Python 3.12, 3.13).
        let folder = (unused.app.path as NSString).deletingLastPathComponent
        let inSubfolder = !AppLocations.standard.roots.contains(folder)
        return inSubfolder ? "\((folder as NSString).lastPathComponent) · \(opened) · \(sizes)" : "\(opened) · \(sizes)"
    }

    /// Why it can't simply go, or where it can come back from.
    private var note: String? {
        var notes: [String] = []
        switch unused.lock {
        case .admin: notes.append("Needs an administrator to remove")
        case .appManagement: notes.append("Needs App Management permission to remove")
        case nil: break
        }
        if unused.installsSystemComponents { notes.append("Installs system components") }
        if unused.fromAppStore { notes.append("Reinstall from the App Store") }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }
}

/// A downloaded installer or disk image.
private struct InstallerRow: View {
    let installer: Installer
    let largest: Int64
    let item: PlanItem
    let planned: Bool
    let toggle: () -> Void
    let eject: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // A mounted image is ejected first; it gets its list toggle back after.
            ListToggle(item: installer.mountedAs == nil ? item : nil, isOn: planned, action: toggle)
                .frame(width: 20)

            Image(nsImage: Icons.icon(for: installer.path))
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(installer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if installer.mountedAs != nil {
                Button("Eject", action: eject)
                    .controlSize(.small)
                    .help("Eject this disk image so it can be cleaned")
            }
            SizeBar(fraction: largest > 0 ? Double(installer.bytes) / Double(largest) : 0)
                .frame(width: 80, height: 5)
            Text(installer.bytes.bytes)
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .draggable(URL(fileURLWithPath: installer.path))
        .contextMenu {
            Button("Show in Finder") { Finder.reveal(installer.path) }
        }
    }

    /// Most telling first; the folder is what gets cut when space runs out.
    private var detail: String {
        var parts: [String] = []
        if installer.mountedAs != nil { parts.append("Mounted") }
        if let added = installer.added { parts.append("Added \(added.formatted(.relative(presentation: .named)))") }
        if let app = installer.installedApp { parts.append("\(app) is installed") }
        parts.append((installer.path as NSString).deletingLastPathComponent.replacingOccurrences(of: Catalog.home, with: "~"))
        return parts.joined(separator: " · ")
    }
}
