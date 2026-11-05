import SwiftUI

/// The top of Suggestions: what can be cleaned safely as the screen's one
/// figure, what the app caches and media sections add on top, and the
/// screen's one primary action.
struct SuggestionsSummary: View {
    let reclaimable: Int64
    /// What App caches and Music & media add, not counted in `reclaimable`.
    let appCaches: Int64
    let media: Int64
    let canAddAll: Bool
    var loading = false
    var addAll: () -> Void = {}

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 24) {
                figure
                Spacer(minLength: 12)
                action
            }
            VStack(alignment: .leading, spacing: 16) {
                figure
                action
            }
        }
    }

    private var figure: some View {
        VStack(alignment: .leading, spacing: 4) {
            Sounding(bytes: reclaimable, font: Theme.hero(44))
                .loadingShimmer(loading)
            Text("can be cleaned safely")
                .font(.title3)
                .foregroundStyle(.secondary)
            if let extra {
                Text(extra)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Review a suggestion, add it to the Cleanup List, then clean up when you’re ready.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }

    private var action: some View {
        Button("Add All Safe Items", systemImage: "plus", action: addAll)
            .buttonStyle(.ink)
            .disabled(!canAddAll)
            .help(canAddAll ? "Add every cache and build folder that passes the safety check to the Cleanup List"
                            : "Every safe cache and build folder is on the Cleanup List already")
    }

    /// "Another 3.1 GB in app caches and 1.2 GB in music and media."
    private var extra: String? {
        var parts: [String] = []
        if appCaches > 0 { parts.append("\(appCaches.bytes) in app caches") }
        if media > 0 { parts.append("\(media.bytes) in music and media") }
        guard !parts.isEmpty else { return nil }
        return "Another " + parts.joined(separator: " and ") + ", below: check those before you clean them."
    }
}
