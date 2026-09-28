// Renders the widget's views to PNGs, for checking the layout without adding
// the widget to the desktop: `swift run WidgetRender <folder>`. It compiles
// the widget's own view and provider files (symlinked from BallastWidget),
// reads the real status.json, and draws each family in light and dark for
// the real disk, the gallery sample, an empty state, an old scan and figures
// that couldn't be refreshed. A development tool: bundle.sh doesn't ship it.
import AppKit
import BallastCore
import SwiftUI
import WidgetKit

guard CommandLine.arguments.count == 2 else {
    print("usage: WidgetRender <output folder>")
    exit(1)
}
let out = CommandLine.arguments[1]

/// The same taps as the widget; the harness never follows them.
enum DeepLink {
    static let overview = URL(string: "ballast://overview")!
    static let cleanup = URL(string: "ballast://cleanup")!
}

/// SwiftUI's Link only draws inside WidgetKit (ImageRenderer shows a yellow
/// "unavailable" box instead), so here it's shadowed by its label.
struct Link<Label: View>: View {
    let label: Label
    init(destination: URL, @ViewBuilder label: () -> Label) { self.label = label() }
    var body: some View { label }
}

/// The desktop's sizes on macOS 26, in points, as chronod asks for them.
let small = CGSize(width: 164, height: 164)
let medium = CGSize(width: 344, height: 164)
let large = CGSize(width: 344, height: 344)

@MainActor func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) {
    let framed = view
        .padding(16)
        .frame(width: size.width, height: size.height)
        .background(dark ? Color(white: 0.12) : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, dark ? .dark : .light)
        .padding(10)
    let renderer = ImageRenderer(content: framed)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        print("couldn't render \(name)")
        return
    }
    let url = URL(fileURLWithPath: out).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
    do { try png.write(to: url) } catch { print("couldn't write \(url.path): \(error)") }
}

MainActor.assumeIsolated {
    let real = StatusProvider.current()
    print(real.snapshot == nil ? "no status.json: real shows the empty state" : "read \(StatusSnapshot.url.path)")
    var cases: [(String, StatusEntry)] = [
        ("real", real),
        ("sample", .sample),
        ("empty", StatusEntry(date: .now, snapshot: nil, volume: DiskCapacity.current, isLive: true)),
    ]
    if let snapshot = real.snapshot {
        var aged = snapshot
        aged.scannedAt = Date.now.addingTimeInterval(-2 * 86_400 - 3_000)
        var stale = aged
        stale.date = Date.now.addingTimeInterval(-3 * 3_600)
        cases.append(("aged", StatusEntry(date: .now, snapshot: aged, volume: nil, isLive: true)))
        cases.append(("stale", StatusEntry(date: .now, snapshot: stale, volume: nil, isLive: false)))
    }
    for (name, entry) in cases {
        let disk = Disk(entry)
        for dark in [false, true] {
            render(SmallStatus(disk: disk), size: small, dark: dark, name: "\(name)-small")
            render(MediumStatus(disk: disk), size: medium, dark: dark, name: "\(name)-medium")
            render(LargeStatus(disk: disk), size: large, dark: dark, name: "\(name)-large")
        }
    }
    print("wrote \(cases.count * 6) images to \(out)")
}
