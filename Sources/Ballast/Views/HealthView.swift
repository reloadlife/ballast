import AppKit
import SwiftUI

@MainActor @Observable final class HealthModel {
    static let shared = HealthModel()
    var local: LocalHealthReport?
    var checkingLocal = false
    var inventory: VulnerabilityInventory?
    var vulnerabilities: VulnerabilityReport?
    /// Reading the package list (offline) or checking it online.
    var checkingVulnerabilities = false
    /// The offline package list is being read, not the online check.
    private(set) var preparing = false
    var error: String?
    private var scanTask: Task<VulnerabilityReport, Error>?
    @ObservationIgnored private var localTask: Task<Void, Never>?

    var canCancel: Bool { scanTask != nil }
    func cancel() { scanTask?.cancel() }

    /// Runs every local check side by side and shows each result as it
    /// arrives. A second request while checks run joins them.
    func refresh() async {
        if let localTask {
            await localTask.value
            return
        }
        let task = Task { await runLocalChecks() }
        localTask = task
        await task.value
        localTask = nil
    }

    func cancelLocal() { localTask?.cancel() }

    private func runLocalChecks() async {
        checkingLocal = true
        defer { checkingLocal = false }
        var report: LocalHealthReport?
        for await update in HealthChecks.updates() {
            // The previous report stays on screen until the first new result.
            var current = report ?? LocalHealthReport()
            current.insert(update)
            report = current
            local = current
        }
    }

    /// Inventory stays local. Sending happens only after the separate confirmation.
    func prepare() async {
        guard !checkingVulnerabilities else { return }
        checkingVulnerabilities = true
        preparing = true
        error = nil
        inventory = nil
        vulnerabilities = nil
        do { inventory = try await Task.detached(priority: .utility) { try VulnerabilityInventory.read() }.value }
        catch { self.error = error.localizedDescription }
        preparing = false
        checkingVulnerabilities = false
    }

    func scan() async {
        guard let inventory, !checkingVulnerabilities else { return }
        checkingVulnerabilities = true
        vulnerabilities = nil
        error = nil
        defer { checkingVulnerabilities = false; scanTask = nil }
        let task = Task { try await VulnerabilityCheck.scan(inventory) }
        scanTask = task
        do { vulnerabilities = try await task.value }
        catch is CancellationError { self.error = "The online check was stopped. Nothing more was sent." }
        catch { self.error = error.localizedDescription }
    }
}

struct HealthView: View {
    @State private var model = HealthModel.shared
    @State private var confirmOnline = false

