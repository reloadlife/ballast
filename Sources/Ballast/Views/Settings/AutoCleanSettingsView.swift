import SwiftUI

/// Rules that clean build folders of projects you haven't touched in a while.
struct AutoCleanSettingsView: View {
    @Bindable var model: AppModel
    @State private var confirmingRun = false

    private static let dayChoices = [1, 3, 7, 14, 30, 90]

    var body: some View {
        let due = model.autoCleanDue
        Form {
            Section {
                Toggle(isOn: $model.autoClean.background) {
                    Text("Run every day in the background")
                    Text("Around 12:30, even when Ballast is closed. You'll get a notification when something is cleaned.")
                }
                .disabled(!model.autoClean.anyEnabled && !model.autoClean.background)

                LabeledContent("Due now") {
                    if due.isEmpty {
                        Text(model.autoClean.anyEnabled ? "Nothing" : "Turn on a rule below")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(folders(due.count)) · \(due.reduce(0) { $0 + $1.0.bytes }.bytes)")
                            .monospacedDigit()
                    }
                }

                LabeledContent("Last run") {
                    if let last = model.lastAutoClean {
                        Text("\(last.date.formatted(.relative(presentation: .named))) · \(folders(last.cleaned.count)), \(last.cleanedBytes.bytes)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never").foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Spacer()
                    Button("Run Now…") { confirmingRun = true }
                        .disabled(due.isEmpty || model.isScanning)
                }
            } footer: {
                Text("A folder is cleaned when its project hasn't changed for the number of days you pick. Ballast checks each one right before removing it: the project file that proves it's build output must still be there, and it must be safe to remove.")
            }

            Section("Rules") {
                ForEach(rows, id: \.kind) { row in
                    RuleRow(rule: binding(for: row.kind), found: row.found, due: row.due, choices: Self.dayChoices)
                }
            }
        }
        .formStyle(.grouped)
        // The one long tab: scrolls, and lets the window grow.
        .frame(width: 600)
        .frame(minHeight: 560, maxHeight: .infinity)
        .confirmationDialog("Clean \(due.count) build \(due.count == 1 ? "folder" : "folders") now?", isPresented: $confirmingRun) {
            Button("Clean Now") { Task { await model.runAutoCleanNow() } }
        } message: {
            Text("Each rule's Trash or Delete setting applies. Folders come back with the next install or build.")
        }
    }

    private func folders(_ count: Int) -> String {
        "\(count) folder\(count == 1 ? "" : "s")"
    }

    /// Kinds found on this Mac first, biggest first; the rest after.
    private var rows: [(kind: ArtifactKind, found: (count: Int, bytes: Int64), due: (count: Int, bytes: Int64))] {
        let due = model.autoCleanDue
        return ArtifactKind.allCases.map { kind in
            let matches = model.artifacts.filter { $0.kind == kind }
            let dueMatches = due.filter { $0.0.kind == kind }
            return (kind, (matches.count, matches.reduce(0) { $0 + $1.bytes }),
                    (dueMatches.count, dueMatches.reduce(0) { $0 + $1.0.bytes }))
        }
        .sorted { ($0.found.bytes, $0.kind.title) > ($1.found.bytes, $1.kind.title) }
    }

    private func binding(for kind: ArtifactKind) -> Binding<AutoCleanRule> {
        Binding {
            model.autoClean.rule(for: kind)
        } set: { rule in
            if let index = model.autoClean.rules.firstIndex(where: { $0.kind == kind }) {
                model.autoClean.rules[index] = rule
            }
        }
    }
}

private struct RuleRow: View {
    @Binding var rule: AutoCleanRule
    let found: (count: Int, bytes: Int64)
    let due: (count: Int, bytes: Int64)
    let choices: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $rule.enabled) {
                HStack(spacing: 8) {
                    Image(systemName: rule.kind.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.kind.title)
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if rule.enabled && due.count > 0 {
                            Text("\(due.count) due now · \(due.bytes.bytes)")
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            if rule.enabled {
                // In a grouped form a labeled picker takes the whole row, so
                // both pickers sit in one LabeledContent. (A trailing text
                // next to them used to get squeezed to a sliver and wrap one
                // letter per line, stretching the row.)
                LabeledContent("Clean after") {
                    HStack(spacing: 8) {
                        Picker("Clean after", selection: $rule.days) {
                            ForEach(choices, id: \.self) { days in
                                Text(label(days)).tag(days)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Picker("How", selection: $rule.permanent) {
                            Text("Delete").tag(true)
                            Text("Move to Trash").tag(false)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .padding(.leading, 26)
            }
        }
        .opacity(found.count == 0 && !rule.enabled ? 0.6 : 1)
    }

    private var summary: String {
        let names = rule.kind.folderNames.joined(separator: ", ")
        let where_ = found.count == 0
            ? "none on this Mac"
            : "\(found.count) on this Mac · \(found.bytes.bytes)"
        return "\(names) · \(where_) · back with \(rule.kind.rebuild)"
    }

    private func label(_ days: Int) -> String {
        switch days {
        case 1: "1 day unused"
        case 7: "1 week unused"
        case 14: "2 weeks unused"
        case 30: "1 month unused"
        case 90: "3 months unused"
        default: "\(days) days unused"
        }
    }
}
