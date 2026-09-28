import CoreServices
import Darwin
import Foundation
import Security

/// Where apps and their data live. Tests point this at a temporary folder.
struct AppLocations: Sendable {
    /// Folders holding apps, searched one level of subfolders deep.
    var roots: [String]
    /// The Library folder app data is looked up in.
    var library: String

    static let standard = AppLocations(
        roots: ["/Applications", NSHomeDirectory() + "/Applications"],
        library: NSHomeDirectory() + "/Library"
    )
}

/// An app bundle, as read from disk.
struct AppBundle: Sendable, Hashable {
    let path: String
    /// File name without ".app", the name Finder shows.
    let name: String
    let bundleID: String
    /// App groups it declares in its signature, for matching group containers.
    let groups: [String]

    static func read(_ path: String, entitlements: Bool = true) -> AppBundle? {
        guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
              let id = info["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        let name = String((path as NSString).lastPathComponent.dropLast(4))
        return AppBundle(path: path, name: name, bundleID: id, groups: entitlements ? appGroups(path) : [])
    }

    /// `com.apple.security.application-groups` from the code signature.
    private static func appGroups(_ path: String) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any],
              let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    /// Bought from the Mac App Store, so it can be downloaded again there.
    var fromAppStore: Bool {
        FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt")
    }

    /// Helpers, login items or system extensions that outlive the app in
    /// the Trash; its own uninstaller knows how to remove them.
    var installsSystemComponents: Bool {
        let fm = FileManager.default
        return ["SystemExtensions", "LaunchServices", "LoginItems"].contains { folder in
            !((try? fm.contentsOfDirectory(atPath: path + "/Contents/Library/" + folder)) ?? []).isEmpty
        }
    }

    /// Why Ballast can't move it to the Trash, if it can't.
    enum Lock: Sendable {
        /// Root-owned, as .pkg installers and the App Store leave apps.
        case admin
        /// macOS App Management: only apps allowed in Privacy & Security
        /// may change apps signed by someone else.
        case appManagement
    }

    /// Moving a folder to the Trash takes write access to where it is and
    /// to the folder itself.
    var lock: Lock? {
        guard FileManager.default.isDeletableFile(atPath: path) else { return .admin }
        guard access(path, W_OK) != 0 else { return nil }
        return errno == EPERM ? .appManagement : .admin
    }
}

/// The data an app keeps in ~/Library, found by exact identity only: its
/// bundle id, its name, or the id a container records about itself. A
/// guess isn't good enough when the cost is someone's data.
enum AppData {
    /// Paths of `app`'s data that exist right now. `others` are the other
    /// installed apps: anything one of them could also be using is left
    /// out. Container metadata is read only with Full Disk Access; without
    /// it macOS asks the user about every app's container.
    static func folders(
        for app: AppBundle, others: [AppBundle], locations: AppLocations = .standard,
        readContainerMetadata: Bool
    ) -> [String] {
        let id = app.bundleID
        // Another copy of the same app still uses all of it; Apple's apps
        // share theirs with macOS.
        guard !id.isEmpty, !SafetyCheck.isSystemOwned(id),
              !others.contains(where: { $0.bundleID == id && $0.path != app.path }) else { return [] }
        let fm = FileManager.default
        let library = locations.library
        func exists(_ path: String) -> Bool {
            var st = stat()
            return lstat(path, &st) == 0
        }

        var found: [String] = []
        let containers = library + "/Containers"
        if exists(containers + "/" + id) {
            found.append(containers + "/" + id)
        }
        if readContainerMetadata {
            // Newer containers are named by UUID; their metadata names the app.
            for name in (try? fm.contentsOfDirectory(atPath: containers)) ?? [] where UUID(uuidString: name) != nil {
                if containerIdentifier(containers + "/" + name) == id { found.append(containers + "/" + name) }
            }
            // A group container is the app's only if it declares that group
            // and no other installed app does (Office apps share one).
            let groups = Set(app.groups)
            let shared = Set(others.filter { $0.path != app.path }.flatMap(\.groups))
            if !groups.isEmpty {
                let root = library + "/Group Containers"
                for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                    guard let group = containerIdentifier(root + "/" + name),
                          groups.contains(group), !shared.contains(group) else { continue }
                    found.append(root + "/" + name)
                }
            }
        }

        // Application Support by bundle id or the app's exact name, unless
        // that name is also another app's or belongs to macOS.
        for key in [id, app.name] where !key.isEmpty && !SafetyCheck.isSystemOwned(key) {
            let taken = others.contains { $0.path != app.path && ($0.name == key || $0.bundleID == key) }
            let path = library + "/Application Support/" + key
            if !taken, exists(path), !found.contains(path) { found.append(path) }
        }

