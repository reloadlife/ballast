// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ballast",
    platforms: [.macOS(.v26)],
    targets: [
        // What the app and the widget share: status.json and its colors.
        .target(name: "BallastCore", path: "Sources/BallastCore"),
        .executableTarget(name: "Ballast", dependencies: ["BallastCore"], path: "Sources/Ballast"),
        // The widget, bundled as Ballast.app/Contents/PlugIns/BallastWidget.appex
        // by scripts/bundle.sh. Built the way Xcode builds app extensions:
        // extension-safe API only, and the process starts in NSExtensionMain,
        // which hands over to WidgetKit.
        .executableTarget(
            name: "BallastWidget",
            dependencies: ["BallastCore"],
            path: "Sources/BallastWidget",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"])]
        ),
        // Development only, never bundled: draws the widget's views to PNGs
        // (`swift run WidgetRender <folder>`). Its StatusProvider.swift and
        // StatusWidgetView.swift are symlinks to the widget's files.
        .executableTarget(name: "WidgetRender", dependencies: ["BallastCore"], path: "Sources/WidgetRender"),
        .testTarget(name: "BallastTests", dependencies: ["Ballast", "BallastCore"], path: "Tests/BallastTests"),
    ]
)
