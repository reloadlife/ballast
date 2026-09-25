import Foundation

/// The parts of "System Data" a folder walk can't see: the other APFS
/// volumes in the boot container, snapshots, and purgeable space. All of it
/// comes from `diskutil` and `tmutil`, which need no admin rights.
struct SystemVolumes: Sendable {
    struct Volume: Sendable {
        let name: String
        let role: String
        let bytes: Int64
    }

    /// Every volume in the boot container except the data volume.
    var volumes: [Volume] = []
    /// Space the data volume uses, as APFS counts it.
    var dataVolumeBytes: Int64?
    /// Local snapshot names, e.g. "com.apple.os.update-…".
    var snapshots: [String] = []
    /// Space macOS can free on its own (already counted as available).
    var purgeable: Int64 = 0

    static func read() -> SystemVolumes {
        var result = SystemVolumes()
        if let data = run("/usr/sbin/diskutil", ["apfs", "list", "-plist"]),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let containers = plist["Containers"] as? [[String: Any]] {
            // The boot container is the one holding the Data volume.
            let boot = containers.first { container in
                (container["Volumes"] as? [[String: Any]] ?? []).contains { roles(of: $0).contains("Data") }
            }
            for volume in boot?["Volumes"] as? [[String: Any]] ?? [] {
                let bytes = (volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
                let role = roles(of: volume).first ?? ""
                if role == "Data" {
                    result.dataVolumeBytes = bytes
                } else if bytes > 0 {
                    result.volumes.append(Volume(name: volume["Name"] as? String ?? role, role: role, bytes: bytes))
                }
            }
        }

        if let data = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]) {
            result.snapshots = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("com.apple.") }
        }

        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
           let important = values.volumeAvailableCapacityForImportantUsage,
           let available = values.volumeAvailableCapacity {
            result.purgeable = max(important - Int64(available), 0)
        }
        return result
    }

    private static func roles(of volume: [String: Any]) -> [String] {
        volume["Roles"] as? [String] ?? []
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

/// One line of the System Data breakdown.
struct SystemDataItem: Identifiable, Sendable {
    enum Action: Sendable, Equatable {
        case none
        /// Open this display path in Explorer.
        case explore(String)
        /// Measure locked folders with an administrator scan.
        case adminScan
    }

    let name: String
    let detail: String
    let bytes: Int64
    let action: Action
    var id: String { name }
}

struct SystemDataReport: Sendable {
    /// Found by walking the data volume.
    let onDisk: [SystemDataItem]
    /// Separate APFS volumes macOS keeps next to your data.
    let hidden: [SystemDataItem]
    let snapshots: [String]
    let purgeable: Int64

    /// Same figure as the Overview's System Data segment.
    let total: Int64
}

enum SystemDataCatalog {
    /// Folders on the data volume that make up System Data, with what they are.
    static let areas: [(path: String, name: String, detail: String)] = [
        ("/private/var/folders", "Temporary files & system caches",
         "Per-user temporary files and caches kept by macOS and apps. Mostly cleared by a restart."),
        ("/System", "Downloaded macOS assets",
         "Voices, fonts, language and machine-learning models macOS downloads on demand. It removes them when space runs low."),
        ("/Library", "Shared app data",
         "Data for every user on this Mac: simulators, audio libraries, printer drivers, shared frameworks."),
        ("/private/var/db", "System databases & diagnostics",
         "Indexes, logs and diagnostic data macOS maintains. Managed by macOS."),
        ("/private/var/log", "System logs", "Log files macOS rotates and trims on its own."),
        ("/opt", "Homebrew & /opt", "Software installed with Homebrew or into /opt. Clean it with brew cleanup."),
        ("/usr", "/usr/local", "Command-line tools installed outside Homebrew."),
    ]

    static func volume(_ volume: SystemVolumes.Volume) -> SystemDataItem {
        let (name, detail): (String, String) = switch volume.role {
        case "System": ("macOS", "The sealed, read-only system itself. Nothing here can or should be removed.")
        case "Preboot": ("Boot & update files", "What your Mac needs to start up, plus parts of installed macOS updates. Shrinks after updates settle; not cleanable by hand.")
        case "VM": ("Swap & sleep image", "Memory swapped to disk and the hibernation image. Shrinks after a restart.")
        case "Recovery": ("macOS Recovery", "The recovery system. Needed; can't be removed.")
        case "Update": ("Staged updates", "macOS updates waiting to install. Cleared once they install.")
        default: (volume.name, "A macOS volume in the same container as your data.")
        }
        return SystemDataItem(name: name, detail: detail, bytes: volume.bytes, action: .none)
    }
}
