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
        /// For device streams: the mount point their relative paths are under.
        let mountPath: String?

        init(mountPath: String?) {
            self.mountPath = mountPath
        }

        /// A device stream names items relative to the volume ("a/b", ""
        /// for the volume itself); a host stream gives absolute paths.
        func absolute(_ path: String) -> String {
            guard let mountPath else { return path }
            var relative = Substring(path)
            while relative.hasPrefix("/") { relative = relative.dropFirst() }
            return relative.isEmpty ? mountPath : mountPath + "/" + relative
        }
    }

    /// Folders changed under `root` since `eventID`, or nil when the history
    /// can't be trusted (dropped events, wrapped IDs, root moved).
    static func changes(under root: String, since eventID: FSEventStreamEventId, timeout: TimeInterval = 60) -> [Change]? {
        replay(since: eventID, mountPath: nil, timeout: timeout) { callback, context, flags in
            FSEventStreamCreate(nil, callback, context, [root] as CFArray, eventID, 0, flags)
        }
    }

    /// The same for another volume, from the history kept on that volume,
    /// which follows it from mount to mount (and mount point to mount
    /// point). Its paths come back under `root`, where it's mounted now.
    static func changes(
        onDevice device: dev_t, root: String, since eventID: FSEventStreamEventId, timeout: TimeInterval = 60
    ) -> [Change]? {
        replay(since: eventID, mountPath: root, timeout: timeout) { callback, context, flags in
            FSEventStreamCreateRelativeToDevice(nil, callback, context, device, [""] as CFArray, eventID, 0, flags)
        }
    }

    private static func replay(
        since eventID: FSEventStreamEventId, mountPath: String?, timeout: TimeInterval,
        create: (FSEventStreamCallback, UnsafeMutablePointer<FSEventStreamContext>, FSEventStreamCreateFlags) -> FSEventStreamRef?
    ) -> [Change]? {
        let collector = Collector(mountPath: mountPath)
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
                collector.changes.append(Change(path: collector.absolute(paths[i]),
                                                recursive: flag & kFSEventStreamEventFlagMustScanSubDirs != 0))
            }
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = create(callback, &context, flags) else { return nil }
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
