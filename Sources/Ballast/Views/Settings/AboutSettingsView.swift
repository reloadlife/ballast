import AppKit
import SwiftUI

struct AboutSettingsView: View {
    private let updater = AppUpdater.shared

    /// "0.1.0 (1)"; a bare `swift run` binary has no Info.plist to read.
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String else { return "Development build" }
        let build = info["CFBundleVersion"] as? String
        return "Version \(short)" + (build.map { " (\($0))" } ?? "")
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Ballast").font(.title2.weight(.semibold))
                Text(version)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
                if updater.isAvailable {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                        .padding(.top, 6)
                }
            }
            Text("See where your Mac's disk space went, and get it back without breaking anything.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 20) {
                Link("GitHub", destination: URL(string: "https://github.com/reloadlife/ballast")!)
                Link("License: GNU AGPL v3", destination: URL(string: "https://github.com/reloadlife/ballast/blob/main/LICENSE")!)
            }
            .padding(.top, 4)
            Text("© Mohammad Mahdi Afshar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 32)
        .frame(width: 600)
    }
}
