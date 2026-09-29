// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ballast",
    platforms: [.macOS(.v26)],
    dependencies: [
        // In-app updates. Only the app links it; scripts/bundle.sh copies
        // Sparkle.framework into Ballast.app/Contents/Frameworks.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // What the app and the widget share: status.json and its colors.
        .target(name: "BallastCore", path: "Sources/BallastCore"),
        .executableTarget(
            name: "Ballast",
            dependencies: ["BallastCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Ballast",
            // Finds Sparkle.framework in Ballast.app/Contents/Frameworks; the
            // default @loader_path covers `swift run`, where it sits alongside.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
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
