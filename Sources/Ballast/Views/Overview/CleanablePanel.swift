import SwiftUI

/// "Can be cleaned safely": the floating glass panel under the storage
/// bar, with Review as the screen's one ink plate. When something waits in
/// the Trash it says so and offers to empty it, the step that actually
/// gives the space back. The light sweep crosses it once per drop that
/// freed space.
struct CleanablePanel: View {
    let bytes: Int64
    /// Replaces "can be cleaned safely" (another drive's build folders).
    var title: String?
    var detail = "Caches and build files that apps and tools recreate on their own."
    /// What waits in the Trash; 0 hides the line.
    var trash: Int64 = 0
    /// Changes once per drop that freed space (BallastDrop.freedToken).
    var sweep = 0
    /// False while work the user started runs: Empty Trash would be refused.
    var canEmptyTrash = true
    let review: () -> Void
    var emptyTrash: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.inset) {
                    symbol
                    message
                    Spacer(minLength: Theme.Space.gap)
                    button
                }
                HStack(alignment: .top, spacing: Theme.Space.inset) {
                    symbol
                    VStack(alignment: .leading, spacing: Theme.Space.gap) {
                        message
                        button
                    }
                    Spacer(minLength: 0)
                }
            }
            if trash > 0, let emptyTrash {
                trashLine(emptyTrash)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .padding(.horizontal, Theme.Space.inset + 4)
        .padding(.vertical, Theme.Space.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chartGlass()
        .lightSweep(trigger: sweep)
        .animation(Motion.animation(trash > 0 ? Motion.state : Motion.exit), value: trash > 0)
    }

    private var symbol: some View {
        Image(systemName: bytes > 0 ? Safety.Level.safe.symbol : "checkmark.circle")
            .symbolRenderingMode(.hierarchical)
            .font(.title)
            .foregroundStyle(bytes > 0 ? Theme.verdictSafe : Theme.sea)
            .frame(width: 34)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var message: some View {
        VStack(alignment: .leading, spacing: 3) {
            if bytes > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Sounding(bytes: bytes, font: Theme.hero(22))
                    Text(title ?? "can be cleaned safely").font(.headline)
                }
                .accessibilityElement(children: .combine)
                Text(detail).foregroundStyle(.secondary)
            } else {
                Text("Nothing to clean safely right now").font(.headline)
                Text("Caches and build files show up here as apps and tools make them. Suggestions also lists big folders to review by hand.")
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var button: some View {
        if bytes > 0 {
            Button("Review", action: review)
                .buttonStyle(.ink)
                .help("Open Suggestions and add what's safe to the Cleanup List")
        } else {
            Button("Open Suggestions", action: review)
                .buttonStyle(.bordered)
        }
    }

    private func trashLine(_ emptyTrash: @escaping () -> Void) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.gap) {
                trashText
                Spacer(minLength: Theme.Space.gap)
                trashButton(emptyTrash)
            }
            VStack(alignment: .leading, spacing: 8) {
                trashText
                trashButton(emptyTrash)
            }
        }
        .padding(.leading, 34 + Theme.Space.inset)
    }

    private var trashText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            DepthSwatch(category: .trash)
                .frame(width: 10, height: 10)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Sounding(bytes: trash, font: Theme.sounding.weight(.medium))
                    Text("is in the Trash")
                }
                Text("It still takes up space until the Trash is emptied.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func trashButton(_ emptyTrash: @escaping () -> Void) -> some View {
        Button("Empty Trash…", action: emptyTrash)
            .buttonStyle(.bordered)
            .disabled(!canEmptyTrash)
    }
}

// MARK: Quiet rows

/// A notice on the water: a symbol, what's going on, what to do about it,
/// and its actions at the trailing edge (or under the text when narrow).
/// Locked folders, the usage-data question, a drive's index state.
struct QuietNotice<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.gap) {
                icon
                text
                Spacer(minLength: Theme.Space.gap)
                HStack(spacing: 8) { actions }
            }
            HStack(alignment: .top, spacing: Theme.Space.gap) {
                icon
                VStack(alignment: .leading, spacing: 8) {
                    text
                    HStack(spacing: 8) { actions }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: some View {
        Image(systemName: symbol)
            .foregroundStyle(.secondary)
            .frame(width: 22)
            .accessibilityHidden(true)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

extension QuietNotice where Actions == EmptyView {
    init(symbol: String, title: String, detail: String) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

/// A one-line state inside a section ("No folder grew by more than…"),
/// with an optional next step. Smaller than EmptyChart, which is for a
/// whole screen.
struct ChartNote: View {
    let symbol: String
    let text: String
    var action: (title: String, perform: () -> Void)?
    var isEnabled = true

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.gap) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.sea)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.bordered)
                    .disabled(!isEnabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, Theme.Space.rowY + 2)
    }
}
