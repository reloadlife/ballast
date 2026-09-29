import Darwin
import Foundation

/// One directory's measurements. Only directories are ever stored; files are
/// folded into their parent's `own` bytes, and only the large ones are also
/// listed in `large`.
struct WalkNode: Codable, Sendable {
    /// Walk-local id: 0 is the walk root, children count up in pre-order.
    var local: Int64
    /// Walk-local parent id, -1 for the walk root.
    var parent: Int64
    var name: String
    var own: Int64 = 0
    var ownFiles: Int64 = 0
    var total: Int64 = 0
    var files: Int64 = 0
    /// errno when the directory could not be read (EACCES: Unix permissions,
    /// EPERM: macOS privacy protection).
    var err: Int32 = 0
    /// Newest modification time (Unix seconds) of anything in the subtree:
    /// how recently this folder was actually used.
    var newest: Int64 = 0
    /// Files directly in this folder of at least `LargeFiles.threshold`
    /// allocated, each still counted in `own` like every other file.
    var large: [WalkFile] = []
}

struct WalkProgress: Sendable {
    var dirs = 0
    var files = 0
    var bytes: Int64 = 0
    var path = ""
}

enum Walker {
    /// Modification times past this are bogus (clock skew, broken archives)
    /// and would make every ancestor look "modified in the future".
    static var latestPlausibleTime: Int64 { Int64(Date.now.timeIntervalSince1970) + 86_400 }

    static func plausible(_ time: Int64) -> Int64 {
        time <= latestPlausibleTime ? time : 0
    }

    /// Whether a folder on `device` belongs to a walk that started on
    /// `root`: another volume mounted inside (a disk image under
    /// /Volumes, a network share in the home folder) never does.
    static func descends(into device: dev_t, from root: dev_t) -> Bool {
        device == root
    }

    /// Measures everything under `path` on its own volume, like `du -x`.
    /// Emits one node per directory in post-order (children before parents),
    /// so a node's totals are final when it is emitted; the root comes last.
    /// Folders in `skip` (full paths below `path`) are left out entirely.
    /// Files of at least `largeFiles` allocated bytes are listed in their
    /// folder's node.
    static func walk(
        _ path: String,
        skip: Exclusions = Exclusions([]),
        largeFiles: Int64 = LargeFiles.threshold,
        cancelled: () -> Bool = { false },
        progress: (WalkProgress) -> Void = { _ in },
        emit: (WalkNode) throws -> Void
    ) throws {
        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else {
            try emit(WalkNode(local: 0, parent: -1, name: path, err: errno))
            return
        }
        let device = rootStat.st_dev

        let cPath = strdup(path)
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
            try emit(WalkNode(local: 0, parent: -1, name: path, err: errno))
            return
        }
        defer { fts_close(fts) }

        var stack: [WalkNode] = []
        var nextLocal: Int64 = 0
        var seenHardLinks = Set<UInt64>()
        var stats = WalkProgress(path: path)
        var lastReport = DispatchTime.now().uptimeNanoseconds
        var ticks = 0

        func open(_ ent: UnsafeMutablePointer<FTSENT>) -> WalkNode {
            defer { nextLocal += 1 }
            var node = WalkNode(local: nextLocal, parent: stack.last?.local ?? -1, name: stack.isEmpty ? path : name(of: ent))
            if let st = ent.pointee.fts_statp?.pointee {
                node.newest = plausible(Int64(st.st_mtimespec.tv_sec))
                // The folder's own entries, as du counts them: zero on APFS
                // and Mac OS Extended, a cluster or more on ExFAT and FAT.
                node.own = Int64(st.st_blocks) * 512
            }
            return node
        }

        func finish(_ node: inout WalkNode) throws {
            node.total += node.own
            node.files += node.ownFiles
            if !stack.isEmpty {
                stack[stack.count - 1].total += node.total
                stack[stack.count - 1].files += node.files
                stack[stack.count - 1].newest = max(stack[stack.count - 1].newest, node.newest)
            }
            stats.dirs += 1
            try emit(node)
        }

        while let ent = fts_read(fts) {
            ticks += 1
            if ticks & 0x3FF == 0 {
                if cancelled() { throw CancellationError() }
                let now = DispatchTime.now().uptimeNanoseconds
                if now - lastReport > 150_000_000 {
                    stats.path = String(cString: ent.pointee.fts_path)
                    progress(stats)
                    lastReport = now
                }
            }

            let info = Int32(ent.pointee.fts_info)
            switch info {
            case FTS_D:
                if !descends(into: ent.pointee.fts_statp.pointee.st_dev, from: device) {
                    fts_set(fts, ent, FTS_SKIP)  // another volume mounted inside
                    continue
                }
                if !skip.isEmpty, ent.pointee.fts_level > 0, skip.contains(String(cString: ent.pointee.fts_path)) {
                    fts_set(fts, ent, FTS_SKIP)  // excluded in Settings
                    continue
                }
                stack.append(open(ent))

            case FTS_DP:
                // Skipped directories (other volumes) still get an FTS_DP but
                // were never pushed; only pop when the level matches the stack.
                guard stack.count == Int(ent.pointee.fts_level) + 1 else { continue }
                var node = stack.removeLast()
                try finish(&node)

            case FTS_DNR, FTS_ERR:
                // fts may report FTS_D first and then FTS_DNR for the same
                // directory once reading it fails; the level tells them apart.
                var node: WalkNode
                if stack.count == Int(ent.pointee.fts_level) + 1 {
                    node = stack.removeLast()
                } else if info == FTS_DNR {
                    node = open(ent)
                } else {
                    continue
                }
                node.err = ent.pointee.fts_errno == 0 ? EACCES : ent.pointee.fts_errno
                try finish(&node)

            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard !stack.isEmpty, let st = ent.pointee.fts_statp?.pointee else { continue }
                if info == FTS_F, st.st_nlink > 1, !seenHardLinks.insert(st.st_ino).inserted {
                    continue  // count each hard-linked file once
                }
                let size = Int64(st.st_blocks) * 512
                if info == FTS_F, size >= largeFiles {
                    stack[stack.count - 1].large.append(WalkFile(name: name(of: ent), stat: st))
                }
                stack[stack.count - 1].own += size
                stack[stack.count - 1].ownFiles += 1
                stack[stack.count - 1].newest = max(stack[stack.count - 1].newest, plausible(Int64(st.st_mtimespec.tv_sec)))
                stats.files += 1
                stats.bytes += size

            default:
                continue  // FTS_DC (cycle), FTS_NS (stat failed), FTS_DOT
            }
        }
        progress(stats)
    }

    private static func name(of ent: UnsafeMutablePointer<FTSENT>) -> String {
        let e = ent.pointee
        let start = UnsafeRawPointer(e.fts_path!).advanced(by: Int(e.fts_pathlen) - Int(e.fts_namelen))
        return String(decoding: UnsafeRawBufferPointer(start: start, count: Int(e.fts_namelen)), as: UTF8.self)
    }
}
