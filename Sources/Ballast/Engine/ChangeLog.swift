import CoreServices
import Foundation
import os

/// Replays the FSEvents log that macOS keeps on every volume, so we learn
/// which folders changed while Ballast wasn't running.
enum ChangeLog {
    struct Change: Sendable, Equatable {
        let path: String
        /// FSEvents coalesced too much and wants the whole subtree rechecked.
        let recursive: Bool
    }

    /// How a replay ended.
    enum Outcome: Sendable {
        /// Every distinct folder that changed, once each, sorted by path.
        case changes([Change])
        /// More distinct folders than the limit: the replay stopped there.
        case tooMany(Int)
        /// Dropped events, wrapped IDs or a moved root: the history can't be trusted.
        case historyLost
        /// The history didn't finish within the time allowed.
        case timedOut(events: Int)
        /// The stream couldn't be created or started.
        case unavailable
    }

    /// Turns raw events into distinct folders as they arrive: drops what
    /// `normalize` rejects (outside the root, excluded), merges repeats of
    /// a folder (one recursive event makes it recursive), and skips folders
    /// inside one already marked for a recursive recheck. A replay of an
    /// afternoon's history is 100k+ events naming a few thousand folders.
    struct Accumulator: Sendable {
        /// Raw event path → the folder to recheck, or nil to drop the event.
        let normalize: @Sendable (String) -> String?
        /// Distinct folders past this and `isFull` turns true.
        let limit: Int
        private(set) var folders: [String: Bool] = [:]
        private(set) var events = 0
        private var recursive = Set<String>()

        init(limit: Int = .max, normalize: @escaping @Sendable (String) -> String? = { ChangeLog.trimmed($0) }) {
            self.limit = limit
            self.normalize = normalize
        }

        var isFull: Bool { folders.count > limit }

        mutating func add(_ rawPath: String, recursive isRecursive: Bool) {
            events += 1
            guard let path = normalize(rawPath), !isCovered(path) else { return }
            if isRecursive {
                folders[path] = true
                recursive.insert(path)
            } else if folders[path] == nil {
                folders[path] = false
            }
        }

        /// Inside a folder that is already rechecked recursively.
        private func isCovered(_ path: String) -> Bool {
            guard !recursive.isEmpty else { return false }
            var current = Substring(path)
            while let slash = current.lastIndex(of: "/"), slash > current.startIndex {
                current = current[..<slash]
                if recursive.contains(String(current)) { return true }
            }
            return false
        }

        var changes: [Change] {
            folders.map { Change(path: $0.key, recursive: $0.value) }.sorted { $0.path < $1.path }
        }
    }

    /// Strips the trailing slash FSEvents puts on folder paths.
    static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private struct State: Sendable {
        var accumulator: Accumulator
        var historyLost = false
        var stopped = false
        /// Uptime of the last event, for extending the deadline.
        var lastEvent: UInt64 = 0
    }

    private final class Collector: Sendable {
        let state: OSAllocatedUnfairLock<State>
        let done = DispatchSemaphore(value: 0)
        /// For device streams: the mount point their relative paths are under.
        let mountPath: String?

