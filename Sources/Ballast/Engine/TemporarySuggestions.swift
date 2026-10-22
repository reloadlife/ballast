import Darwin
import Foundation

/// Per-user temporary storage lives outside home. Offer individual known
/// developer leftovers for review, never the shared temporary roots.
enum TemporarySuggestions {
    static var userRoot: String {
        Paths.canonical(FileManager.default.temporaryDirectory.deletingLastPathComponent().path)
    }

    /// The shared /tmp. Scripts, CLIs and agents unpack, build and deploy here.
    static let sharedRoot = "/private/tmp"

    /// Anything this big in a temporary folder is worth a look, known or not.
    static let largeItem: Int64 = 500 << 20

    static func label(name: String, area: String) -> String? {
        switch area {
        case "T":
            if name.hasPrefix("go-build"), !name.dropFirst(8).isEmpty,
               name.dropFirst(8).allSatisfy(\.isNumber) { return "Go temporary build" }
            if name.hasPrefix("bunx-") { return "Bun temporary package" }
            if name == "node-compile-cache" { return "Node compilation cache" }
            if name.contains("-deploy-") { return "Temporary deployment working copy" }
        case "C":
            if name == "clang" || name == "org.llvm.clang" { return "Clang compilation cache" }
        case "X":
            if name.hasSuffix(".code_sign_clone") { return "App runtime clones (managed by the app)" }
        default: break
        }
        return nil
    }

    static func results(_ db: IndexDB, root: String = userRoot, shared: String = sharedRoot, large: Int64 = largeItem) -> [ScanResult] {
        func children(_ display: String) -> [DirRow] {
            let path = Paths.onVolume(display)
            guard let parent = try? db.locate(path).last, parent.path == path else { return [] }
            return (try? db.children(of: parent.row.id)) ?? []
        }
        func result(_ name: String, _ path: String, _ row: DirRow) -> ScanResult {
            ScanResult(target: Target(name: name, path: path, category: .developer, action: .remove),
                       bytes: row.total, newest: row.newest)
        }

        var found: [ScanResult] = []
        if root.hasPrefix("/private/var/folders/") {
            for area in ["T", "C", "X"] {
                for row in children(root + "/" + area) where row.total >= 10 << 20 && row.err == 0 {
                    let path = root + "/" + area + "/" + row.name
                    if let label = label(name: row.name, area: area) {
                        found.append(result("\(label): \(row.name)", path, row))
                    } else if area == "T", row.total >= large, isOwnedByUser(path) {
                        found.append(result("Large temporary item: \(row.name)", path, row))
                    }
                }
            }
        }
        // Only folders you created: /tmp is shared with every account and
        // system service, and the root itself is never offered.
        for row in children(shared) where row.total >= large && row.err == 0 {
            let path = shared + "/" + row.name
            if isOwnedByUser(path) { found.append(result("Temporary folder: \(row.name)", path, row)) }
        }
        return found
    }

    static func isOwnedByUser(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_uid == getuid()
    }
}
