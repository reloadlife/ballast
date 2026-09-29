import CryptoKit
import Darwin
import Foundation

/// How a file shares storage with others on APFS, from `getattrlist`.
struct StorageSharing: Sendable, Hashable {
    /// Bytes no other file (or clone) uses: what deleting this file alone frees.
    let privateBytes: Int64
    /// Files cloned from each other with nothing changed since share an id.
    let cloneID: UInt64?
    /// How many files use this clone's storage, this one included.
    let cloneCount: Int
    /// Every block is shared with another file: an untouched clone.
    let sharesAll: Bool

    /// nil when the volume doesn't say (not APFS).
    static func of(_ path: String) -> StorageSharing? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS
                                    | ATTR_CMNEXT_CLONE_REFCNT)
        var buffer = [UInt8](repeating: 0, count: 128)
        guard getattrlist(path, &list, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) == 0 else {
            return nil
        }
        return buffer.withUnsafeBytes { raw -> StorageSharing? in
            // Length, then which attributes came back, then each in bit order.
            var offset = MemoryLayout<UInt32>.size
            let returned = raw.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self).forkattr
            offset += MemoryLayout<attribute_set_t>.size
            func next<T>(_ bit: Int32, _ type: T.Type) -> T? {
                guard returned & UInt32(bit) != 0 else { return nil }
                defer { offset += MemoryLayout<T>.size }
                return raw.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
            guard let size = next(ATTR_CMNEXT_PRIVATESIZE, Int64.self) else { return nil }
            let clone = next(ATTR_CMNEXT_CLONEID, UInt64.self)
            let flags = next(ATTR_CMNEXT_EXT_FLAGS, UInt64.self) ?? 0
            let count = next(ATTR_CMNEXT_CLONE_REFCNT, UInt32.self)
            return StorageSharing(privateBytes: size, cloneID: clone, cloneCount: Int(count ?? 1),
                                  sharesAll: flags & UInt64(EF_SHARES_ALL_BLOCKS) != 0)
        }
    }
}

/// One copy among files with the same contents.
struct DuplicateCopy: Identifiable, Hashable, Sendable {
    /// Display path.
    let path: String
    /// Allocated on disk.
    let bytes: Int64
    let modified: Int64
    let sharing: StorageSharing?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    /// Bytes deleting this copy alone would free.
    var privateBytes: Int64 { min(sharing?.privateBytes ?? bytes, bytes) }

    /// Copies in Downloads, on the Desktop or in the Trash are the likely
    /// strays; the default keeps a copy that's somewhere on purpose.
    var isStray: Bool {
        let home = NSHomeDirectory()
        return ["/Downloads/", "/Desktop/", "/.Trash/"].contains { path.hasPrefix(home + $0) }
    }
}

/// Files with the same contents. Copies that are untouched APFS clones of
/// each other share their storage: deleting one of them frees nothing.
struct DuplicateGroup: Identifiable, Hashable, Sendable {
    /// Oldest copy outside Downloads, the Desktop and the Trash first: the
    /// one kept unless someone picks another.
    let copies: [DuplicateCopy]
    /// Logical size of each copy.
    let size: Int64
    /// SHA-256 of the contents, in hex.
    let hash: String

    var id: String { hash }
    var suggestedKeep: String { copies[0].path }

    init(copies: [DuplicateCopy], size: Int64, hash: String) {
        self.copies = copies.sorted {
            ($0.isStray ? 1 : 0, $0.modified, $0.path.count, $0.path) < ($1.isStray ? 1 : 0, $1.modified, $1.path.count, $1.path)
        }
        self.size = size
        self.hash = hash
    }

    /// Copies sharing all of their storage, by clone id; every other copy
    /// is a unit of its own.
    private func unit(of copy: DuplicateCopy) -> String {
        if let sharing = copy.sharing, sharing.sharesAll, sharing.cloneCount > 1, let clone = sharing.cloneID {
            return "clone:\(clone)"
        }
        return "file:" + copy.path
    }

    /// Every copy is one clone: there's nothing to gain.
    var sharesStorage: Bool { Set(copies.map(unit)).count == 1 }

    /// What removing every copy but `kept` frees, copy by copy. A clone
    /// whose storage is used only by copies being removed frees it once,
    /// counted on the first of them; if something else still uses it
    /// (another clone Ballast didn't list, say), it frees only its own
    /// changed blocks. Copies that share with the kept one free next to
    /// nothing.
    func freed(keeping kept: String) -> [String: Int64] {
        guard let keep = copies.first(where: { $0.path == kept }) else { return [:] }
        let keptUnit = unit(of: keep)
        var freed: [String: Int64] = [:]
        for (unit, members) in Dictionary(grouping: copies.filter { $0.path != kept }, by: unit) {
            if unit != keptUnit, unit.hasPrefix("clone:"), members[0].sharing?.cloneCount == members.count {
                for (i, member) in members.enumerated() { freed[member.path] = i == 0 ? member.bytes : 0 }
            } else {
                for member in members { freed[member.path] = member.privateBytes }
            }
        }
        return freed
    }

    func reclaimable(keeping kept: String) -> Int64 {
        freed(keeping: kept).values.reduce(0, +)
    }
}

