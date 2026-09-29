import CoreServices
import Darwin
import Foundation
import IOKit

/// Which index a screen reads: the startup disk's, or another volume's by
/// its UUID.
enum DiskID: Hashable, Sendable {
    case startup
    case volume(String)

    var uuid: String? {
        if case .volume(let uuid) = self { return uuid }
        return nil
    }
}

/// A mounted volume other than the startup disk that Ballast can index.
struct MountedVolume: Sendable, Hashable, Identifiable {
    /// `URLResourceKey.volumeUUIDStringKey`, canonical upper case.
    let uuid: String
    let name: String
    /// Mount point, e.g. "/Volumes/Backup SSD".
    let path: String
    /// "APFS", "ExFAT", "FAT32"…
    let format: String
    let isReadOnly: Bool
    /// APFS and HFS+ keep an FSEvents history that survives unplugging;
    /// ExFAT and FAT drives get a fresh one on every mount.
    let isJournaled: Bool
    /// USB and Thunderbolt drives, SD cards and disk images.
    let isRemovable: Bool
    let total: Int64
    let free: Int64
    let device: dev_t

    var id: String { uuid }
}

/// A volume the list names but can't index, with why.
struct UnsupportedVolume: Sendable, Hashable, Identifiable {
    let name: String
    let path: String
    let reason: String
    var id: String { path }
}

/// Everything the volume list decides on, read once per volume, so the
/// decision itself is a pure function tests can feed.
struct VolumeCandidate: Sendable {
    var path: String
    var uuid: String?
    var name: String
    var typeName: String
    var formatDescription: String
    var isLocal = true
    var isRootFileSystem = false
    /// Same device as /System/Volumes/Data: the startup disk's data half.
    var isStartupData = false
    /// APFS volume roles from the IORegistry ("Backup", "System", "Data"…).
    var roles: [String] = []
    /// Backups.backupdb or Time Machine's own files at the top.
    var hasTimeMachineFiles = false
    var isReadOnly = false
    var isJournaled = false
    var isRemovable = false
    var total: Int64 = 0
    var free: Int64 = 0
    var device: dev_t = 0
}

enum VolumeKind: Equatable, Sendable {
    /// Listed, and scanned when the user asks.
    case indexable
    /// Listed with a reason, never scanned.
    case unsupported(String)
    /// Not listed at all: the startup disk, macOS's own helper volumes and
    /// Time Machine backups (slow to scan, dangerous to clean).
    case hidden
}

enum Volumes {
    /// APFS roles macOS uses for its own plumbing; `.skipHiddenVolumes`
    /// usually hides these already.
    private static let systemRoles: Set<String> = [
        "Preboot", "Recovery", "VM", "Update", "Hardware", "xART", "Baseband", "Prelinked", "Enterprise", "Installer",
    ]

    static func classify(_ volume: VolumeCandidate) -> VolumeKind {
        if volume.isRootFileSystem || volume.isStartupData || volume.path == "/" { return .hidden }
        if volume.path.hasPrefix("/Volumes/.timemachine") || volume.path.hasPrefix("/System/Volumes/")
            || volume.roles.contains("Backup") || volume.hasTimeMachineFiles {
            return .hidden
        }
        if volume.roles.contains(where: systemRoles.contains) { return .hidden }
        if !volume.isLocal { return .unsupported("Network drives aren't supported yet.") }
        guard let uuid = volume.uuid, UUID(uuidString: uuid) != nil else {
            return .unsupported("This drive has no identifier, so Ballast can't keep an index for it.")
        }
        return .indexable
    }

    /// "APFS", "Mac OS Extended", "ExFAT", "FAT32", "NTFS": short names for
    /// the formats people know, the system's description for the rest.
    static func formatName(type: String, description: String) -> String {
        switch type.lowercased() {
        case "apfs": "APFS"
        case "hfs": "Mac OS Extended"
        case "exfat": "ExFAT"
        case "msdos": description.contains("32") ? "FAT32" : (description.isEmpty ? "FAT" : description)
        case "ntfs": "NTFS"
        default: description.isEmpty ? type.uppercased() : description
        }
    }

    private static let keys: [URLResourceKey] = [
        .volumeUUIDStringKey, .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeTypeNameKey,
        .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey, .volumeIsRemovableKey,
        .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsJournalingKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ]

    /// Mounted volumes worth listing, and the ones that can't be indexed.
    static func mounted() -> (indexable: [MountedVolume], unsupported: [UnsupportedVolume]) {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var startupData = stat()
        lstat(Paths.volumeRoot, &startupData)
        var indexable: [MountedVolume] = []
        var unsupported: [UnsupportedVolume] = []
        for url in urls {
            guard let candidate = candidate(url, startupDevice: startupData.st_dev) else { continue }
            switch classify(candidate) {
            case .hidden: continue
            case .unsupported(let reason):
                unsupported.append(UnsupportedVolume(name: candidate.name, path: candidate.path, reason: reason))
            case .indexable:
                guard let uuid = candidate.uuid.flatMap(UUID.init(uuidString:))?.uuidString else { continue }
                indexable.append(MountedVolume(
                    uuid: uuid, name: candidate.name, path: candidate.path,
                    format: formatName(type: candidate.typeName, description: candidate.formatDescription),
                    isReadOnly: candidate.isReadOnly, isJournaled: candidate.isJournaled,
                    isRemovable: candidate.isRemovable, total: candidate.total, free: candidate.free,
                    device: candidate.device))
            }
        }
        return (indexable.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, unsupported)
    }

