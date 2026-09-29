import AppKit
import Foundation
import Observation
import Sparkle

/// Whether this build can update itself. Sparkle needs a real app bundle,
/// a feed, and the public key that release archives are signed against;
/// bundle.sh leaves the key out when it has none (forks, CI), and then
/// Ballast never starts Sparkle rather than have it fail at check time.
enum UpdateSupport: Equatable, Sendable {
    case available
    case unavailable(Reason)

    enum Reason: Equatable, Sendable {
        /// `swift run`: a bare binary with no Info.plist and nowhere to install to.
        case notBundled
        case noFeed
        case noPublicKey
    }

    static let feedKey = "SUFeedURL"
    static let publicKeyKey = "SUPublicEDKey"

    static var current: UpdateSupport {
        check(bundleURL: Bundle.main.bundleURL, info: Bundle.main.infoDictionary ?? [:])
    }

    static func check(bundleURL: URL, info: [String: Any]) -> UpdateSupport {
        guard bundleURL.pathExtension == "app" else { return .unavailable(.notBundled) }
        guard let feed = info[feedKey] as? String, isFeedURL(feed) else { return .unavailable(.noFeed) }
        guard let key = info[publicKeyKey] as? String, isPublicKey(key) else { return .unavailable(.noPublicKey) }
        return .available
    }

    /// An http(s) URL with a host.
    static func isFeedURL(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil
        else { return false }
        return true
    }

    /// Sparkle's EdDSA public key: 32 bytes, base64 (what `generate_keys` prints).
    static func isPublicKey(_ string: String) -> Bool {
        Data(base64Encoded: string.trimmingCharacters(in: .whitespacesAndNewlines))?.count == 32
    }
}

/// Sparkle, for SwiftUI: what Settings, the app menu and the menu bar item
/// show and do. Sparkle asks on the second launch whether to check
/// automatically (SUEnableAutomaticChecks is left unset), so nothing goes
/// online until the user says yes or clicks Check for Updates.
@MainActor
@Observable
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    let support = UpdateSupport.current
    var isAvailable: Bool { support == .available }

    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecks = false
    private(set) var automaticallyDownloads = false
    private(set) var lastChecked: Date?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Starts Sparkle's schedule, once, at launch. Does nothing in a build
    /// that can't update.
    func start() {
        guard isAvailable, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        // Sparkle changes these on the main thread.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
        controller.startUpdater()
        refresh()
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Setting either one counts as the user's answer, so Sparkle won't ask.
    func setAutomaticallyChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
        refresh()
    }

    func setAutomaticallyDownloads(_ on: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = on
        refresh()
    }

    /// Reads Sparkle's settings without writing any back.
    func refresh() {
        guard let updater = controller?.updater else { return }
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        lastChecked = updater.lastUpdateCheckDate
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { refresh() }
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    /// With the menu bar item on, Ballast can run with no window and no
    /// Dock icon. Sparkle then shows a scheduled update without stealing
    /// focus, and Ballast comes back to the Dock for it.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            if state.userInitiated { NSApp.activate() }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { AppDelegate.leaveDockIfWindowless() }
    }
}
