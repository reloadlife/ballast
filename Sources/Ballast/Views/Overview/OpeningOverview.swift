import SwiftUI

/// The Overview's shape in skeleton while the saved index opens at launch:
/// a header, a bar and a few rows, shimmering only while it loads. Bounded:
/// if the index hasn't opened after `patience`, it shows `fallback` (the
/// welcome and its Scan button), so it can never wait forever.
struct OpeningOverview<Fallback: View>: View {
    var patience: Duration = .seconds(3)
    @ViewBuilder var fallback: Fallback
    @State private var gaveUp = false

    var body: some View {
        Group {
            if gaveUp {
                fallback
                    .transition(.opacity)
            } else {
                OverviewSkeleton()
                    .transition(.opacity.animation(Motion.exit))
            }
        }
        .task {
            guard (try? await Task.sleep(for: patience)) != nil else { return }
            Motion.with(Motion.state) { gaveUp = true }
        }
    }
}

/// Placeholder Overview: name and hero figure, the bar, the panel and the
/// first rows, in the shapes they'll take.
struct OverviewSkeleton: View {
    var body: some View {
        // Not a ScrollView: a placeholder never scrolls, and the top of the
        // page is all it needs to show.
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .lastTextBaseline) {
                            VStack(alignment: .leading, spacing: 8) {
                                Capsule().frame(width: 150, height: 16)
                                Capsule().frame(width: 190, height: 10).opacity(0.6)
                            }
                            Spacer()
                            Capsule().frame(width: 140, height: 34)
                        }
                        RoundedRectangle(cornerRadius: Theme.Radius.bar, style: .continuous)
                            .frame(height: 22)
                        HStack(spacing: 18) {
                            ForEach([96, 84, 70, 88], id: \.self) { width in
                                Capsule().frame(width: CGFloat(width), height: 9).opacity(0.7)
                            }
                        }
                    }
                    RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                        .frame(height: 78)
                        .opacity(0.6)
                }
                .foregroundStyle(Theme.depth[0])
                .loadingShimmer(true)

                ChartSection(title: "Largest folders") {
                    SkeletonRows(count: 5)
                }
            }
            .frame(maxWidth: Theme.Space.contentMax, alignment: .leading)
            .padding(.horizontal, Theme.Space.pageX)
            .padding(.vertical, Theme.Space.section)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening the disk index")
    }
}
