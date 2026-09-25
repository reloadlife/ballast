import AppKit
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

    static let volumeName: String =
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
}

enum Volume {
    static var device: dev_t {
        var st = stat()
        lstat(Paths.volumeRoot, &st)
        return st.st_dev
    }

    /// Changes when the volume's FSEvents history is reset; stored event IDs
    /// are only meaningful while this stays the same.
    static var eventsUUID: String? {
        guard let uuid = FSEventsCopyUUIDForDevice(device) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
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
