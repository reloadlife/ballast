import Foundation

/// A kind of regenerable build output. Each kind is recognized by its folder
/// name *and* a marker file that proves it, never by name alone: `target` is
/// only a Rust target next to a Cargo.toml. The marker sits beside the
/// folder, inside it (a venv's pyvenv.cfg, a cache's CACHEDIR.TAG), or, for
/// folders that live inside another one (Carthage/Build), in the project
/// two levels up.
enum ArtifactKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case nodeModules, next, nuxt, svelteKit, angular, turbo, parcel
    case nx, astro, docusaurus, expo, vercelOutput, wrangler, coverage
    case rustTarget, mavenTarget, gradleBuild, gradleCache, androidCxx
    case pythonVenv, pythonCache, pythonToolCache, tox
    case swiftBuild, pods, carthageBuild, dartTool, zigCache, terraform
    case dotnet, elixir, haskell

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
        case .nx: [".nx"]
        case .astro: [".astro"]
        case .docusaurus: [".docusaurus"]
        case .expo: [".expo"]
        case .vercelOutput: ["output"]
        case .wrangler: ["tmp"]
        case .coverage: ["coverage"]
        case .rustTarget, .mavenTarget: ["target"]
        case .gradleBuild: ["build"]
        case .gradleCache: [".gradle"]
        case .androidCxx: [".cxx"]
        case .pythonVenv: [".venv", "venv"]
        case .pythonCache: ["__pycache__"]
        case .pythonToolCache: [".pytest_cache", ".mypy_cache", ".ruff_cache"]
        case .tox: [".tox"]
        case .swiftBuild: [".build"]
        case .pods: ["Pods"]
        case .carthageBuild: ["Build"]
        case .dartTool: [".dart_tool"]
        case .zigCache: [".zig-cache", "zig-cache"]
        case .terraform: [".terraform"]
        case .dotnet: ["bin", "obj"]
        case .elixir: ["_build", "deps"]
        case .haskell: [".stack-work", "dist-newstyle"]
        }
    }

    /// The folder this kind lives in, for kinds one level down inside a
    /// project (Carthage/Build). Only the inner folder is build output:
    /// .wrangler/state holds local databases, .vercel/project.json the link
    /// to the project.
    var container: String? {
        switch self {
        case .carthageBuild: "Carthage"
        case .vercelOutput: ".vercel"
        case .wrangler: ".wrangler"
        default: nil
        }
    }

    /// Folder names as they appear in the project: "Carthage/Build".
    var displayNames: [String] {
        folderNames.map { name in container.map { "\($0)/\(name)" } ?? name }
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
        case .nx: "Nx caches"
        case .astro: "Astro generated files"
        case .docusaurus: "Docusaurus builds"
        case .expo: "Expo caches"
        case .vercelOutput: "Vercel build output"
        case .wrangler: "Wrangler bundles"
        case .coverage: "Test coverage reports"
        case .rustTarget: "Rust targets"
        case .mavenTarget: "Maven targets"
        case .gradleBuild: "Gradle builds"
        case .gradleCache: "Gradle project caches"
        case .androidCxx: "Android native builds"
        case .pythonVenv: "Python virtualenvs"
        case .pythonCache: "Python bytecode"
        case .pythonToolCache: "pytest, mypy & Ruff caches"
        case .tox: "tox environments"
        case .swiftBuild: "Swift package builds"
        case .pods: "CocoaPods"
        case .carthageBuild: "Carthage builds"
        case .dartTool: "Dart & Flutter tools"
        case .zigCache: "Zig caches"
        case .terraform: "Terraform providers"
        case .dotnet: ".NET builds"
        case .elixir: "Elixir builds & deps"
        case .haskell: "Haskell builds"
        }
    }

    /// How the folder comes back after it's gone.
    var rebuild: String {
        switch self {
        case .nodeModules: "npm / pnpm / bun install"
        case .next, .nuxt, .svelteKit, .angular, .turbo, .parcel, .astro, .docusaurus: "the next dev or build"
        case .nx: "the next Nx task"
        case .expo: "the next expo start"
        case .vercelOutput: "vercel build"
        case .wrangler: "the next wrangler dev or deploy"
        case .coverage: "the next test run with coverage"
        case .rustTarget: "cargo build"
        case .mavenTarget: "mvn package"
        case .gradleBuild, .gradleCache, .androidCxx: "the next Gradle build"
        case .pythonVenv: "recreating the venv and reinstalling"
        case .pythonCache: "running the code again"
        case .pythonToolCache: "the next test, type check or lint"
        case .tox: "the next tox run"
        case .swiftBuild: "swift build"
        case .pods: "pod install"
        case .carthageBuild: "carthage build"
        case .dartTool: "flutter pub get"
        case .zigCache: "zig build"
        case .terraform: "terraform init"
        case .dotnet: "dotnet build"
        case .elixir: "mix deps.get and mix compile"
        case .haskell: "stack build or cabal build"
        }
    }

    var symbol: String {
        switch self {
        case .nodeModules, .next, .nuxt, .svelteKit, .angular, .turbo, .parcel,
             .nx, .astro, .docusaurus, .expo, .vercelOutput: "shippingbox"
        case .wrangler: "cloud"
        case .coverage: "checklist"
        case .rustTarget: "gearshape.2"
        case .mavenTarget, .gradleBuild, .gradleCache, .androidCxx: "cup.and.saucer"
        case .pythonVenv, .pythonCache, .pythonToolCache, .tox: "chevron.left.forwardslash.chevron.right"
        case .swiftBuild: "swift"
        case .pods, .carthageBuild: "apple.logo"
        case .dartTool: "bird"
        case .zigCache: "bolt"
        case .terraform: "cloud"
        case .dotnet, .elixir, .haskell: "curlybraces"
        }
    }

    /// How many folders up the project is: 2 for Carthage/Build.
    var depth: Int { container == nil ? 1 : 2 }

    static let allFolderNames: Set<String> = Set(allCases.flatMap(\.folderNames))

    /// Folder names to look up in the index. Kinds inside another folder
    /// are found through that folder: there are thousands of `tmp` folders,
    /// but only a few `.wrangler` ones.
    static let indexNames: Set<String> = Set(allCases.flatMap { $0.container.map { [$0] } ?? $0.folderNames })

    /// Inner folder names by the folder that holds them: ".wrangler" → ["tmp"].
    static let nestedNames: [String: [String]] = Dictionary(
        allCases.compactMap { kind in kind.container.map { ($0, kind.folderNames) } },
        uniquingKeysWith: +
    )

    /// The kind of `dir`, if it is confirmed build output.
    static func detect(_ dir: URL) -> ArtifactKind? {
        let name = dir.lastPathComponent
        guard allFolderNames.contains(name) else { return nil }
        let parent = dir.deletingLastPathComponent()
        let fm = FileManager.default
        func exists(_ url: URL, _ files: [String]) -> Bool {
            files.contains { fm.fileExists(atPath: url.appending(path: $0).path) }
        }
        func beside(_ files: String...) -> Bool { exists(parent, files) }
        func inside(_ files: String...) -> Bool { exists(dir, files) }
        /// A file with one of these extensions next to the folder: App.csproj.
        func besideSuffix(_ suffixes: String...) -> Bool {
            ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).contains { file in
                suffixes.contains { file.hasSuffix($0) }
            }
        }
        /// For folders inside another one: the holder's name, and a marker
        /// in the project that holds it.
        func within(_ container: String, project files: String...) -> Bool {
            parent.lastPathComponent == container && exists(parent.deletingLastPathComponent(), files)
        }

        switch name {
        case "node_modules": return beside("package.json") ? .nodeModules : nil
        case ".next": return beside("package.json", "next.config.js", "next.config.mjs", "next.config.ts") ? .next : nil
        case ".nuxt": return beside("package.json", "nuxt.config.ts", "nuxt.config.js") ? .nuxt : nil
        case ".svelte-kit": return beside("package.json", "svelte.config.js") ? .svelteKit : nil
        case ".angular": return beside("angular.json") ? .angular : nil
        case ".turbo": return beside("package.json", "turbo.json") ? .turbo : nil
        case ".parcel-cache": return beside("package.json") ? .parcel : nil
        case ".nx": return beside("nx.json") ? .nx : nil
        case ".astro": return beside("astro.config.mjs", "astro.config.js", "astro.config.ts", "astro.config.mts", "astro.config.cjs") ? .astro : nil
        case ".docusaurus":
            return beside("docusaurus.config.js", "docusaurus.config.ts", "docusaurus.config.mjs", "docusaurus.config.mts", "docusaurus.config.cjs")
                ? .docusaurus : nil
        case ".expo": return beside("app.json", "app.config.js", "app.config.ts") ? .expo : nil
        case "output":
            // `vercel build` or a framework's Vercel adapter: the project's
            // vercel.json, the .vercel/project.json link, or the Build
            // Output API's own config.json.
            guard parent.lastPathComponent == ".vercel" else { return nil }
            return within(".vercel", project: "vercel.json") || beside("project.json") || inside("config.json") ? .vercelOutput : nil
        case "tmp": return within(".wrangler", project: "wrangler.toml", "wrangler.json", "wrangler.jsonc") ? .wrangler : nil
        case "coverage":
            // "coverage" is a common folder name: it has to hold a report too.
            guard beside("package.json") else { return nil }
            return inside("lcov.info", "lcov-report", "coverage-final.json", "clover.xml") ? .coverage : nil
        case "target":
            if beside("Cargo.toml") { return .rustTarget }
            return beside("pom.xml") ? .mavenTarget : nil
        case "build": return beside("build.gradle", "build.gradle.kts") ? .gradleBuild : nil
        case ".gradle": return beside("settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts") ? .gradleCache : nil
        case ".cxx": return beside("build.gradle", "build.gradle.kts") ? .androidCxx : nil
        case ".venv", "venv": return inside("pyvenv.cfg") ? .pythonVenv : nil
        case "__pycache__": return .pythonCache
        case ".pytest_cache", ".mypy_cache", ".ruff_cache":
            // Each tool tags its cache with a CACHEDIR.TAG, wherever it ran.
            return inside("CACHEDIR.TAG") ? .pythonToolCache : nil
        case ".tox": return beside("tox.ini", "pyproject.toml", "setup.py", "setup.cfg") ? .tox : nil
        case ".build": return beside("Package.swift") ? .swiftBuild : nil
        case "Pods": return beside("Podfile") ? .pods : nil
        case "Build": return within("Carthage", project: "Cartfile", "Cartfile.resolved") ? .carthageBuild : nil
        case ".dart_tool": return beside("pubspec.yaml") ? .dartTool : nil
        case ".zig-cache", "zig-cache": return beside("build.zig") ? .zigCache : nil
        case ".terraform": return besideSuffix(".tf") ? .terraform : nil
        case "bin", "obj": return besideSuffix(".csproj", ".fsproj", ".vbproj") ? .dotnet : nil
        case "_build", "deps": return beside("mix.exs") ? .elixir : nil
        case ".stack-work": return beside("stack.yaml", "package.yaml") || besideSuffix(".cabal") ? .haskell : nil
        case "dist-newstyle": return beside("cabal.project") || besideSuffix(".cabal") ? .haskell : nil
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
        var folder = path
        for _ in 0..<kind.depth { folder = (folder as NSString).deletingLastPathComponent }
        return folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// Finds every confirmed build folder in the index.
enum ArtifactScanner {
    static func scan(_ db: IndexDB) -> [Artifact] {
        guard let named = try? db.rows(named: Array(ArtifactKind.indexNames)) else { return [] }
        // Folders that hold a kind (".wrangler") stand in for the inner
        // folder ("tmp"), looked up inside each one.
        let rows = named.flatMap { row -> [DirRow] in
            guard let inner = ArtifactKind.nestedNames[row.name] else { return [row] }
            return inner.compactMap { try? db.child(of: row.id, named: $0) }
        }

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
            // The project folder: one up, or two for Carthage/Build.
            var project: DirRow? = row
            for _ in 0..<kind.depth { project = project?.parent.flatMap { parents[$0] ?? (try? db.row($0)) } }
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
