import SwiftUI

/// Whether a row can go on the Cleanup List, and if it's on it.
enum AddState: Equatable {
    /// Its verdict is still being worked out (off the main thread).
    case pending
    /// Protected or never removable: no control; the context menu says why.
    case unavailable
    case ready(isOn: Bool)
}

/// One location in an Overview list: its text and share bar (`content`),
/// then at fixed widths the size, the ⊕ toggle, What is this? and a
/// chevron, so every size in the list ends on one column edge. Clicking
/// the row runs `action`; adding it flashes the row so the click lands.
struct ChartRow<Content: View, Menu: View>: View {
    let name: String
    let path: String
    /// The row's own verdict, so What is this? never contradicts it.
    let level: Safety.Level?
    let add: AddState
    var showsChevron = true
    var accessibilityHint = "Opens in Explorer"
    let action: () -> Void
    let toggle: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var menu: Menu

    @State private var hovered = false
    @State private var flash = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(accessibilityHint)

            AddToggle(name: name, state: add) {
                if case .ready(false) = add { flashRow() }
                toggle()
            }
            WhatIsThisButton(path: path, level: level)
                .frame(width: 20)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, Theme.Space.rowY)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(flash ? Theme.sea.opacity(0.14) : Color.primary.opacity(hovered ? 0.045 : 0))
        )
        .onHover { hovered = $0 }
        .draggable(URL(fileURLWithPath: path))
        .contextMenu {
            menu
            Divider()
            Button("Copy Path") { Finder.copy(path) }
        }
    }

    /// A short sea-tinted flash when the row joins the list; the toggle's
    /// symbol swap and bounce finish the acknowledgement.
    private func flashRow() {
        guard Motion.animation(Motion.feedback) != nil else { return }
        Motion.with(Motion.feedback) { flash = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            Motion.with(Motion.exit) { flash = false }
        }
    }
}

/// ⊕ / ✓: adds a row to the Cleanup List, or takes it off. The symbol
/// swaps and bounces once on each change (not under Reduce Motion).
struct AddToggle: View {
    let name: String
    let state: AddState
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if case .ready(let isOn) = state {
                Button(action: action) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(isOn ? AnyShapeStyle(Theme.sea) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : isOn)
                }
                .buttonStyle(.borderless)
                .help(isOn ? "Remove from Cleanup List" : "Add to Cleanup List")
                .accessibilityLabel(isOn ? "Remove \(name) from Cleanup List" : "Add \(name) to Cleanup List")
                .transition(.opacity)
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }
        .frame(width: 22, height: 22)
        .animation(Motion.animation(Motion.feedback), value: state == .pending)
    }
}

/// A row's text, share bar and size. The bar goes first when the column
/// is narrow, so the name keeps its room. Every size is a sounding at the
/// same trailing column edge.
struct ChartRowText<Icon: View>: View {
    let name: String
    let detail: String
    let fraction: Double
    let bytes: Int64
    /// "+" for growth.
    var sign = ""
    @ViewBuilder var icon: Icon

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(bar: true)
            row(bar: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(sign)\(bytes.bytes), in \(detail)")
    }

    private func row(bar: Bool) -> some View {
        HStack(spacing: Theme.Space.gap) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Measured as 160 pt wide, so a long path doesn't push the bar out.
            .frame(minWidth: 0, idealWidth: 160, maxWidth: .infinity, alignment: .leading)
            if bar {
                SizeBar(fraction: fraction, tint: Self.tint(fraction))
                    .frame(width: 90, height: 5)
            }
            HStack(spacing: 0) {
                if !sign.isEmpty { Text(sign).font(Theme.sounding) }
                Sounding(bytes: bytes)
            }
            .lineLimit(1)
            .frame(width: 84, alignment: .trailing)
        }
    }

    /// Heavier rows sit deeper: the share bar steps through depth bands
    /// 1-4 (band 0 is the track).
    static func tint(_ fraction: Double) -> Color {
        Theme.depth(0.25 + 0.75 * min(max(fraction, 0), 1))
    }
}

extension ChartRowText where Icon == EmptyView {
    init(name: String, detail: String, fraction: Double, bytes: Int64, sign: String = "") {
        self.init(name: name, detail: detail, fraction: fraction, bytes: bytes, sign: sign) { EmptyView() }
    }
}

// MARK: Verdicts off the main thread

/// A row whose list item is worked out off the main thread.
struct RowRequest: Hashable, Sendable {
    let name: String
    let path: String
    let bytes: Int64
    let isDirectory: Bool
}

/// List items for rows. Safety checks touch the disk (paths, volumes,
/// `.git` markers), which on a sleeping drive would freeze the window, so
/// they run detached; rows show their toggle once theirs is known.
/// Folders the cleaner could never remove get no item.
struct RowItems: Equatable {
    private(set) var items: [String: PlanItem] = [:]
    private(set) var resolved: Set<String> = []

    func state(_ path: String, isPlanned: Bool) -> AddState {
        guard resolved.contains(path) else { return .pending }
        guard let item = items[path], item.safety.level != .blocked else { return .unavailable }
        return .ready(isOn: isPlanned)
    }

    func level(_ path: String) -> Safety.Level? { items[path]?.safety.level }
    func item(_ path: String) -> PlanItem? { items[path] }

    static func resolve(_ requests: [RowRequest], apps: AppInventory, protected: [String]) async -> RowItems {
        guard !requests.isEmpty else { return RowItems() }
        return await Task.detached(priority: .userInitiated) {
            var result = RowItems()
            for request in requests {
                result.resolved.insert(request.path)
                if request.isDirectory, !Cleaner.canRemove(request.path) { continue }
                result.items[request.path] = PlanItem.assess(
                    name: request.name, path: request.path, bytes: request.bytes, action: .remove,
                    isDirectory: request.isDirectory, apps: apps, protected: protected)
            }
            return result
        }.value
    }
}