        for path in [
            library + "/Caches/" + id,
            library + "/Preferences/" + id + ".plist",
            library + "/Saved Application State/" + id + ".savedState",
            library + "/HTTPStorages/" + id,
            library + "/WebKit/" + id,
        ] where exists(path) {
            found.append(path)
        }
        return found
    }

    /// What a container says it belongs to: `MCMMetadataIdentifier` in the
    /// metadata file macOS writes into every container.
    static func containerIdentifier(_ container: String) -> String? {
        let plist = NSDictionary(contentsOfFile: container + "/.com.apple.containermanagerd.metadata.plist")
        return plist?["MCMMetadataIdentifier"] as? String
    }
}

/// An app nobody has opened in a while, with everything uninstalling it
/// would move to the Trash.
struct UnusedApp: Identifiable, Sendable {
    let app: AppBundle
    /// When Spotlight saw it opened last; nil when macOS has no record.
    let lastUsed: Date?
    /// Its data in ~/Library, see `AppData`.
    let data: [String]
    let fromAppStore: Bool
    let lock: AppBundle.Lock?
    let installsSystemComponents: Bool
    var appBytes: Int64 = 0
    var dataBytes: Int64 = 0

    var id: String { app.path }
    var bytes: Int64 { appBytes + dataBytes }
    var action: CleanAction { .uninstall(bundleID: app.bundleID, data: data) }
}

enum AppScanner {
    /// Every app bundle in `roots` and their subfolders (Utilities, vendor
    /// folders), except aliases: /Applications/Safari.app is a link into
    /// the sealed system volume.
    static func bundles(in roots: [String] = AppLocations.standard.roots, entitlements: Bool = true) -> [AppBundle] {
        let fm = FileManager.default
        var found: [AppBundle] = []
        func isFolder(_ path: String) -> Bool {
            var st = stat()
            return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
        }
        func add(_ dir: String, depth: Int) {
            for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where !name.hasPrefix(".") {
                let path = dir + "/" + name
                guard isFolder(path) else { continue }
                if name.hasSuffix(".app") {
                    if let app = AppBundle.read(path, entitlements: entitlements) { found.append(app) }
                } else if depth > 0 {
                    add(path, depth: depth - 1)
                }
            }
        }
        for root in roots { add(root, depth: 1) }
        return found
    }

    /// Apps the user installed and can remove: on the data volume (not the
    /// sealed system), not part of macOS, and not Ballast.
    static func isRemovable(_ app: AppBundle, device: dev_t = Volume.device) -> Bool {
        var st = stat()
        guard lstat(app.path, &st) == 0, st.st_dev == device else { return false }
        if [Bundle.main.bundleIdentifier, "dev.mamad.Ballast"].contains(app.bundleID) { return false }
        // Apple's App Store apps (Keynote, Xcode) are yours to remove.
        return !app.bundleID.hasPrefix("com.apple.") || app.fromAppStore
    }

    /// Unused: Spotlight's last-opened date is older than the cutoff. With
    /// no record, only an app installed before the cutoff that nothing has
    /// read since counts; the read date is a filter, never shown as "opened".
    static func isUnused(lastUsed: Date?, accessed: Date?, installed: Date?, months: Int, now: Date = .now) -> Bool {
        let cutoff = now.addingTimeInterval(-Double(months) * 30.44 * 86_400)
        if let lastUsed = recorded(lastUsed) { return lastUsed < cutoff }
        guard let installed, installed < cutoff else { return false }
        return (accessed ?? .distantPast) < cutoff
    }

    /// Spotlight sometimes reports a zip archive's placeholder date (1980)
    /// as the last use; nothing ran on this Mac before 2001.
    static func recorded(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSinceReferenceDate > 0 else { return nil }
        return date
    }

    /// Removable apps not opened in `months`, with their data. Sizes are
    /// filled in by the caller from the index.
    static func unused(months: Int, readContainerMetadata: Bool, locations: AppLocations = .standard,
                       now: Date = .now) -> [UnusedApp] {
        let all = bundles(in: locations.roots)
        let device = Volume.device
        return all.compactMap { app in
            guard isRemovable(app, device: device) else { return nil }
            let url = URL(fileURLWithPath: app.path)
            let values = try? url.resourceValues(forKeys: [.contentAccessDateKey, .addedToDirectoryDateKey, .creationDateKey])
            let lastUsed = recorded(MDItemCreateWithURL(nil, url as CFURL)
                .flatMap { MDItemCopyAttribute($0, "kMDItemLastUsedDate" as CFString) as? Date })
            guard isUnused(lastUsed: lastUsed, accessed: values?.contentAccessDate,
                           installed: values?.addedToDirectoryDate ?? values?.creationDate,
                           months: months, now: now) else { return nil }
            return UnusedApp(
                app: app, lastUsed: lastUsed,
                data: AppData.folders(for: app, others: all, locations: locations, readContainerMetadata: readContainerMetadata),
                fromAppStore: app.fromAppStore, lock: app.lock,
                installsSystemComponents: app.installsSystemComponents
            )
        }
    }
}