    var body: some View {
        ToolPage {
            HealthSummary(report: model.local, isChecking: model.checkingLocal,
                          check: { Task { await model.refresh() } }, cancel: { model.cancelLocal() })

            HealthFindingsSection(title: "Storage health",
                                  note: "SMART can't predict every failure. Keep a current backup.",
                                  findings: model.local?.storage, pending: model.checkingLocal ? 1 : 0) {
                Button("Open Disk Utility") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
                }
                .help("Disk Utility verifies and repairs file systems. Ballast doesn't run it for you.")
            }

            HealthFindingsSection(title: "Mac security",
                                  note: "FileVault, System Integrity Protection, Gatekeeper and the firewall.",
                                  findings: model.local?.security,
                                  pending: model.checkingLocal ? max(SecurityCheck.all.count - (model.local?.security.count ?? 0), 0) : 0) {
                Button("Open Privacy & Security") { openSettings("com.apple.settings.PrivacySecurity.extension") }
                Button("Check for macOS Updates…") { openSettings("com.apple.Software-Update-Settings.extension") }
                    .help("System Settings checks for updates; Ballast doesn't infer them from the installed version.")
            }

            vulnerabilities
        }
        // Local checks are offline and read-only, so they start on their own.
        .task { if model.local == nil && !model.checkingLocal { await model.refresh() } }
        .confirmationDialog("Send package names and versions to OSV?", isPresented: $confirmOnline, titleVisibility: .visible) {
            Button("Send and Check") { Task { await model.scan() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("OSV receives the \(model.inventory?.packages.count ?? 0) package names and versions you reviewed, and your IP address. Disk health and local files stay on this Mac.")
        }
    }

    private var vulnerabilities: some View {
        ChartSection(title: "Known vulnerabilities",
                     note: "Homebrew core formulae, checked against OSV advisories. Nothing is sent until you confirm.") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Checks installed Homebrew core formula versions in /opt/homebrew and /usr/local. Mac apps, casks, third-party taps and other package managers aren't covered. No match means no known match in this source, not that your Mac is secure.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.preparing {
                    SkeletonRows(count: 3, showsIcon: false)
                } else if let inventory = model.inventory {
                    PackagesToSend(inventory: inventory)
                    if model.checkingVulnerabilities {
                        ToolActivityLine(activity: "Checking \(inventory.packages.count) versions with OSV…",
                                         canCancel: model.canCancel, cancel: model.cancel)
                    } else {
                        HStack {
                            Button("Review Again") { Task { await model.prepare() } }
                                .buttonStyle(.borderless)
                            Spacer()
                            Button("Check These Versions Online…") { confirmOnline = true }
                                .buttonStyle(.glass)
                                .disabled(inventory.packages.isEmpty)
                                .help(inventory.packages.isEmpty ? "No supported formula versions were found." : "Asks before sending anything")
                        }
                    }
                } else {
                    HStack {
                        Text("Review the package names and versions first; nothing leaves this Mac yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Review Packages…") { Task { await model.prepare() } }
                            .buttonStyle(.glass)
                            .disabled(model.checkingVulnerabilities)
                    }
                }

                if let error = model.error {
                    ChartHairline()
                    StatusMark(state: .problem, title: error)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let report = model.vulnerabilities {
                    ChartHairline()
                    VulnerabilityResults(report: report)
                }
            }
        }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(url) }
    }
}

// MARK: Pieces (value-taking, so the snapshot tests can render them)

/// The figure that owns the Health screen: how many checks need you, with
/// when they ran and the one control that reruns or stops them.
struct HealthSummary: View {
    let report: LocalHealthReport?
    let isChecking: Bool
    var check: () -> Void = {}
    var cancel: () -> Void = {}

    private var attention: Int {
        guard let report else { return 0 }
        return (report.storage + report.security).count { $0.state == .attention }
    }

    private var headline: String {
        guard report != nil else { return isChecking ? "Checking this Mac…" : "Not checked yet" }
        switch attention {
        case 0: return isChecking ? "Nothing needs attention so far" : "Nothing needs attention"
        case 1: return "1 check needs attention"
        default: return "\(attention) checks need attention"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.gap) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if report != nil {
                            StatusMark(state: attention > 0 ? .attention : .passed)
                                .font(.title2)
                        }
                        Text(headline)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(attention > 0 ? AnyShapeStyle(Theme.hazard) : AnyShapeStyle(.primary))
                            .contentTransition(.numericText(value: Double(attention)))
                            .animation(Motion.animation(Motion.state), value: attention)
                    }
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if isChecking {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.glass)
                        .help("Stop the checks still running")
                } else {
                    Button(report == nil ? "Check This Mac" : "Check Again", action: check)
                        .buttonStyle(.glass)
                        .help("Runs the read-only checks again")
                }
            }
            if isChecking {
                DepthProgress(fraction: nil)
                    .transition(.opacity)
            }
        }
        .animation(Motion.animation(Motion.state), value: isChecking)
    }

    private var subtitle: String {
        var text = "Read-only. Ballast doesn't repair disks or change security settings."
        if let date = report?.date, !isChecking {
            text += " Checked \(date.formatted(date: .omitted, time: .shortened))."
        }
        return text
    }
}

