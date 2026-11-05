import AppKit
import SwiftUI
import Testing
@testable import Ballast

/// Renders design components to PNGs for a visual check. Runs only when
/// BALLAST_SNAPSHOTS names an output folder:
/// `BALLAST_SNAPSHOTS=/tmp/shots swift test --filter ComponentSnapshots`
@MainActor @Suite struct ComponentSnapshots {
    nonisolated static let folder = ProcessInfo.processInfo.environment["BALLAST_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderComponents() throws {
        let segments: [DepthBar.Segment] = [
            .init(category: .applications, bytes: 32_000_000_000),
            .init(category: .yourFiles, bytes: 220_000_000_000),
            .init(category: .caches, bytes: 42_000_000_000),
            .init(category: .build, bytes: 22_000_000_000),
            .init(category: .system, bytes: 117_000_000_000),
        ]
        let board = VStack(alignment: .leading, spacing: 24) {
            DepthBar(segments: segments, free: 59_000_000_000, total: 494_000_000_000)
            HStack { ForEach([Safety.Level.safe, .quitFirst, .caution, .blocked], id: \.self) { SafetyMark(level: $0, showsTitle: true) } }
            BallastDock(count: 12, bytes: 18_400_000_000, needsYou: 2, review: {})
            EmptyChart(symbol: "checkmark.seal", title: "Nothing to clean right now", message: "Ballast checks again after the next scan.")
                .frame(height: 220)
            SkeletonRows(count: 3)
        }
        .padding(32)
        .frame(width: 760)
        .background(Theme.water)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try Self.render(board, name: "components-\(appearance == .aqua ? "light" : "dark")", appearance: appearance)
        }
    }

    static func render(_ view: some View, name: String, appearance: NSAppearance.Name) throws {
        let dark = appearance == .darkAqua
        var data: Data?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation {
                data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            }
        }
        let url = URL(fileURLWithPath: folder!).appendingPathComponent(name + ".png")
        try data?.write(to: url)
    }
}