    private static func candidate(_ url: URL, startupDevice: dev_t) -> VolumeCandidate? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let path = url.path
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        var fs = statfs()
        let hasStatfs = statfs(path, &fs) == 0
        let isLocal = values.volumeIsLocal ?? (hasStatfs && fs.f_flags & UInt32(MNT_LOCAL) != 0)
        let fm = FileManager.default
        return VolumeCandidate(
            path: path,
            uuid: values.volumeUUIDString,
            name: values.volumeName ?? url.lastPathComponent,
            typeName: values.volumeTypeName ?? (hasStatfs ? fsString(fs.f_fstypename) : ""),
            formatDescription: values.volumeLocalizedFormatDescription ?? "",
            isLocal: isLocal,
            isRootFileSystem: values.volumeIsRootFileSystem ?? false,
            isStartupData: st.st_dev == startupDevice,
            // Only local volumes: asking the IORegistry about a network
            // mount is meaningless.
            roles: isLocal && hasStatfs ? roles(bsdName: fsString(fs.f_mntfromname)) : [],
            hasTimeMachineFiles: isLocal && (fm.fileExists(atPath: path + "/Backups.backupdb")
                || fm.fileExists(atPath: path + "/.com.apple.timemachine.donotpresent")),
            isReadOnly: values.volumeIsReadOnly ?? false,
            isJournaled: values.volumeIsJournaling ?? false,
            isRemovable: (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false),
            total: Int64(values.volumeTotalCapacity ?? 0),
            // ExFAT reports 0 for "important usage"; the plain figure is right there.
            free: values.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
                ?? Int64(values.volumeAvailableCapacity ?? 0),
            device: st.st_dev)
    }

    /// APFS roles of the volume behind "/dev/disk5s1": ["Backup"] for a
    /// Time Machine disk, ["System"] or ["Data"] for a macOS install.
    static func roles(bsdName device: String) -> [String] {
        let name = device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : device
        guard name.hasPrefix("disk"), let matching = IOBSDNameMatching(kIOMainPortDefault, 0, name) else { return [] }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "Role" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String] ?? []
    }

    fileprivate static func fsString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: Known volumes

    /// A volume with an index, connected or not.
    struct Known: Sendable, Hashable, Identifiable {
        let uuid: String
        let name: String
        let format: String
        /// Where it was mounted when last scanned or seen.
        let lastPath: String
        let scannedAt: Date?
        let isJournaled: Bool
        let isRemovable: Bool
        /// Capacity when last seen, for the list while it's unplugged.
        let total: Int64
        var id: String { uuid }
    }

    /// Every volume with an index in `volumes/`.
    static func known(in directory: String = Paths.volumesDir) -> [Known] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        return names.compactMap { name -> Known? in
            guard let uuid = UUID(uuidString: name)?.uuidString, uuid == name else { return nil }
            let index = directory + "/" + name + "/index.sqlite"
            guard fm.fileExists(atPath: index), let db = try? IndexDB(path: index, mode: .read) else { return nil }
            func meta(_ key: String) -> String? { (try? db.meta(key)) ?? nil }
            guard let path = meta("mountPath") else { return nil }
            return Known(
                uuid: uuid,
                name: meta("volumeName") ?? (path as NSString).lastPathComponent,
                format: meta("format") ?? "",
                lastPath: path,
                scannedAt: meta("scannedAt").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                isJournaled: meta("journaled") == "1",
                isRemovable: meta("removable") != "0",
                total: meta("totalBytes").flatMap(Int64.init) ?? 0)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Deletes a volume's index folder, and nothing outside `volumes/`.
    static func forget(_ uuid: String, in directory: String = Paths.volumesDir) throws {
        guard let folder = Paths.volumeDir(uuid, in: directory) else {
            throw IndexError(message: "not a volume identifier: \(uuid)")
        }
        let resolved = (folder as NSString).standardizingPath
        guard resolved.hasPrefix((directory as NSString).standardizingPath + "/") else {
            throw IndexError(message: "refusing to delete \(folder)")
        }
        if FileManager.default.fileExists(atPath: resolved) {
            try FileManager.default.removeItem(atPath: resolved)
        }
    }

    // MARK: Free space

    /// Free bytes on the volume holding `path`, as statfs counts them.
    static func freeBytes(at path: String) -> Int64? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }
}

// MARK: Drives, for the safety rules

/// What the safety rules need to know about the drive holding a path that
/// isn't on the startup disk.
struct DriveFacts: Sendable, Equatable {
    /// Mount point, e.g. "/Volumes/Backup SSD".
    var mountPath: String
    var name: String
    var isConnected = true
    var isReadOnly = false
    var isLocal = true
    var isTimeMachine = false
    /// Holds a macOS installation (another startup disk, or its data).
    var holdsMacOS = false
}

