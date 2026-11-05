import Foundation

/// What a list's verdicts depend on, for `.task(id:)`: its rows and the
/// folders protected in Settings, so protecting one re-assesses the list.
struct VerdictKey<Rows: Equatable>: Equatable {
    let rows: Rows
    let protected: [String]
}

/// One path whose safety verdict a list wants, for `AppModel.verdicts(for:)`.
struct VerdictRequest: Sendable, Hashable {
    /// Display path.
    let path: String
    let isDirectory: Bool
}

extension AppModel {
    /// Safety verdicts for every row of a list at once, worked out off the
    /// main actor. `SafetyCheck.assess` touches the disk (it resolves
    /// symlinks, reads volume facts and looks for `.git`), so lists call
    /// this from a `.task` instead of asking `listItem(for:)` per row in a
    /// body. The verdict is for display: adding an item still goes through
    /// `listItem(for:)`, and the Cleaner checks again before deleting.
    func verdicts(for requests: [VerdictRequest]) async -> [String: Safety] {
        let apps = self.apps
        let protected = preferences.protectedFolders
        let work = Task.detached(priority: .userInitiated) {
            var found: [String: Safety] = [:]
            for request in requests where found[request.path] == nil {
                if Task.isCancelled { break }
                found[request.path] = SafetyCheck.assess(request.path, isDirectory: request.isDirectory,
                                                          apps: apps, protected: protected)
            }
            return found
        }
        // A detached task doesn't inherit cancellation: pass it on, so a
        // folder left mid-way stops being assessed.
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    /// The same verdicts, delivered in `requests` order a chunk at a time,
    /// so the first rows of a large folder get their toggles at once
    /// instead of after the whole folder is assessed.
    func verdicts(for requests: [VerdictRequest], chunk: Int = 100,
                  deliver: ([String: Safety]) -> Void) async {
        var start = 0
        while start < requests.count, !Task.isCancelled {
            let end = min(start + chunk, requests.count)
            let found = await verdicts(for: Array(requests[start..<end]))
            guard !Task.isCancelled else { return }
            deliver(found)
            start = end
        }
    }

    /// The System Data sheet's state after a load, worked out from what
    /// the model holds (see `SystemDataPhase.after`).
    var systemDataPhase: SystemDataPhase {
        SystemDataPhase.after(report: systemData, hasIndex: hasIndex)
    }
}

/// Where the System Data sheet stands. Every load ends in one of the
/// finished states; `loading` never outlives the load.
enum SystemDataPhase: Equatable {
    case loading
    case loaded
    /// The breakdown came back with nothing large enough to list.
    case empty
    /// There's no index to break down yet.
    case notScanned
    /// The load didn't finish in time.
    case timedOut

    /// The state once a load has returned.
    static func after(report: SystemDataReport?, hasIndex: Bool) -> SystemDataPhase {
        guard hasIndex else { return .notScanned }
        guard let report else { return .timedOut }
        return report.onDisk.isEmpty && report.hidden.isEmpty && report.snapshots.isEmpty ? .empty : .loaded
    }
}
