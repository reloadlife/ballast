import Foundation

/// Per-user temporary storage lives outside home. Offer individual known
/// developer leftovers for review, never the shared temporary roots.
enum TemporarySuggestions {
    static var userRoot: String {
        Paths.canonical(FileManager.default.temporaryDirectory.deletingLastPathComponent().path)
    }

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

    static func results(_ db: IndexDB, root: String = userRoot) -> [ScanResult] {
        guard root.hasPrefix("/private/var/folders/") else { return [] }
        return ["T", "C", "X"].flatMap { area -> [ScanResult] in
            let path = Paths.onVolume(root + "/" + area)
            guard let parent = try? db.locate(path).last, parent.path == path,
                  let children = try? db.children(of: parent.row.id) else { return [] }
            return children.compactMap { row in
                guard row.total >= 10 << 20, row.err == 0, let label = label(name: row.name, area: area) else { return nil }
                return ScanResult(target: Target(name: "\(label): \(row.name)", path: root + "/" + area + "/" + row.name,
                                                 category: .developer, action: .remove), bytes: row.total, newest: row.newest)
            }
        }
    }
}
