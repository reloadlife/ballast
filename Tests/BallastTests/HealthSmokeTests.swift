import AppKit
import SwiftUI
import Testing
@testable import Ballast

/// Opt-in read-only diagnostics and native view render. Never contacts OSV.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BALLAST_HEALTH_SMOKE"] == "1"))
struct HealthSmokeTests {
    @Test @MainActor func localChecksAndNativeView() async throws {
        let report = await Task.detached { HealthChecks.local() }.value
        #expect(!report.storage.isEmpty)
        #expect(report.security.count == 4)
        for finding in report.storage + report.security {
            print("HEALTH \(finding.title): \(finding.state.rawValue) — \(finding.detail)")
        }
        let inventory = try await Task.detached { try VulnerabilityInventory.read() }.value
        print("HEALTH inventory: \(inventory.packages.count) supported versions; \(inventory.excluded) excluded")
        HealthModel.shared.local = report
        HealthModel.shared.inventory = inventory
        _ = NSApplication.shared
        let host = NSHostingView(rootView: HealthView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/ballast-health-preview.png"))
        window.orderOut(nil)
    }
}
