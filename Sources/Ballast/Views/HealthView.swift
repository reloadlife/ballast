import AppKit
import SwiftUI

@MainActor @Observable final class HealthModel {
    static let shared = HealthModel()
    var local: LocalHealthReport?
    var checkingLocal = false
    var inventory: VulnerabilityInventory?
    var vulnerabilities: VulnerabilityReport?
    var checkingVulnerabilities = false
    var error: String?
    private var scanTask: Task<VulnerabilityReport, Error>?

    var canCancel: Bool { scanTask != nil }
    func cancel() { scanTask?.cancel() }

    func refresh() async {
        guard !checkingLocal else { return }
        checkingLocal = true
        local = await Task.detached(priority: .utility) { HealthChecks.local() }.value
        checkingLocal = false
    }

    /// Inventory stays local. Sending happens only after the separate confirmation.
    func prepare() async {
        guard !checkingVulnerabilities else { return }
        checkingVulnerabilities = true
        error = nil
        inventory = nil
        vulnerabilities = nil
        do { inventory = try await Task.detached(priority: .utility) { try VulnerabilityInventory.read() }.value }
        catch { self.error = error.localizedDescription }
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
        catch { self.error = error.localizedDescription }
    }
}

struct HealthView: View {
    @State private var model = HealthModel.shared
    @State private var confirmOnline = false

    var body: some View {
        List {
            Section {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Know what needs attention").font(.headline)
                        Text("Read-only checks. Ballast does not repair disks or change security settings.")
                            .foregroundStyle(.secondary)
                        if let date = model.local?.date {
                            Text("Local checks: \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.checkingLocal { ProgressView().controlSize(.small).accessibilityLabel("Checking this Mac") }
                    Button("Check This Mac") { Task { await model.refresh() } }
                        .disabled(model.checkingLocal)
                }
                .padding(.vertical, 6)
            }
            if let report = model.local {
                Section("Storage health") {
                    ForEach(report.storage) { finding in HealthFindingRow(finding: finding) }
                    Button("Open Disk Utility") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app")) }
                    Text("SMART cannot predict every failure. Keep a current backup. Filesystem verification and repairs are available in Disk Utility; Ballast does not run them automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Mac security") {
                    ForEach(report.security) { finding in HealthFindingRow(finding: finding) }
                    Button("Open Privacy & Security") { openSettings("com.apple.settings.PrivacySecurity.extension") }
                    Button("Check macOS Updates…") { openSettings("com.apple.Software-Update-Settings.extension") }
                    Text("Update availability is checked by System Settings, not inferred from the installed macOS version.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Storage and security") {
                    Text("Check SMART, SSD endurance and media errors where available, startup disk space, FileVault, SIP, Gatekeeper, and the firewall.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Known vulnerabilities") {
                Text("Checks installed Homebrew core formula versions in /opt/homebrew and /usr/local against OSV advisories. Mac app bundles, casks, third-party taps, and other package managers are not covered. An empty result means no known matches in this source, not that your Mac is secure.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Review Packages…") { Task { await model.prepare() } }
                        .disabled(model.checkingVulnerabilities)
                    if model.checkingVulnerabilities {
                        ProgressView().controlSize(.small).accessibilityLabel("Checking packages")
                        if model.canCancel { Button("Cancel") { model.cancel() } }
                    }
                }
                if let inventory = model.inventory {
                    Text("\(inventory.packages.count) installed formula versions supported · \(inventory.excluded) inventory entries excluded")
                        .font(.callout).monospacedDigit()
                    DisclosureGroup("Packages to send") {
                        ForEach(inventory.packages, id: \.self) { package in
                            HStack { Text(package.name); Spacer(); Text(package.version).foregroundStyle(.secondary) }
                        }
                    }
                    Text("Only the names and versions shown above are sent to api.osv.dev. No paths, files, app inventory, or disk health data are sent. OSV also receives your IP address. This permission applies to this check only.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Check These Versions Online…") { confirmOnline = true }
                        .disabled(inventory.packages.isEmpty || model.checkingVulnerabilities)
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                if let report = model.vulnerabilities {
                    Text("\(report.checked) versions checked · \(report.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    if report.matches.isEmpty {
                        Label("No known advisory matches for the checked versions", systemImage: "checkmark.circle")
                    } else {
                        Text("\(report.matches.count) advisory matches. Review each advisory's affected versions and update guidance before acting.")
                        ForEach(report.matches) { match in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(match.package.name) \(match.package.version)").fontWeight(.medium)
                                Link(match.advisory, destination: match.url)
                            }.padding(.vertical, 3)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .confirmationDialog("Send package names and versions to OSV?", isPresented: $confirmOnline, titleVisibility: .visible) {
            Button("Send and Check") { Task { await model.scan() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("OSV receives the \(model.inventory?.packages.count ?? 0) package names and versions you reviewed, and your IP address. Disk health and local files stay on this Mac.")
        }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(url) }
    }
}

private struct HealthFindingRow: View {
    let finding: HealthFinding
    private var symbol: String {
        switch finding.state {
        case .passed: "checkmark.circle"
        case .attention: "exclamationmark.triangle"
        case .unavailable: "questionmark.circle"
        case .information: "info.circle"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(finding.title).fontWeight(.medium)
                Spacer()
                Label(finding.state.rawValue, systemImage: symbol)
                    .foregroundStyle(finding.state == .attention ? Color.orange : Color.secondary)
            }
            Text(finding.detail).foregroundStyle(.secondary)
            Text(finding.source).font(.caption).foregroundStyle(.tertiary)
        }
        .textSelection(.enabled)
        .padding(.vertical, 5)
    }
}
