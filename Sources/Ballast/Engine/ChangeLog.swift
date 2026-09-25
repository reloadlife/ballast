import CoreServices
import Foundation

/// Replays the FSEvents log that macOS keeps on every volume, so we learn
/// which folders changed while Ballast wasn't running.
enum ChangeLog {
    struct Change: Sendable {
        let path: String
        /// FSEvents coalesced too much and wants the whole subtree rechecked.
        let recursive: Bool
    }

    private final class Collector: @unchecked Sendable {
        var changes: [Change] = []
        var historyLost = false
        let done = DispatchSemaphore(value: 0)
    }

    /// Folders changed under `root` since `eventID`, or nil when the history
    /// can't be trusted (dropped events, wrapped IDs, root moved).
    static func changes(under root: String, since eventID: FSEventStreamEventId, timeout: TimeInterval = 60) -> [Change]? {
        let collector = Collector()
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            let collector = Unmanaged<Collector>.fromOpaque(info!).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
            let lost = kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged
            for i in 0..<min(count, paths.count) {
                let flag = Int(flags[i])
                if flag & kFSEventStreamEventFlagHistoryDone != 0 {
                    collector.done.signal()
                    continue
                }
                if flag & lost != 0 { collector.historyLost = true }
                collector.changes.append(Change(path: paths[i], recursive: flag & kFSEventStreamEventFlagMustScanSubDirs != 0))
            }
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray, eventID, 0, flags) else {
            return nil
        }
        let queue = DispatchQueue(label: "ballast.changelog")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        let finished = collector.done.wait(timeout: .now() + timeout) == .success
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        queue.sync {}  // drain any callback still running

        return finished && !collector.historyLost ? collector.changes : nil
    }
}
