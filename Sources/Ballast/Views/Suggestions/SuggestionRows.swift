import AppKit
import SwiftUI

// Suggestion rows, as views that take plain values (and closures for
// what they do), so they render in previews and snapshot tests. Every
// row ends on the byte column; every row that shows a location has
// "What is this?" with the row's own verdict.

/// The leading control of a row backed by a PlanItem: add, added, or no
/// control for what can't be cleaned.
private func addState(item: PlanItem?, planned: Bool) -> AddState {
    guard let item, item.safety.level != .blocked else { return .unavailable }
    return planned ? .added : .add
}

// MARK: Catalog suggestion

/// A known cache, tool folder or untouched folder.
struct SuggestionRow: View {
    let result: ScanResult
    let largest: Int64
    let item: PlanItem?
    let planned: Bool
    /// What the knowledge base says about it, when it knows the place.
    var explanation: KnowledgeExplanation?
    /// Untouched folders lead with when they last changed.
    var showsAge = false
    var toggle: () -> Void = {}
    var explore: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if item != nil {
                AddButton(state: addState(item: item, planned: planned), name: result.target.name, action: toggle)
            } else {
                Image(systemName: "eye")
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
                    .help("Review this one yourself in Explorer")
                    .accessibilityLabel("Review in Explorer")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(result.target.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let item {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        SafetyMark(level: item.safety.level)
                        Text(verdictLine(item))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Explore", action: explore)
                .buttonStyle(.borderless)
                .font(.subheadline)
                .foregroundStyle(Theme.sea)
                .help("Open in Explorer")
            if showsAge {
                AgeLabel(newest: result.newest)
                    .frame(width: 76, alignment: .trailing)
            }
            SuggestionShareBar(fraction: largest > 0 ? Double(result.bytes) / Double(largest) : 0)
            WhatIsThisButton(path: result.target.path, level: item?.safety.level)
            ByteColumn(bytes: result.bytes)
        }
        .padding(.vertical, Theme.Space.rowY)
        .contentShape(Rectangle())
        .rowHover()
        .draggable(URL(fileURLWithPath: result.target.path))
        .contextMenu {
            Button("Open in Explorer", action: explore)
            Button("Show in Finder") { Finder.reveal(result.target.path) }
            Button("Quick Look") { QuickLook.toggle(result.target.path) }
            if let hint = result.target.hint {
                Button("Copy Command") { Finder.copy(hint) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Where it is, and the command that cleans it when a tool does.
    private var detail: String {
        let path = homeRelative(result.target.path)
        if case .command(let command)? = result.target.action {
            return "\(path) · runs \(command)"
        }
        return path
    }

    /// For a plainly safe place the knowledge base knows, how it comes
    /// back says more than "safe"; otherwise the verdict's own reason.
    private func verdictLine(_ item: PlanItem) -> String {
        if item.safety.level == .safe, let explanation { return explanation.whenRemoved }
        return item.safety.reason
    }
}

// MARK: Build files

/// One kind of build folder: a summary that opens to the folders.
struct KindGroupRow<Rows: View>: View {
    let kind: ArtifactKind
    let count: Int
    let bytes: Int64
    let largest: Int64
    /// The auto-clean rule's state for this kind, as the link's title.
    let ruleTitle: String
    let ruleHelp: String
    var openRule: () -> Void = {}
    var addAll: () -> Void = {}
    @ViewBuilder var rows: Rows

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    Motion.with(Motion.layout) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        DisclosureChevron(expanded: expanded)
                        Image(systemName: kind.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.title)
                            Text("\(count) folder\(count == 1 ? "" : "s") · back with \(kind.rebuild)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(kind.title), \(count) folder\(count == 1 ? "" : "s")")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows the folders")

                Button(ruleTitle, action: openRule)
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .foregroundStyle(Theme.sea)
                    .help(ruleHelp)
                Button("Add All", action: addAll)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Add every \(kind.title.lowercased()) folder to the Cleanup List")
                SuggestionShareBar(fraction: largest > 0 ? Double(bytes) / Double(largest) : 0)
                ByteColumn(bytes: bytes)
            }
            .padding(.vertical, Theme.Space.rowY)
            .rowHover()

            if expanded {
                VStack(spacing: 0) { rows }
                    .padding(.leading, 24)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.exit)))
            }
        }
    }
}