/// One group of findings on a chart surface: the rows as they arrive,
/// placeholders for checks still running, and the section's actions.
struct HealthFindingsSection<Actions: View>: View {
    let title: String
    let note: String
    /// Nil until the first check reports.
    let findings: [HealthFinding]?
    /// Checks still running in this section, shown as placeholder rows.
    let pending: Int
    /// False for a section with no actions, so no empty footer is drawn.
    var hasActions = true
    @ViewBuilder var actions: Actions

    private var rows: [HealthFinding] { findings ?? [] }

    var body: some View {
        ChartSection(title: title, note: note) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, finding in
                    if index > 0 { ChartHairline() }
                    HealthFindingRow(finding: finding)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
                if pending > 0 {
                    // Only while checks run: every run ends in rows, "no
                    // readings" or "not checked", never an endless shimmer.
                    if !rows.isEmpty { ChartHairline() }
                    SkeletonRows(count: findings == nil ? max(pending, 2) : pending, showsIcon: false)
                        .transition(.opacity.animation(Motion.exit))
                } else if rows.isEmpty {
                    Text(findings == nil ? "Not checked yet. Check This Mac reads it in a few seconds."
                                         : "macOS reported no readings for this on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, Theme.Space.rowY)
                }
                if hasActions {
                    ChartHairline().padding(.top, 4)
                    HStack(spacing: 14) {
                        actions
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .padding(.top, 10)
                }
            }
            .animation(Motion.animation(Motion.state), value: rows.map(\.id))
        }
    }
}

extension HealthFindingsSection where Actions == EmptyView {
    init(title: String, note: String, findings: [HealthFinding]?, pending: Int) {
        self.init(title: title, note: note, findings: findings, pending: pending, hasActions: false) { EmptyView() }
    }
}

/// A finding: its name and outcome on one line (the outcome as a shape
/// and a word, never hue alone), what was read, and where it came from.
struct HealthFindingRow: View {
    let finding: HealthFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(finding.title).fontWeight(.medium)
                Spacer(minLength: 8)
                StatusMark(state: StatusMark.State(finding.state), title: finding.state.rawValue)
                    .font(.callout)
                    .foregroundStyle(finding.state == .attention ? AnyShapeStyle(Theme.hazard) : AnyShapeStyle(.secondary))
            }
            Text(finding.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(finding.source)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .padding(.vertical, Theme.Space.rowY + 1)
        .accessibilityElement(children: .combine)
    }
}

/// The reviewed package list, folded away until asked for.
struct PackagesToSend: View {
    let inventory: VulnerabilityInventory
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(inventory.packages.count) supported formula versions · \(inventory.excluded) entries excluded")
                .font(.callout.weight(.medium))
                .monospacedDigit()
            DisclosureGroup("Packages to send", isExpanded: $isExpanded) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(inventory.packages, id: \.self) { package in
                        HStack {
                            Text(package.name)
                            Spacer()
                            Text(package.version)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .padding(.vertical, 3)
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
            Text("Only these names and versions go to api.osv.dev, with your IP address. No paths, files, app list or disk health readings. This permission is for this check only.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What OSV said: an all-clear, or each match to act on in magenta.
struct VulnerabilityResults: View {
    let report: VulnerabilityReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(report.checked) versions checked · \(report.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if report.matches.isEmpty {
                StatusMark(state: .passed, title: "No known advisory matches for the checked versions")
            } else {
                StatusMark(state: .attention,
                           title: "\(report.matches.count) advisory \(report.matches.count == 1 ? "match" : "matches"). Check each advisory's affected versions, then update with brew upgrade.")
                    .foregroundStyle(Theme.hazard)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(report.matches.enumerated()), id: \.element.id) { index, match in
                        if index > 0 { ChartHairline() }
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(match.package.name) \(match.package.version)")
                                .fontWeight(.medium)
                                .monospacedDigit()
                            Spacer()
                            Link(match.advisory, destination: match.url)
                                .help("Open the advisory on osv.dev")
                        }
                        .padding(.vertical, Theme.Space.rowY)
                    }
                }
            }
        }
    }
}
