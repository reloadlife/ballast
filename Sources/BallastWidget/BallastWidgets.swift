import SwiftUI
import WidgetKit

/// The widget extension's entry point. The process starts in
/// NSExtensionMain (see Package.swift), which hands over to WidgetKit.
@main
struct BallastWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
    }
}

/// Free space, what fills the disk, and what's safe to clean: the Overview's
/// first screen at three sizes.
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.mamad.Ballast.status", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Ballast")
        .description("Free space and what's safe to clean.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Where the widget's taps land; the app routes them in RootView.onOpenURL.
enum DeepLink {
    static let overview = URL(string: "ballast://overview")!
    static let cleanup = URL(string: "ballast://cleanup")!
}