struct DuplicateReport: Sendable {
    /// Largest saving first, with the suggested copy kept.
    let groups: [DuplicateGroup]
    /// Sets of copies that are already clones of one another.
    let cloned: [DuplicateGroup]
    /// Files left out because they're another name for a listed file.
    let hardLinks: Int
    /// Large files left out because they're in a protected place.
    let protectedFiles: Int
    /// Large files looked at.
    let checked: Int

    var reclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable(keeping: $1.suggestedKeep) } }
}

struct DuplicateProgress: Sendable, Equatable {
    enum Stage: Sendable { case comparing, hashing }
    var stage: Stage = .comparing
    var files = 0
    var totalFiles = 0
    var bytes: Int64 = 0
    var totalBytes: Int64 = 0

    var fraction: Double? {
        guard stage == .hashing, totalBytes > 0 else { return nil }
        return min(Double(bytes) / Double(totalBytes), 1)
    }
}

/// Finds large files with identical contents. Bounded by the index's
/// large-file list: files the same size are compared by their first and
/// last 64 KB, and only files that still match are read in full.
enum Duplicates {
    static let sample = 64 << 10

    static func find(
        _ files: [LargeFile],
        isProtected: (String) -> Bool,
        cancel: CancelFlag,
        progress: (DuplicateProgress) -> Void = { _ in }
    ) throws -> DuplicateReport {
        let allowed = files.filter { !isProtected($0.path) }
        var status = DuplicateProgress()
        var hardLinks = 0

        // Same logical size, still there, still that size; one entry per
        // file on disk, so hard links count once.
        var candidates: [[LargeFile]] = []
        for group in Dictionary(grouping: allowed, by: \.size).values where group.count > 1 {
            var seen = Set<[UInt64]>()
            var unique: [LargeFile] = []
            for file in group.sorted(by: { $0.path < $1.path }) {
                var st = stat()
                guard lstat(file.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, Int64(st.st_size) == file.size else { continue }
                if seen.insert([UInt64(bitPattern: Int64(st.st_dev)), UInt64(st.st_ino)]).inserted {
                    unique.append(file)
                } else {
                    hardLinks += 1
                }
            }
            if unique.count > 1 { candidates.append(unique) }
        }

        status.totalFiles = candidates.reduce(0) { $0 + $1.count }
        progress(status)
        var matching: [[LargeFile]] = []
        for group in candidates {
            var bySample: [Data: [LargeFile]] = [:]
            for file in group {
                if cancel.isSet { throw CancellationError() }
                if let digest = try? sampleHash(file.path, size: file.size) { bySample[digest, default: []].append(file) }
                status.files += 1
                progress(status)
            }
            matching += bySample.values.filter { $0.count > 1 }
        }

        status = DuplicateProgress(stage: .hashing, totalFiles: matching.reduce(0) { $0 + $1.count },
                                   totalBytes: matching.reduce(0) { $0 + $1.reduce(0) { $0 + $1.size } })
        progress(status)
        var groups: [DuplicateGroup] = []
        for group in matching {
            var byHash: [String: [LargeFile]] = [:]
            for file in group {
                let before = status.bytes
                if let digest = try? fullHash(file.path, cancel: cancel, read: { status.bytes += $0; progress(status) }) {
                    byHash[digest, default: []].append(file)
                }
                if cancel.isSet { throw CancellationError() }
                status.bytes = before + file.size
                status.files += 1
                progress(status)
            }
            for (hash, same) in byHash where same.count > 1 {
                let copies = same.map { file in
                    DuplicateCopy(path: file.path, bytes: file.bytes, modified: file.modified, sharing: StorageSharing.of(file.path))
                }
                groups.append(DuplicateGroup(copies: copies, size: same[0].size, hash: hash))
            }
        }

        let (cloned, separate) = (groups.filter(\.sharesStorage), groups.filter { !$0.sharesStorage })
        return DuplicateReport(
            groups: separate.sorted { $0.reclaimable(keeping: $0.suggestedKeep) > $1.reclaimable(keeping: $1.suggestedKeep) },
            cloned: cloned.sorted { $0.size > $1.size },
            hardLinks: hardLinks,
            protectedFiles: files.count - allowed.count,
            checked: files.count
        )
    }

    /// SHA-256 of the first and last 64 KB.
    static func sampleHash(_ path: String, size: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        hasher.update(data: try handle.read(upToCount: sample) ?? Data())
        if size > Int64(sample) {
            try handle.seek(toOffset: UInt64(max(size - Int64(sample), Int64(sample))))
            hasher.update(data: try handle.read(upToCount: sample) ?? Data())
        }
        return Data(hasher.finalize())
    }

    /// SHA-256 of the whole file, read in 1 MB pieces past the file cache,
    /// so hashing gigabytes doesn't push everything else out of memory.
    static func fullHash(_ path: String, cancel: CancelFlag, read: (Int64) -> Void = { _ in }) throws -> String {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        let chunk = 1 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var sinceReport: Int64 = 0
        while true {
            if cancel.isSet { throw CancellationError() }
            let count = Darwin.read(fd, buffer.baseAddress, chunk)
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
            sinceReport += Int64(count)
            if sinceReport >= 32 << 20 {
                read(sinceReport)
                sinceReport = 0
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
