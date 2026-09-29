import Darwin
import Foundation

/// A large file as the walker saw it, before it has a row in the index.
struct WalkFile: Codable, Sendable, Hashable {
    var name: String
    /// Allocated on disk, as folder sizes count it.
    var bytes: Int64
    /// Logical size: what Finder calls the file's size, and what copies of
    /// the same file share.
    var size: Int64
    /// Unix seconds.
    var modified: Int64
    var inode: UInt64

    init(name: String, bytes: Int64, size: Int64, modified: Int64, inode: UInt64) {
        self.name = name
        self.bytes = bytes
        self.size = size
        self.modified = modified
        self.inode = inode
    }

    init(name: String, stat st: stat) {
        self.init(name: name, bytes: Int64(st.st_blocks) * 512, size: Int64(st.st_size),
                  modified: Walker.plausible(Int64(st.st_mtimespec.tv_sec)), inode: UInt64(st.st_ino))
    }
}

/// A large file in the index, with where it is.
struct LargeFile: Identifiable, Hashable, Sendable {
    /// Row id in the `files` table.
    let id: Int64
    /// The folder it's in.
    let dir: Int64
    let name: String
    let bytes: Int64
    let size: Int64
    let modified: Int64
    let inode: UInt64
    /// Display path.
    let path: String

    var kind: FileKind { FileKind(path: path) }
}

extension LargeFile {
    init(row: (id: Int64, dir: Int64, file: WalkFile), path: String) {
        id = row.id
        dir = row.dir
        name = row.file.name
        bytes = row.file.bytes
        size = row.file.size
        modified = row.file.modified
        inode = row.file.inode
        self.path = path
    }
}

/// What the index knows about large files.
struct LargeFileList: Sendable {
    /// Largest first.
    let files: [LargeFile]
    /// False until a full scan has listed every large file: an index from
    /// before large files were recorded only has the folders that changed
    /// since, which would be a misleading list.
    let isComplete: Bool

    static let empty = LargeFileList(files: [], isComplete: false)
}

enum LargeFiles {
    /// Files this big or bigger are listed one by one; everything smaller
    /// stays folded into its folder's size. On a 500 GB Mac with 2.7 million
    /// files that's about 500 files holding 110 GB, where 20 MB would list
    /// 1,200 and 5 MB 4,000. Decimal, so it reads "50 MB" like every
    /// other size Ballast shows.
    static let threshold: Int64 = 50_000_000
}

/// What a large file is, for filtering the list.
enum FileKind: String, CaseIterable, Identifiable, Sendable {
    case video
    case archive
    case virtualMachine
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .video: "Videos"
        case .archive: "Disk Images & Archives"
        case .virtualMachine: "VMs & Containers"
        case .other: "Other"
        }
    }

    private static let videos: Set<String> = [
        "mov", "mp4", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "mts", "m2ts", "3gp",
        "vob", "ogv", "mxf", "braw", "r3d", "insv", "lrv",
    ]
    private static let archives: Set<String> = [
        "dmg", "iso", "img", "sparseimage", "cdr", "toast", "zip", "tar", "gz", "tgz", "bz2", "tbz", "xz",
        "txz", "zst", "lz4", "7z", "rar", "cpio", "pkg", "mpkg", "xip", "ipa", "apk", "aab",
    ]
    /// Virtual disks, and the memory and state files VMs keep beside them.
    private static let virtualDisks: Set<String> = [
        "vmdk", "qcow2", "vdi", "vhd", "vhdx", "hds", "hdd", "vmem", "vmsn", "vmss", "sav", "utm", "pvm",
    ]
    /// Folders that hold a VM or container engine's disks, whatever the
    /// files inside are called.
    private static let vmFolders: Set<String> = [".orbstack", ".lima", ".colima", ".tart", "com.docker.docker", "podman"]
    private static let vmBundles: Set<String> = ["utm", "pvm", "vmwarevm", "avd"]

    init(path: String) {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let folders = (path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        let bundles = folders.map { ($0 as NSString).pathExtension.lowercased() }
        if Self.virtualDisks.contains(ext) || name == "Docker.raw"
            || bundles.contains(where: Self.vmBundles.contains) || folders.contains(where: Self.vmFolders.contains) {
            self = .virtualMachine
        } else if Self.archives.contains(ext) || bundles.contains("sparsebundle") {
            self = .archive
        } else if Self.videos.contains(ext) {
            self = .video
        } else {
            self = .other
        }
    }
}
