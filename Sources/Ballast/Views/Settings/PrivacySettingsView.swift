import SwiftUI

/// Usage data: the switch, what it sends (listed from Telemetry.swift's own
/// definitions), what's waiting to go, and the identifier.
struct PrivacySettingsView: View {
    @Bindable var model: AppModel
    @State private var identifier: UUID?
    @State private var showingQueue = false
    @State private var showingWhatsSent = false

    private var telemetry: Telemetry { model.telemetry }

    var body: some View {
        Form {
            switch telemetry.support {
            case .available(let config):
                Section {
                    Toggle(isOn: sharing) {
                        Text("Share anonymous usage data")
                        Text("Which features get used, how long scans take and the rough size of cleanups, to learn what to improve. Never file or folder names, paths, app names or exact sizes.")
                    }
                } footer: {
                    Text("Off until you turn it on. Turning it off deletes the identifier and anything waiting to be sent.")
                }

                Section {
                    LabeledContent("Identifier") {
                        Text(identifier?.uuidString ?? "None")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Spacer()
                        Button("Show Queued Events…") { showingQueue = true }
                        Button("Reset Identifier") {
                            telemetry.resetIdentifier()
                            identifier = telemetry.distinctID
                        }
                        .help("Start over with a new random identifier. Events waiting to be sent are deleted.")
                    }
                    .disabled(!model.sharesUsageData)
                } footer: {
                    Text("A random identifier made when you turned sharing on, so events from one Mac can be counted together. It isn't tied to you, your Apple Account or this Mac's serial number.")
                }

                Section {
                    DisclosureGroup("What's sent", isExpanded: $showingWhatsSent) {
                        WhatsSent()
                    }
                } footer: {
                    Text("Events wait on this Mac and go to PostHog (\(config.host.host() ?? "")) \(config.host.scheme == "https" ? "over HTTPS" : "without encryption, to this Mac only,") about every half hour. Each asks PostHog not to build a profile or look up a location, but PostHog still sees the IP address they come from, like any server does. Events more than three days old that couldn't be sent are dropped.")
                }

                Section {
                    HStack {
                        Spacer()
                        Link("How It Works, in Ballast's Source", destination: Telemetry.sourceURL)
                    }
                }
            case .unavailable:
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Usage sharing isn't set up in this build")
                        Text("It has no project key to send with, so Ballast never records or sends usage data, and doesn't ask.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Link("How It Works, in Ballast's Source", destination: Telemetry.sourceURL)
                    }
                }
            }
        }
        .settingsPane(scrolls: telemetry.isAvailable)
.onAppear { identifier = telemetry.distinctID }
        .sheet(isPresented: $showingQueue) {
            QueuedEventsSheet(json: telemetry.queuedJSON(), count: telemetry.store.queue().count)
        }
    }

    private var sharing: Binding<Bool> {
        Binding {
            model.sharesUsageData
        } set: { on in
            model.setSharesUsageData(on)
            identifier = telemetry.distinctID
        }
    }
}

/// Every event and property, generated from the definitions that build
/// them, so the list can't drift from what's sent.
private struct WhatsSent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("On every event").font(.headline)
            ForEach(TelemetryProperty.envelope + TelemetryProperty.context, id: \.self) { PropertyLine(property: $0) }
        }
        .padding(.vertical, 4)
        ForEach(TelemetryEvent.Kind.allCases, id: \.self) { kind in
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.rawValue).font(.body.monospaced().weight(.semibold))
                Text(kind.explanation).font(.callout).foregroundStyle(.secondary)
                ForEach(kind.properties, id: \.self) { PropertyLine(property: $0) }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct PropertyLine: View {
    let property: TelemetryProperty

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(Text(property.rawValue).font(.callout.monospaced()))  \(Text(property.explanation).foregroundStyle(.secondary))")
                .font(.callout)
            if let values = property.possibleValues {
                Text(values.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 12)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The queue as it is on disk: exactly what the next request carries,
/// besides the project key.
private struct QueuedEventsSheet: View {
    let json: String
    let count: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Queued Events").font(.title2.weight(.semibold))
                Text(count == 0 ? "Nothing is waiting to be sent."
                     : "\(count) event\(count == 1 ? "" : "s") waiting to be sent, exactly as Ballast will send \(count == 1 ? "it" : "them").")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            Divider()
            ScrollView {
                Text(json)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(.bar)
        }
        .frame(width: 580, height: 520)
    }
}