// MARK: Unused app

/// An app nobody has opened in a while: what uninstalling it would free.
struct UnusedAppRow: View {
    let unused: UnusedApp
    let largest: Int64
    let item: PlanItem
    let planned: Bool
    let staleSpan: String
    var toggle: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            AddButton(state: addState(item: item, planned: planned), name: unused.app.name, action: toggle)
            Image(nsImage: Icons.icon(for: unused.app.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(unused.app.name)
                    .lineLimit(1)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    SafetyMark(level: item.safety.level)
                    Text(note ?? item.safety.reason)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SuggestionShareBar(fraction: largest > 0 ? Double(unused.bytes) / Double(largest) : 0)
            WhatIsThisButton(path: unused.app.path, level: item.safety.level)
            ByteColumn(bytes: unused.bytes)
        }
        .padding(.vertical, Theme.Space.rowY)
        .contentShape(Rectangle())
        .rowHover()
        .help(item.safety.reason)
        .contextMenu {
            Button("Show in Finder") { Finder.reveal(unused.app.path) }
            Button("Quick Look") { QuickLook.toggle(unused.app.path) }
            if unused.lock == .appManagement {
                Button("Open App Management Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            if !unused.data.isEmpty {
                Button("Show Data in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(unused.data.map { URL(fileURLWithPath: $0) })
                }
            }
        }
        .accessibilityElement(children: .contain)
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

// MARK: Installer

/// A downloaded installer or disk image.
struct InstallerRow: View {
    let installer: Installer
    let largest: Int64
    let item: PlanItem
    let planned: Bool
    var toggle: () -> Void = {}
    var eject: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            // A mounted image is ejected first; it gets its add button after.
            AddButton(state: installer.mountedAs == nil ? addState(item: item, planned: planned) : .unavailable,
                      name: installer.name, action: toggle)
            Image(nsImage: Icons.icon(for: installer.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(installer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if installer.mountedAs != nil {
                Button("Eject", action: eject)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Eject this disk image so it can be cleaned")
            }
            SuggestionShareBar(fraction: largest > 0 ? Double(installer.bytes) / Double(largest) : 0)
            WhatIsThisButton(path: installer.path, level: item.safety.level)
            ByteColumn(bytes: installer.bytes)
        }
        .padding(.vertical, Theme.Space.rowY)
        .contentShape(Rectangle())
        .rowHover()
        .draggable(URL(fileURLWithPath: installer.path))
        .contextMenu {
            Button("Show in Finder") { Finder.reveal(installer.path) }
            Button("Quick Look") { QuickLook.toggle(installer.path) }
        }
        .accessibilityElement(children: .contain)
    }

    /// Most telling first; the folder is what gets cut when space runs out.
    private var detail: String {
        var parts: [String] = []
        if installer.mountedAs != nil { parts.append("Mounted") }
        if let added = installer.added { parts.append("Added \(added.formatted(.relative(presentation: .named)))") }
        if let app = installer.installedApp { parts.append("\(app) is installed") }
        parts.append(homeRelative((installer.path as NSString).deletingLastPathComponent))
        return parts.joined(separator: " · ")
    }
}

// MARK: App caches

/// "Clear Slack's cache": one row per app, opening to its folders, each
/// with its size and whether something else on the list already cleans it.
struct AppCacheRow: View {
    let breakdown: AppCacheBreakdown
    let state: AddState
    let largest: Int64
    var add: () -> Void = {}

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AddButton(state: state, name: breakdown.title, coveredBy: coveredName, action: add)
                Button {
                    Motion.with(Motion.layout) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: Icons.icon(for: breakdown.appPath))
                            .resizable()
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(breakdown.title)
                                .lineLimit(1)
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        DisclosureChevron(expanded: expanded)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(breakdown.title)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows the folders")

                SuggestionShareBar(fraction: largest > 0 ? Double(breakdown.bytes) / Double(largest) : 0)
                ByteColumn(bytes: breakdown.bytes)
            }
            .padding(.vertical, Theme.Space.rowY)
            .rowHover()
            .contextMenu {
                Button("Show App in Finder") { Finder.reveal(breakdown.appPath) }
                if let first = breakdown.folders.first {
                    Button("Show Cache in Finder") { Finder.reveal(first.path) }
                }
            }

            if expanded {
                VStack(spacing: 0) {
                    ForEach(breakdown.folders) { folder in
                        folderRow(folder)
                    }
                }
                .padding(.leading, 68)
                .padding(.bottom, 6)
                .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(Motion.exit)))
            }
        }
    }

    private var subtitle: String {
        let count = breakdown.folders.count
        let folders = "\(count) folder\(count == 1 ? "" : "s")"
        let covered = breakdown.bytes - breakdown.uncoveredBytes
        guard covered > 0 else { return "\(folders) it rebuilds on its own" }
        return "\(folders) · \(covered.bytes) also counted under \(coveredName ?? "Caches")"
    }

    /// The Suggestions entry that already cleans part of it, by name.
    private var coveredName: String? {
        breakdown.folders.lazy.compactMap(\.coveredBy).first.map(Self.targetName)
    }

    static func targetName(_ path: String) -> String {
        Catalog.targets.first { $0.path == path }?.name ?? homeRelative(path)
    }

    private func folderRow(_ folder: AppCacheFolder) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.label)
                    .font(.callout)
                Text(homeRelative(folder.path))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let covered = folder.coveredBy {
                    Text("Also cleaned by \(Self.targetName(covered))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WhatIsThisButton(path: folder.path)
            ByteColumn(bytes: folder.bytes, font: Theme.soundingSmall, dimmed: folder.coveredBy != nil)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Show in Finder") { Finder.reveal(folder.path) }
            Button("Quick Look") { QuickLook.toggle(folder.path) }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Music & media

/// A music or media location: whose it is, its verdict, how it comes
/// back, and how to clean it. Guidance-only places (cleaned from inside
/// their app) get no add button, only the way there.
struct MediaRow: View {
    let location: MediaLocation
    let state: AddState
    let largest: Int64
    var add: () -> Void = {}
    var reveal: () -> Void = {}
    var openApp: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if location.canAddToPlan {
                    AddButton(state: state, name: location.name,
                              coveredBy: location.coveredBy.map(AppCacheRow.targetName), action: add)
                } else {
                    Image(systemName: "hand.point.up.left")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .help("Cleaned from inside its app")
                        .accessibilityLabel("Cleaned from inside its app")
                }
            }
            .padding(.top, 2)
            Image(nsImage: Icons.icon(for: location.path))
                .resizable()
                .frame(width: 24, height: 24)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(location.name)
                    .lineLimit(1)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // A safe location's reason only restates how it comes back,
                // so it shows that once; anything else keeps its reason.
                let safe = location.level == .safe
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    SafetyMark(level: location.level)
                    Text(safe ? location.regenerates : location.reason)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                if !safe {
                    Text(location.regenerates)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !location.canAddToPlan {
                    if let guidance = location.guidance {
                        Text(guidance)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        if let app = location.appName {
                            Button("Open \(app)", action: openApp)
                        }
                        Button("Show in Finder", action: reveal)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                if let covered = location.coveredBy {
                    Text("Also counted under \(AppCacheRow.targetName(covered))")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SuggestionShareBar(fraction: largest > 0 ? Double(location.ownBytes) / Double(largest) : 0)
                .padding(.top, 7)
            WhatIsThisButton(path: location.path, level: location.level)
            ByteColumn(bytes: location.bytes)
        }
        .padding(.vertical, Theme.Space.rowY)
        .contentShape(Rectangle())
        .rowHover()
        .contextMenu {
            Button("Show in Finder", action: reveal)
            Button("Quick Look") { QuickLook.toggle(location.path) }
            if let app = location.appName {
                Button("Open \(app)", action: openApp)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        ([location.appName, location.kind.title].compactMap { $0 } + [homeRelative(location.path)])
            .joined(separator: " · ")
    }
}

// MARK: Section pieces

/// A quiet all-clear inside a section that was checked and is empty.
struct SectionAllClear: View {
    let text: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Theme.sea)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.sea)
            }
        }
        .padding(.vertical, 12)
    }
}

/// "Show All 24" under a long section.
struct ShowMoreButton: View {
    let total: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(expanded ? "Show Fewer" : "Show All \(total)", action: toggle)
            .buttonStyle(.borderless)
            .font(.callout.weight(.medium))
            .foregroundStyle(Theme.sea)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 34)
    }
}