enum Drives {
    /// The drive under /Volumes holding `path`, or nil for paths on the
    /// startup disk. A /Volumes path whose drive isn't mounted gets
    /// `isConnected == false`.
    static func facts(for path: String) -> DriveFacts? {
        guard path.hasPrefix("/Volumes/"), !path.contains("/../") else { return nil }
        guard let fs = statfsOfNearest(path) else { return nil }
        let mount = Volumes.fsString(fs.f_mntonname)
        guard mount.hasPrefix("/Volumes/") else {
            let name = path.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? ""
            // "/Volumes/Macintosh HD" is a link to "/": the startup disk.
            var st = stat()
            if lstat("/Volumes/" + name, &st) == 0 { return nil }
            // Only /Volumes itself is left, on the startup disk: the drive is gone.
            return DriveFacts(mountPath: "/Volumes/" + name, name: name, isConnected: false)
        }
        let fm = FileManager.default
        let roles = Volumes.roles(bsdName: Volumes.fsString(fs.f_mntfromname))
        let isLocal = fs.f_flags & UInt32(MNT_LOCAL) != 0
        return DriveFacts(
            mountPath: mount,
            name: (try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeNameKey]).volumeName)
                ?? (mount as NSString).lastPathComponent,
            isReadOnly: fs.f_flags & UInt32(MNT_RDONLY) != 0,
            isLocal: isLocal,
            isTimeMachine: mount.hasPrefix("/Volumes/.timemachine") || roles.contains("Backup")
                || fm.fileExists(atPath: mount + "/Backups.backupdb"),
            holdsMacOS: roles.contains("System") || roles.contains("Data")
                || fm.fileExists(atPath: mount + "/System/Library/CoreServices/SystemVersion.plist")
                || ["Users", "Library", "private"].allSatisfy { fm.fileExists(atPath: mount + "/" + $0) })
    }

    /// Cheap check for where ⊕ buttons appear: somewhere inside a mounted
    /// drive under /Volumes, not the drive itself.
    static func isInsideMountedDrive(_ path: String) -> Bool {
        guard path.hasPrefix("/Volumes/"), !path.contains("/../"), let fs = statfsOfNearest(path) else { return false }
        let mount = Volumes.fsString(fs.f_mntonname)
        return mount.hasPrefix("/Volumes/") && path.hasPrefix(mount + "/")
    }

    /// statfs of the path, or of its nearest ancestor that exists.
    private static func statfsOfNearest(_ path: String) -> statfs? {
        var current = path
        var fs = statfs()
        while current.count > 1 {
            if statfs(current, &fs) == 0 { return fs }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}

extension Drives {
    /// Your Trash folder on each mounted, writable drive under /Volumes
    /// ("/Volumes/Drive/.Trashes/501"), where Move to Trash puts items
    /// from that drive.
    static func trashes() -> [String] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return urls.map(\.path).filter { $0.hasPrefix("/Volumes/") }.compactMap { mount in
            var fs = statfs()
            guard statfs(mount, &fs) == 0, fs.f_flags & UInt32(MNT_RDONLY) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0 else { return nil }
            let trash = mount + "/.Trashes/\(getuid())"
            return FileManager.default.fileExists(atPath: trash) ? trash : nil
        }
    }
}

/// A volume in the Disks list: connected, indexed, or both.
struct Disk: Identifiable, Hashable, Sendable {
    let uuid: String
    /// Set while it's connected.
    let mounted: MountedVolume?
    /// Set once it has an index.
    let known: Volumes.Known?

    var id: String { uuid }
    var name: String { mounted?.name ?? known?.name ?? "Drive" }
    var format: String { mounted?.format ?? known?.format ?? "" }
    /// Where it's mounted, or was when last seen.
    var path: String { mounted?.path ?? known?.lastPath ?? "" }
    var isConnected: Bool { mounted != nil }
    var isScanned: Bool { known != nil }
    var isRemovable: Bool { mounted?.isRemovable ?? known?.isRemovable ?? true }
    /// Ballast can follow its changes instead of rescanning.
    var isJournaled: Bool { mounted?.isJournaled ?? known?.isJournaled ?? false }
    var isReadOnly: Bool { mounted?.isReadOnly ?? false }
    var scannedAt: Date? { known?.scannedAt }
    var total: Int64 { mounted?.total ?? known?.total ?? 0 }

    /// Connected volumes first by name, then unplugged ones with an index.
    static func list(mounted: [MountedVolume], known: [Volumes.Known]) -> [Disk] {
        let byID = Dictionary(known.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        let connected = mounted.map { Disk(uuid: $0.uuid, mounted: $0, known: byID[$0.uuid]) }
        let ids = Set(mounted.map(\.uuid))
        let unplugged = known.filter { !ids.contains($0.uuid) }.map { Disk(uuid: $0.uuid, mounted: nil, known: $0) }
        return connected + unplugged
    }
}
