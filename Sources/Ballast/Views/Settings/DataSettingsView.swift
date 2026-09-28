import AppKit
import SwiftUI

/// What Ballast keeps on disk, and ways to start over.
struct DataSettingsView: View {
    let model: AppModel
    @State private var indexBytes: Int64 = 0
    @State private var confirmingRebuild = false
    @State private var confirmingClear = false

    private var hasLogs: Bool { FileManager.default.fileExists(atPath: Paths.logsDir) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    Text(Paths.supportDir.replacingOccurrences(of: Catalog.home, with: "~"))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Size") {
                    Text(indexBytes > 0 ? indexBytes.bytes : "No index yet").monospacedDigit()
                }
                LabeledContent("Last updated") {
                    Text(model.overview?.scannedAt?.formatted(.relative(presentation: .named)) ?? "Never")
                }
                HStack {
                    Button("Show in Finder") {
                        Finder.reveal(FileManager.default.fileExists(atPath: Paths.index) ? Paths.index : Paths.supportDir)
                    }
                    Spacer()
                    Button("Rebuild Index…") { confirmingRebuild = true }
                        .disabled(model.isScanning)
                }
            } header: {
                Text("Index")
            } footer: {
                Text("A map of every folder and its size. It holds no file contents.")
            }

            Section {
                LabeledContent("Readings") {
                    if let first = model.history.first {
                        Text("\(model.history.count) since \(first.date.formatted(date: .abbreviated, time: .omitted))")
                            .monospacedDigit()
                    } else {
                        Text("None yet")
                    }
                }
                LabeledContent("Folder sizes") {
                    if let since = model.growth.since {
                        Text("\(model.growth.days) day\(model.growth.days == 1 ? "" : "s") since \(since.formatted(date: .abbreviated, time: .omitted))")
                            .monospacedDigit()
                    } else {
                        Text("None yet")
                    }
                }
                HStack {
                    Spacer()
                    Button("Clear History…") { confirmingClear = true }
                        .disabled(model.history.isEmpty && model.growth.days == 0)
                }
            } header: {
                Text("History")
            } footer: {
                Text("The free space chart and What grew on the Overview. Ballast records free space when it updates and after each cleanup, and the size of every folder over 20 MB once a day, kept for 90 days.")
            }

            Section {
                LabeledContent("Auto-clean log") {
                    Text(Paths.logsDir.replacingOccurrences(of: Catalog.home, with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    if !hasLogs {
                        Text("Written after the first background run.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show in Finder") { Finder.reveal(Paths.logsDir) }
                        .disabled(!hasLogs)
                }
            } header: {
                Text("Logs")
            }
        }
        .settingsPane()
        .task(id: model.overview?.scannedAt) { indexBytes = Self.indexSize() }
        .confirmationDialog("Rebuild the index?", isPresented: $confirmingRebuild) {
            Button("Rebuild Index") { Task { await model.fullScan() } }
        } message: {
            Text("Ballast measures every folder again, which takes a few minutes. The current index stays in use until the new one is ready.")
        }
        .confirmationDialog("Clear history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("The free space chart and What grew start over. This can't be undone.")
        }
    }

    /// The database plus its write-ahead files.
    private static func indexSize() -> Int64 {
        ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: Paths.index + suffix))?[.size] as? Int64
            return total + (size ?? 0)
        }
    }
}
