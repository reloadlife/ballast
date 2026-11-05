import SwiftUI

// Small pieces shared by Explorer, Largest Files, Duplicates and the
// System Data sheet. They take plain values, so they preview and snapshot
// without an AppModel.

// MARK: Share bar

/// A row's share of something larger, drawn in one Canvas instead of a
/// GeometryReader per row (rows in a Table redraw often). The fill steps
/// through the depth bands by weight, so heavier rows read deeper.
struct ShareBar: View {
    let fraction: Double
    /// The fill; `nil` picks a depth band from `weight`.
    var tint: Color?
    /// The row's weight relative to the heaviest row, 0...1, for the band.
    var weight: Double?
    /// The empty part; land bars sit on a contour track so they don't
    /// blur into the shallowest blue.
    var track: Color?

    var body: some View {
        let fill = tint ?? Self.depthTint(weight ?? fraction)
        let track = track ?? Theme.depth[0]
        Canvas { context, size in
            let radius = size.height / 2
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius), with: .color(track))
            let clamped = min(max(fraction, 0), 1)
            guard clamped > 0 else { return }
            let width = max(size.width * clamped, size.height)
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: size.height), cornerRadius: radius),
                         with: .color(fill))
        }
        .accessibilityHidden(true)
    }

    /// The depth band for a weight: never the track's own band, so even a
    /// light row stays visible, and the heaviest row is ink.
    static func depthTint(_ weight: Double) -> Color {
        Theme.depth(0.25 + 0.75 * sqrt(min(max(weight, 0), 1)))
    }
}

// MARK: Age

/// "Last changed", quietly: long-untouched folders are set in the primary
/// color and a little heavier instead of a warning hue. Being old isn't a
/// hazard, only a hint, and rows nobody can act on stay muted.
struct AgeText: View {
    let newest: Int64
    var muted = false

    var body: some View {
        let age = Age(newest: newest)
        let stale = !muted && [.halfYear, .year, .older].contains(age)
        Text(Age.relative(newest))
            .font(.callout.weight(stale ? .medium : .regular))
            .monospacedDigit()
            .foregroundStyle(stale ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .help("Last modified \(Age.relative(newest)) (\(age.label.lowercased()))")
            .accessibilityLabel("Last changed \(Age.relative(newest))")
    }
}

// MARK: What is this?

/// "What is this?" with its popover state held by the caller, so a
/// context-menu entry can open the same popover the row's button does.
/// Pass the row's own verdict as `level`, so the popover never contradicts
/// the row.
struct InfoPopoverButton: View {
    /// Absolute display path.
    let path: String
    var level: Safety.Level?
    @Binding var isShown: Bool

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("What is this?")
        .accessibilityLabel("What is \((path as NSString).lastPathComponent)?")
        .popover(isPresented: $isShown, arrowEdge: .trailing) {
            WhatIsThisPanel(path: path, level: level)
        }
    }
}

// MARK: Kind filter

/// The kinds a list of large files holds, and the files of one kind,
/// worked out once per change instead of in a body: `FileKind(path:)`
/// parses every path.
enum LargeFileFilter {
    struct Result: Equatable {
        /// The files of the chosen kind, largest first.
        let shown: [LargeFile]
        /// Each kind present, in `FileKind.allCases` order, with its count.
        let kinds: [Count]
        /// Bytes of the shown files.
        let bytes: Int64

        static let empty = Result(shown: [], kinds: [], bytes: 0)
    }

    struct Count: Equatable, Identifiable {
        let kind: FileKind
        let files: Int
        var id: FileKind { kind }
    }

    static func apply(_ files: [LargeFile], kind: FileKind?) -> Result {
        var counts: [FileKind: Int] = [:]
        var shown: [LargeFile] = []
        var bytes: Int64 = 0
        for file in files {
            let fileKind = file.kind
            counts[fileKind, default: 0] += 1
            if kind == nil || fileKind == kind {
                shown.append(file)
                bytes += file.bytes
            }
        }
        let kinds = FileKind.allCases.compactMap { kind in counts[kind].map { Count(kind: kind, files: $0) } }
        return Result(shown: shown, kinds: kinds, bytes: bytes)
    }
}

/// A floating filter bar of glass chips: All, then each kind present.
/// Narrow spaces get the same choice as one glass menu capsule.
struct KindFilterBar: View {
    let kinds: [LargeFileFilter.Count]
    @Binding var selection: FileKind?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips
            menu
        }
    }

    private var chips: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 6) {
                chip("All Kinds", kind: nil)
                ForEach(kinds) { count in chip(count.kind.title, kind: count.kind, files: count.files) }
            }
        }
        .fixedSize()
    }

    private func chip(_ title: String, kind: FileKind?, files: Int? = nil) -> some View {
        let isOn = selection == kind
        return Button {
            Motion.with(Motion.feedback) { selection = kind }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if let files {
                    Text(files.formatted())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout.weight(isOn ? .semibold : .regular))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(isOn ? .regular.tint(Theme.sea.opacity(0.28)).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel(files.map { "\(title), \($0) files" } ?? title)
    }

    private var menu: some View {
        Menu {
            Picker("Kind", selection: $selection) {
                Text("All Kinds").tag(FileKind?.none)
                ForEach(kinds) { Text($0.kind.title).tag(Optional($0.kind)) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(selection?.title ?? "All Kinds", systemImage: "line.3.horizontal.decrease")
                .font(.callout)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .chartCapsule()
        .accessibilityLabel("Kind: \(selection?.title ?? "All Kinds")")
    }
}

// MARK: Notes

/// A one-line note inside a section: a symbol, plain text, an optional
/// action. Errors use `exclamationmark.circle` in the secondary color
/// unless the caller passes the hazard tint for something to act on.
struct SectionNote: View {
    let symbol: String
    let text: String
    var tint: Color?
    var action: (title: String, perform: () -> Void)?
    var actionDisabled = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.glass)
                    .disabled(actionDisabled)
            }
        }
        .padding(.vertical, Theme.Space.rowY)
        .accessibilityElement(children: .combine)
    }
}

/// A hairline between rows: one device pixel, drawn once.
struct RowHairline: View {
    var leading: CGFloat = 0
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Theme.contour)
            .frame(height: 1 / max(displayScale, 1))
            .padding(.leading, leading)
            .accessibilityHidden(true)
    }
}