        init(mountPath: String?, accumulator: Accumulator) {
            self.mountPath = mountPath
            state = OSAllocatedUnfairLock(initialState: State(accumulator: accumulator))
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

    /// How long a replay may take. History arrives in bursts, so the wait
    /// is extended while events keep coming, up to `ceiling`.
    struct Timing: Sendable {
        /// Given up after this long unless events are still arriving.
        var timeout: TimeInterval = 60
        /// Once events have started, how long a pause still counts as "arriving".
        var quiet: TimeInterval = 15
        /// Never longer than this in all.
        var ceiling: TimeInterval = 600
    }

    // MARK: Compatibility

    /// Folders changed under `root` since `eventID`, or nil when the history
    /// can't be trusted (dropped events, wrapped IDs, root moved).
    static func changes(under root: String, since eventID: FSEventStreamEventId, timeout: TimeInterval = 60) -> [Change]? {
        if case .changes(let changes) = replay(under: root, since: eventID, accumulator: Accumulator(),
                                               timing: Timing(timeout: timeout)) {
            return changes
        }
        return nil
    }

    /// The same for another volume, from the history kept on that volume,
    /// which follows it from mount to mount (and mount point to mount
    /// point). Its paths come back under `root`, where it's mounted now.
    static func changes(
        onDevice device: dev_t, root: String, since eventID: FSEventStreamEventId, timeout: TimeInterval = 60
    ) -> [Change]? {
        if case .changes(let changes) = replay(onDevice: device, root: root, since: eventID, accumulator: Accumulator(),
                                               timing: Timing(timeout: timeout)) {
            return changes
        }
        return nil
    }

    // MARK: Replay

    /// Replays the host history under `root`. `progress` gets the number of
    /// raw events read so far, a few times a second, on the calling thread.
    static func replay(
        under root: String, since eventID: FSEventStreamEventId, accumulator: Accumulator,
        timing: Timing = Timing(), progress: (Int) -> Void = { _ in }
    ) -> Outcome {
        replay(since: eventID, mountPath: nil, accumulator: accumulator, timing: timing, progress: progress) { callback, context, flags in
            FSEventStreamCreate(nil, callback, context, [root] as CFArray, eventID, 0, flags)
        }
    }

    /// Replays the history kept on another volume.
    static func replay(
        onDevice device: dev_t, root: String, since eventID: FSEventStreamEventId, accumulator: Accumulator,
        timing: Timing = Timing(), progress: (Int) -> Void = { _ in }
    ) -> Outcome {
        replay(since: eventID, mountPath: root, accumulator: accumulator, timing: timing, progress: progress) { callback, context, flags in
            FSEventStreamCreateRelativeToDevice(nil, callback, context, device, [""] as CFArray, eventID, 0, flags)
        }
    }

    private static func replay(
        since eventID: FSEventStreamEventId, mountPath: String?, accumulator: Accumulator, timing: Timing,
        progress: (Int) -> Void,
        create: (FSEventStreamCallback, UnsafeMutablePointer<FSEventStreamContext>, FSEventStreamCreateFlags) -> FSEventStreamRef?
    ) -> Outcome {
        let collector = Collector(mountPath: mountPath, accumulator: accumulator)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            let collector = Unmanaged<Collector>.fromOpaque(info!).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
            let lost = kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged
            let events = (0..<min(count, paths.count)).map { (path: collector.absolute(paths[$0]), flag: Int(flags[$0])) }
            let finished = collector.state.withLock { state -> Bool in
                guard !state.stopped else { return false }
                state.lastEvent = DispatchTime.now().uptimeNanoseconds
                for event in events {
                    if event.flag & kFSEventStreamEventFlagHistoryDone != 0 {
                        state.stopped = true
                        return true
                    }
                    if event.flag & lost != 0 { state.historyLost = true }
                    state.accumulator.add(event.path, recursive: event.flag & kFSEventStreamEventFlagMustScanSubDirs != 0)
                    // Nothing more can change the answer: stop reading.
                    if state.accumulator.isFull || state.historyLost {
                        state.stopped = true
                        return true
                    }
                }
                return false
            }
            if finished { collector.done.signal() }
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = create(callback, &context, flags) else { return .unavailable }
        let queue = DispatchQueue(label: "ballast.changelog")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return .unavailable
        }

        let start = DispatchTime.now().uptimeNanoseconds
        func seconds(_ nanoseconds: UInt64) -> TimeInterval { TimeInterval(nanoseconds) / 1e9 }
        var finished = false
        while true {
            if collector.done.wait(timeout: .now() + 0.25) == .success {
                finished = true
                break
            }
            let (events, lastEvent) = collector.state.withLock { ($0.accumulator.events, $0.lastEvent) }
            progress(events)
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = seconds(now - start)
            if elapsed >= timing.ceiling { break }
            let stillArriving = lastEvent > 0 && seconds(now - lastEvent) < timing.quiet
            if elapsed >= timing.timeout, !stillArriving { break }
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        queue.sync {}  // drain any callback still running

        let state = collector.state.withLock { $0 }
        if state.historyLost { return .historyLost }
        if state.accumulator.isFull { return .tooMany(state.accumulator.folders.count) }
        guard finished else { return .timedOut(events: state.accumulator.events) }
        return .changes(state.accumulator.changes)
    }
}
