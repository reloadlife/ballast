import Foundation

/// A kind of regenerable build output. Each kind is recognized by its folder
/// name *and* a marker file beside or inside it, never by name alone:
/// `target` is only a Rust target next to a Cargo.toml.
enum ArtifactKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case nodeModules, next, nuxt, svelteKit, angular, turbo, parcel
    case rustTarget, mavenTarget, gradleBuild, gradleCache
    case pythonVenv, pythonCache
    case pods, dartTool, zigCache, terraform

    var id: String { rawValue }

    /// Folder names this kind can have; used to query the index.
    var folderNames: [String] {
        switch self {
        case .nodeModules: ["node_modules"]
        case .next: [".next"]
        case .nuxt: [".nuxt"]
        case .svelteKit: [".svelte-kit"]
        case .angular: [".angular"]
        case .turbo: [".turbo"]
        case .parcel: [".parcel-cache"]
        case .rustTarget, .mavenTarget: ["target"]
        case .gradleBuild: ["build"]
        case .gradleCache: [".gradle"]
        case .pythonVenv: [".venv", "venv"]
        case .pythonCache: ["__pycache__"]
        case .pods: ["Pods"]
        case .dartTool: [".dart_tool"]
        case .zigCache: [".zig-cache", "zig-cache"]
        case .terraform: [".terraform"]
        }
    }

    var title: String {
        switch self {
        case .nodeModules: "Node modules"
        case .next: "Next.js builds"
        case .nuxt: "Nuxt builds"
        case .svelteKit: "SvelteKit builds"
        case .angular: "Angular caches"
        case .turbo: "Turborepo caches"
        case .parcel: "Parcel caches"
        case .rustTarget: "Rust targets"
        case .mavenTarget: "Maven targets"
        case .gradleBuild: "Gradle builds"
        case .gradleCache: "Gradle project caches"
        case .pythonVenv: "Python virtualenvs"
        case .pythonCache: "Python bytecode"
        case .pods: "CocoaPods"
        case .dartTool: "Dart & Flutter tools"
        case .zigCache: "Zig caches"
        case .terraform: "Terraform providers"
        }
    }

    /// How the folder comes back after it's gone.
    var rebuild: String {
        switch self {
        case .nodeModules: "npm / pnpm / bun install"
        case .next, .nuxt, .svelteKit, .angular, .turbo, .parcel: "the next dev or build"
        case .rustTarget: "cargo build"
        case .mavenTarget: "mvn package"
        case .gradleBuild, .gradleCache: "the next Gradle build"
        case .pythonVenv: "recreating the venv and reinstalling"
        case .pythonCache: "running the code again"
        case .pods: "pod install"
        case .dartTool: "flutter pub get"
        case .zigCache: "zig build"
        case .terraform: "terraform init"
        }
    }

    var symbol: String {
        switch self {
        case .nodeModules, .next, .nuxt, .svelteKit, .angular, .turbo, .parcel: "shippingbox"
        case .rustTarget: "gearshape.2"
        case .mavenTarget, .gradleBuild, .gradleCache: "cup.and.saucer"
        case .pythonVenv, .pythonCache: "chevron.left.forwardslash.chevron.right"
        case .pods: "apple.logo"
        case .dartTool: "bird"
        case .zigCache: "bolt"
        case .terraform: "cloud"
        }
    }

    static let allFolderNames: Set<String> = Set(allCases.flatMap(\.folderNames))

    /// The kind of `dir`, if it is confirmed build output.
    static func detect(_ dir: URL) -> ArtifactKind? {
        let name = dir.lastPathComponent
        guard allFolderNames.contains(name) else { return nil }
        let parent = dir.deletingLastPathComponent()
        let fm = FileManager.default
        func beside(_ files: String...) -> Bool {
            files.contains { fm.fileExists(atPath: parent.appending(path: $0).path) }
        }
        func besideSuffix(_ suffix: String) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).contains { $0.hasSuffix(suffix) }
        }

        switch name {
        case "node_modules": return beside("package.json") ? .nodeModules : nil
        case ".next": return beside("package.json", "next.config.js", "next.config.mjs", "next.config.ts") ? .next : nil
        case ".nuxt": return beside("package.json", "nuxt.config.ts", "nuxt.config.js") ? .nuxt : nil
        case ".svelte-kit": return beside("package.json", "svelte.config.js") ? .svelteKit : nil
        case ".angular": return beside("angular.json") ? .angular : nil
        case ".turbo": return beside("package.json", "turbo.json") ? .turbo : nil
        case ".parcel-cache": return beside("package.json") ? .parcel : nil
        case "target":
            if beside("Cargo.toml") { return .rustTarget }
            return beside("pom.xml") ? .mavenTarget : nil
        case "build": return beside("build.gradle", "build.gradle.kts") ? .gradleBuild : nil
        case ".gradle": return beside("settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts") ? .gradleCache : nil
        case ".venv", "venv": return fm.fileExists(atPath: dir.appending(path: "pyvenv.cfg").path) ? .pythonVenv : nil
        case "__pycache__": return .pythonCache
        case "Pods": return beside("Podfile") ? .pods : nil
        case ".dart_tool": return beside("pubspec.yaml") ? .dartTool : nil
        case ".zig-cache", "zig-cache": return beside("build.zig") ? .zigCache : nil
        case ".terraform": return besideSuffix(".tf") ? .terraform : nil
        default: return nil
        }
    }
}

/// One build folder on disk, as the index knows it.
struct Artifact: Identifiable, Sendable, Hashable {
    let path: String
    let kind: ArtifactKind
    let bytes: Int64
    /// Newest change anywhere in the project folder that holds it: the
    /// signal for "is this project still being worked on".
    let projectNewest: Int64
    var id: String { path }

    /// The project, for display: "~/projects/app".
    var project: String {
        (path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// Finds every confirmed build folder in the index.
enum ArtifactScanner {
    static func scan(_ db: IndexDB) -> [Artifact] {
        guard let rows = try? db.rows(named: Array(ArtifactKind.allFolderNames)) else { return [] }

        // Paths share ancestors, so memoize the walk up the tree.
        var paths: [Int64: String] = [:]
        var parents: [Int64: DirRow] = [:]
        func path(_ id: Int64) -> String? {
            if let known = paths[id] { return known }
            guard let row = parents[id] ?? (try? db.row(id)) else { return nil }
            parents[id] = row
            let full = row.parent.map { path($0).map { $0 + "/" + row.name } } ?? row.name
            paths[id] = full
            return full
        }

        var found: [Artifact] = []
        for row in rows where row.total > 0 && row.err == 0 {
            guard let full = path(row.id) else { continue }
            let display = Paths.display(full)
            guard let kind = ArtifactKind.detect(URL(fileURLWithPath: display)) else { continue }
            let project = row.parent.flatMap { parents[$0] ?? (try? db.row($0)) }
            found.append(Artifact(path: display, kind: kind, bytes: row.total,
                                  projectNewest: project?.newest ?? row.newest))
        }

        // Outermost only: node_modules inside node_modules, or __pycache__
        // inside a venv, is already counted by the outer folder.
        var kept: [Artifact] = []
        var keptPaths = Set<String>()
        for artifact in found.sorted(by: { $0.path < $1.path }) {
            var ancestor = (artifact.path as NSString).deletingLastPathComponent
            var nested = false
            while ancestor.count > 1 {
                if keptPaths.contains(ancestor) { nested = true; break }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            if !nested {
                kept.append(artifact)
                keptPaths.insert(artifact.path)
            }
        }
        return kept.sorted { $0.bytes > $1.bytes }
    }
}
