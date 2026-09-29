import AppKit
import BallastCore
import CoreServices
import Darwin
import Foundation
import os

enum Paths {
    /// The writable APFS data volume. /Users, /Applications, /Library and /opt
    /// are firmlinks into it, so walking it (not "/") counts everything once.
    static let volumeRoot = "/System/Volumes/Data"
    static let supportDir = NSHomeDirectory() + "/Library/Application Support/Ballast"
    static let index = supportDir + "/index.sqlite"
    /// Folder sizes over time; outside the index, which a full scan replaces.
    static let growth = supportDir + "/growth.sqlite"
    /// Where the background auto-clean run writes its log.
    static let logsDir = NSHomeDirectory() + "/Library/Logs/Ballast"
    /// Other volumes' indexes, one folder per volume UUID. The startup
    /// disk's index stays at `index`, where the CLI and widget read it.
    static let volumesDir = supportDir + "/volumes"

    /// "…/volumes/<UUID>", or nil when `uuid` isn't a UUID: it becomes a
    /// folder name, so nothing else may get through.
    static func volumeDir(_ uuid: String, in directory: String = volumesDir) -> String? {
        guard let canonical = UUID(uuidString: uuid)?.uuidString else { return nil }
        return directory + "/" + canonical
    }

    static func volumeIndex(_ uuid: String, in directory: String = volumesDir) -> String? {
        volumeDir(uuid, in: directory).map { $0 + "/index.sqlite" }
    }

    /// "/System/Volumes/Data/Users/x" → "/Users/x"
    static func display(_ path: String) -> String {
        if path == volumeRoot { return "/" }
        return path.hasPrefix(volumeRoot + "/") ? String(path.dropFirst(volumeRoot.count)) : path
    }

    /// "/Users/x" → "/System/Volumes/Data/Users/x"
    static func onVolume(_ path: String) -> String {
        if path == volumeRoot || path.hasPrefix(volumeRoot + "/") { return path }
        return path == "/" ? volumeRoot : volumeRoot + path
    }

    static var volumeName: String { DiskCapacity.volumeName }
}

enum Volume {
    static var device: dev_t {
        var st = stat()
        lstat(Paths.volumeRoot, &st)
        return st.st_dev
    }

    /// Changes when the volume's FSEvents history is reset; stored event IDs
    /// are only meaningful while this stays the same.
    static var eventsUUID: String? { eventsUUID(device) }

    /// The FSEvents store of any volume. ExFAT and FAT volumes get a new
    /// one each time they're mounted; APFS and Mac OS Extended keep theirs.
    static func eventsUUID(_ device: dev_t) -> String? {
        guard let uuid = FSEventsCopyUUIDForDevice(device) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Free space the way the Overview and Finder count it; the widget reads
    /// the same figure through the same code.
    static var capacity: (free: Int64, total: Int64)? { DiskCapacity.current }

    static var freeBytes: Int64 { capacity?.free ?? 0 }
}

enum Access {
    /// TCC.db is readable only by processes with Full Disk Access.
    static var hasFullDiskAccess: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    @MainActor
    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

final class CancelFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}
