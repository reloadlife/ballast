import SwiftUI

/// "What is this?": a small info button that opens a popover explaining a
/// location from the knowledge base: what it is, what happens when it's
/// removed, how to clean it, its verdict, and whether macOS hides it
/// without Full Disk Access. The lookup runs off the main thread when the
/// popover opens, never in a view body.
///
/// Pass the row's own verdict as `level` wherever one is shown beside it
/// (a PlanItem's `safety.level`): the knowledge base only knows the
/// location, not that an app is running, the folder is protected or a
/// repository has changes, so its verdict alone could contradict the row.
struct WhatIsThisButton: View {
    /// An absolute display path.
    let path: String
    /// The verdict the row shows; nil shows the knowledge base's.
    var level: Safety.Level?
    @State private var isShown = false

    init(path: String, level: Safety.Level? = nil) {
        self.path = path
        self.level = level
    }

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("What is this?")
        .accessibilityLabel("What is \((Paths.display(path) as NSString).lastPathComponent)?")
        .popover(isPresented: $isShown, arrowEdge: .trailing) {
            WhatIsThisPanel(path: path, level: level)
        }
    }
}

/// The popover's content. Also usable inline (an inspector, a sheet).
struct WhatIsThisPanel: View {
    let path: String
    /// Overrides the knowledge base's verdict (see WhatIsThisButton).
    let level: Safety.Level?

    enum Phase: Sendable, Equatable {
        case loading
        case known(KnowledgeEntry, level: Safety.Level, inside: String?)
        case unknown
    }

    @State private var phase: Phase
    /// The placeholder waits a moment: the lookup is in memory and usually
    /// done first, so the popover doesn't flash a shimmer and resize.
    @State private var showsPlaceholder = false
    /// Previews pass a fixed phase and skip the lookup.
    private let isFixed: Bool

    init(path: String, level: Safety.Level? = nil, phase: Phase? = nil) {
        self.path = path
        self.level = level
        _phase = State(initialValue: phase ?? .loading)
        isFixed = phase != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .loading:
                loading
            case .unknown:
                unknown
            case let .known(entry, known, inside):
                self.known(entry, level: level ?? known, inside: inside)
            }
        }
        .padding(Theme.Space.inset)
        .frame(width: 320, alignment: .leading)
        .task(id: path) {
            guard !isFixed else { return }
            // Knowledge.explain(path:) is lookup(path:)?.entry; the match
            // also says whether the path is inside the entry, which can
            // change the verdict.
            let path = path
            let match = await Task.detached(priority: .userInitiated) {
                Knowledge.lookup(path: path)
            }.value
            guard !Task.isCancelled else { return }
            phase = match.map {
                .known($0.entry, level: $0.level, inside: $0.isInside ? Paths.display($0.matchedPath) : nil)
            } ?? .unknown
        }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Folder name here").font(.headline)
            Text("What this folder is and what happens when it's removed.")
            Text("How it comes back.")
        }
        .opacity(showsPlaceholder ? 1 : 0)
        .loadingShimmer(showsPlaceholder)
        .task {
            guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
            showsPlaceholder = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }

    private var unknown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ballast doesn't know this folder yet").font(.headline)
            Text("Its verdict comes from Ballast's general rules, shown beside it in the list. Check what it holds before cleaning it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            pathLine(Paths.display(path))
        }
    }

    @ViewBuilder
    private func known(_ entry: KnowledgeEntry, level: Safety.Level, inside: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).font(.headline)
            Text(entry.kind.title).font(.callout).foregroundStyle(.secondary)
        }
        if let inside {
            Text("Inside \(inside)").font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
        }
        section("When it's removed", entry.regenerates)
        if let guidance = entry.guidance {
            section("How to clean it", guidance)
        }
        SafetyMark(level: level, showsTitle: true)
            .font(.callout.weight(.medium))
        if entry.needsFullDiskAccess {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "hand.raised")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Needs Full Disk Access").font(.callout.weight(.medium))
                    Text("macOS shows this folder only to apps you allow.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Privacy Settings") { Access.openFullDiskAccessSettings() }
                        .buttonStyle(.link)
                        .tint(Theme.control)
                        .font(.callout)
                }
            }
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.medium))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pathLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

// MARK: Previews

private struct WhatIsThisPreview: View {
    static let entry = KnowledgeEntry(
        id: "preview.xcode", name: "Xcode derived data", pathPattern: "Library/Developer/Xcode/DerivedData",
        kind: .buildOutput, verdict: .safe,
        regenerates: "Xcode rebuilds it the next time you build; the first build takes longer.",
        guidance: "Or use Product › Clean Build Folder in Xcode.", needsFullDiskAccess: true)

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            WhatIsThisPanel(path: "/Users/me/Library/Developer/Xcode/DerivedData",
                            phase: .known(Self.entry, level: .safe, inside: nil))
                .chartSurface()
            WhatIsThisPanel(path: "/Users/me/odd", phase: .unknown).chartSurface()
            WhatIsThisPanel(path: "/Users/me/odd", phase: .loading).chartSurface()
        }
        .padding(24)
        .background(Theme.water)
    }
}

#Preview("What is this · light") { WhatIsThisPreview().preferredColorScheme(.light) }
#Preview("What is this · dark") { WhatIsThisPreview().preferredColorScheme(.dark) }
