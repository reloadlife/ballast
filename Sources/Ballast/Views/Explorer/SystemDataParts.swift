import SwiftUI

/// What someone can do about each part of System Data, in plain words,
/// beside the catalog's description of what the part is. Keyed by the
/// names `SystemDataCatalog` and `AppModel.loadSystemData` give the parts.
enum SystemDataAdvice {
    static func advice(for item: SystemDataItem) -> String? {
        // Only what the catalog's description doesn't already say.
        switch item.name {
        case "Temporary files & system caches":
            "Ballast leaves it alone: open apps are still using it."
        case "Shared temporary folder (/tmp)":
            "A restart clears it sooner."
        case "Shared app data":
            "Open it in Explorer. Simulators (Xcode › Settings › Components), audio libraries and old printer drivers are the usual weight; remove them from the app that installed them."
        case "Homebrew & /opt":
            "Or review packages on Ballast's Homebrew screen."
        case "/usr/local":
            "Remove tools you no longer use with whatever installed them."
        case "Other users & Shared":
            "Sign in as that user to review their files, or open /Users/Shared in Explorer."
        case "Other system files":
            "Open it in Explorer to see which folder holds it."
        case "Not measured":
            item.action == .adminScan
                ? "Scan as Admin measures the folders macOS kept locked, so they move out of this line."
                : "Nothing to do: it's how APFS keeps track of your files."
        case "Swap & sleep image":
            "Quitting apps you aren't using shrinks it too."
        case "Staged updates":
            "Install the waiting update in System Settings › General › Software Update to clear it."
        default:
            nil
        }
    }

    /// The path a part opens in Explorer, for "What is this?".
    static func path(of item: SystemDataItem) -> String? {
        if case .explore(let path) = item.action, path != "/" { return path }
        return nil
    }
}

/// One part of System Data: what it is, what to do about it, and its size
/// as a sounding over a land-colored share bar (System Data is land on
/// the storage bar: what can't simply be moved).
struct SystemDataRow: View {
    let item: SystemDataItem
    let total: Int64
    /// What the knowledge base says, when it knows the part's folder.
    var explanation: KnowledgeExplanation?
    /// A user run (scan, cleanup) holds the run gate.
    var isBusy = false
    let perform: (SystemDataItem.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                    if explanation != nil, let path = SystemDataAdvice.path(of: item) {
                        WhatIsThisButton(path: path)
                    }
                }
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let advice = SystemDataAdvice.advice(for: item) {
                    Text(advice)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let guidance = explanation?.guidance {
                    Text(guidance)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch item.action {
                case .explore:
                    Button("Show in Explorer") { perform(item.action) }
                        .buttonStyle(.link)
                        .tint(Theme.control)
                        .font(.callout)
                case .adminScan:
                    Button("Scan as Admin…") { perform(item.action) }
                        .buttonStyle(.link)
                        .tint(Theme.control)
                        .font(.callout)
                        .disabled(isBusy)
                        .help(isBusy ? "Waiting for the current run to finish" : "Measures folders macOS kept locked")
                case .none:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 7) {
                Sounding(bytes: item.bytes)
                ShareBar(fraction: Double(item.bytes) / Double(max(total, 1)), tint: Theme.land, track: Theme.contour)
                    .frame(width: 84, height: 5)
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name), \(item.bytes.bytes)")
    }
}

/// A titled group of System Data parts on one chart surface.
struct SystemDataGroup: View {
    let title: String
    let note: String
    let items: [SystemDataItem]
    let total: Int64
    var knowledge: [String: KnowledgeExplanation] = [:]
    var isBusy = false
    let perform: (SystemDataItem.Action) -> Void

    var body: some View {
        ChartSection(title: title, note: note, total: items.reduce(0) { $0 + $1.bytes }) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowHairline() }
                SystemDataRow(item: item, total: total,
                              explanation: SystemDataAdvice.path(of: item).flatMap { knowledge[$0] },
                              isBusy: isBusy, perform: perform)
            }
        }
    }
}

/// "macOS hides some of this": without Full Disk Access, parts of the
/// data volume can't be measured and end up in "Not measured".
struct FullDiskAccessCallout: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "hand.raised")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Some of System Data is hidden from Ballast")
                    .font(.callout.weight(.medium))
                Text("Without Full Disk Access, macOS keeps parts of Library and other apps' data out of view, so their size counts as Not measured.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open Privacy Settings") { Access.openFullDiskAccessSettings() }
                .buttonStyle(.bordered)
        }
        .padding(Theme.Space.inset)
        .chartGlass(radius: Theme.Radius.card)
        .accessibilityElement(children: .contain)
    }
}
