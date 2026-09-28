import Foundation

/// A downloaded installer or disk image.
struct Installer: Identifiable, Sendable {
    let path: String
    let bytes: Int64
    /// Old-style .pkg and .mpkg installers are folders.
    let isDirectory: Bool
    /// When it landed in its folder (downloaded, usually).
    let added: Date?
    /// An installed app the file is named after ("Firefox 130.0.dmg").
    let installedApp: String?
    /// For a disk image that's mounted: the device to eject ("/dev/disk6").
    let mountedAs: String?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Installers and disk images in the folders downloads end up in. The index
/// stores folders only, so these few folders are listed when needed.
enum Installers {
    static let extensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]
    static let minimumBytes: Int64 = 10 << 20

    static var folders: [String] {
        ["Downloads", "Desktop", "Documents"].map { NSHomeDirectory() + "/" + $0 }
    }

    /// Whether a file of this name and size counts. A .zip counts only with
    /// an app at its top level: "Setup.zip" alone is too fuzzy to call.
    static func qualifies(_ path: String, bytes: Int64) -> Bool {
        guard bytes >= minimumBytes else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        return ext == "zip" && zipHasApp(path)
    }

    /// Reads a zip's central directory for an entry inside a top-level
    /// "Something.app/". Zip64 archives aren't read, so they don't count.
    static func zipHasApp(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 22 else { return false }
        // The end record sits in the last 22 bytes plus a comment of up to 64 KB.
        let tailLength = min(size, 22 + 0xFFFF)
        guard (try? handle.seek(toOffset: size - tailLength)) != nil,
              let tail = try? handle.read(upToCount: Int(tailLength)).map([UInt8].init) else { return false }
        func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ b: [UInt8], _ o: Int) -> Int { u16(b, o) | u16(b, o + 2) << 16 }

        var end = tail.count - 22
        while end >= 0, u32(tail, end) != 0x0605_4B50 { end -= 1 }
        guard end >= 0 else { return false }
        let count = u16(tail, end + 10)
        let directorySize = u32(tail, end + 12)
        let directoryOffset = u32(tail, end + 16)
        guard count != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF,
              directoryOffset + directorySize <= Int(size), directorySize < 64 << 20,
              (try? handle.seek(toOffset: UInt64(directoryOffset))) != nil,
              let directory = try? handle.read(upToCount: directorySize).map([UInt8].init) else { return false }

        var offset = 0
        for _ in 0..<count {
            guard offset + 46 <= directory.count, u32(directory, offset) == 0x0201_4B50 else { return false }
            let nameLength = u16(directory, offset + 28)
            let extra = u16(directory, offset + 30)
            let comment = u16(directory, offset + 32)
            guard offset + 46 + nameLength <= directory.count else { return false }
            let name = String(decoding: directory[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            if let slash = name.firstIndex(of: "/") {
                let top = name[..<slash]
                if top.lowercased().hasSuffix(".app") && top != "__MACOSX" { return true }
            }
            offset += 46 + nameLength + extra + comment
        }
        return false
    }

    /// The installed app a file is named after, if its name starts with
    /// one: "Firefox 130.0.dmg" names Firefox, "Slacker.dmg" doesn't name
    /// Slack. Longest name wins.
    static func installedApp(named fileName: String, among apps: [String]) -> String? {
        let file = fileName.lowercased()
        return apps
            .filter { name in
                guard name.count >= 3, file.hasPrefix(name.lowercased()) else { return false }
                let next = file.dropFirst(name.count).first
                return next.map { !$0.isLetter && !$0.isNumber } ?? true
            }
            .max { $0.count < $1.count }
    }

    /// Mounted disk images: image path → the device to eject.
    static func mounted() -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [:] }
        var mounted: [String: String] = [:]
        for image in images {
            guard let path = image["image-path"] as? String,
                  let entities = image["system-entities"] as? [[String: Any]],
                  let device = entities.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count }) else { continue }
            mounted[URL(fileURLWithPath: path).resolvingSymlinksInPath().path] = device
        }
        return mounted
    }

    static func isMounted(_ path: String) -> Bool {
        mounted()[URL(fileURLWithPath: path).resolvingSymlinksInPath().path] != nil
    }

    /// Ejects a mounted disk image, like Finder's Eject.
    static func eject(_ device: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", device]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Cleaner.Failure(message: message.isEmpty ? "Couldn't eject \(device)." : message)
        }
    }

    /// Installers in `folders` and their direct subfolders, biggest first.
    /// `apps` are installed app names, for the "is installed" note.
    static func scan(folders: [String] = folders, apps: [String]) -> [Installer] {
        let fm = FileManager.default
        let mounted = mounted()
        var found: [Installer] = []
        func visit(_ dir: String, depth: Int) {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !name.hasPrefix(".") {
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let isFolder = st.st_mode & S_IFMT == S_IFDIR
                let ext = (name as NSString).pathExtension.lowercased()
                if isFolder && !extensions.contains(ext) {
                    // Packages (apps, libraries) aren't folders to look through.
                    let isPackage = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? true
                    if depth > 0 && !isPackage { visit(path, depth: depth - 1) }
                    continue
                }
                guard isFolder || st.st_mode & S_IFMT == S_IFREG else { continue }
                let bytes = isFolder ? Cleaner.measure(path).bytes : Int64(st.st_blocks) * 512
                guard qualifies(path, bytes: bytes) else { continue }
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
                found.append(Installer(
                    path: path, bytes: bytes, isDirectory: isFolder,
                    added: values?.addedToDirectoryDate ?? values?.creationDate,
                    installedApp: installedApp(named: name, among: apps),
                    mountedAs: mounted[URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
                ))
            }
        }
        for folder in folders { visit(folder, depth: 1) }
        return found.sorted { $0.bytes > $1.bytes }
    }
}
