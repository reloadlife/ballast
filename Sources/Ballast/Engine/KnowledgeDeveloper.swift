import Foundation

/// Developer tools: Xcode and simulators, Android, package managers and
/// toolchains, build caches, AI models, containers and virtual machines.
enum KnowledgeDeveloper {
    private static let xcode = ["com.apple.dt.Xcode"]
    private static let simulator = ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]

    private static func deviceSupport(_ platform: String) -> KnowledgeEntry {
        KnowledgeEntry(
            id: "xcode.device-support." + Knowledge.slug(platform), name: "\(platform) device support",
            pathPattern: "Library/Developer/Xcode/\(platform) DeviceSupport", owners: xcode, kind: .cache,
            verdict: .safe, action: .remove,
            regenerates: "Debug files Xcode copied from your devices. It copies them again the next time you connect one."
        )
    }

    private static func cache(_ id: String, _ name: String, _ path: String, owners: [String] = [],
                              action: CleanAction = .remove, _ regenerates: String) -> KnowledgeEntry {
        KnowledgeEntry(id: id, name: name, pathPattern: path, owners: owners, kind: .cache, verdict: .safe,
                       action: action, regenerates: regenerates)
    }

    private static func model(_ id: String, _ name: String, _ path: String, owners: [String] = [],
                              _ regenerates: String) -> KnowledgeEntry {
        KnowledgeEntry(id: id, name: name, pathPattern: path, owners: owners, kind: .model, verdict: .caution,
                       action: .remove, regenerates: regenerates)
    }

    /// A virtual machine or container engine's disk. An app's whole data
    /// folder stays blocked (its own tools clean it); a machine on its own
    /// can go after a tick.
    private static func virtualMachine(_ id: String, _ name: String, _ path: String, owners: [String] = [],
                                       verdict: Safety.Level = .caution, action: CleanAction? = nil,
                                       guidance: String) -> KnowledgeEntry {
        // Pieces of a machine never go on their own: that corrupts its disk.
        KnowledgeEntry(id: id, name: name, pathPattern: path, owners: owners, kind: .userData, verdict: verdict,
                       insideVerdict: .blocked, action: action,
                       regenerates: "Virtual machine disks with everything installed and saved inside them. They can't be brought back.",
                       guidance: guidance)
    }

    private static func toolVersions(_ id: String, _ name: String, _ path: String, _ guidance: String) -> KnowledgeEntry {
        KnowledgeEntry(id: id, name: name, pathPattern: path, kind: .download, verdict: .caution, action: .remove,
                       regenerates: "A tool version you installed. Projects and environments built on it stop working until you install it again.",
                       guidance: guidance)
    }

    static let entries: [KnowledgeEntry] = xcodeEntries + androidEntries + packageEntries + buildEntries
        + modelEntries + containerEntries

    // MARK: Xcode and simulators

    private static let xcodeEntries: [KnowledgeEntry] = [
        KnowledgeEntry(
            id: "xcode.derived-data", name: "Xcode DerivedData", pathPattern: "Library/Developer/Xcode/DerivedData",
            owners: xcode, kind: .buildOutput, verdict: .safe, action: .contents,
            regenerates: "Build products and indexes for every project. Xcode rebuilds a project's on its next build."
        ),
        KnowledgeEntry(
            id: "xcode.archives", name: "Xcode archives", pathPattern: "Library/Developer/Xcode/Archives",
            owners: xcode, kind: .buildOutput, verdict: .caution, action: .remove,
            regenerates: "Apps you archived in Xcode, with the debug symbols that make their crash reports readable. Keep the ones for versions people still use.",
            guidance: "Xcode › Window › Organizer › Archives shows what each one is."
        ),
        deviceSupport("iOS"), deviceSupport("watchOS"), deviceSupport("tvOS"), deviceSupport("macOS"),
        deviceSupport("visionOS"),
        KnowledgeEntry(
            id: "xcode.previews", name: "SwiftUI previews", pathPattern: "Library/Developer/Xcode/UserData/Previews",
            owners: xcode, kind: .buildOutput, verdict: .safe, action: .remove,
            regenerates: "SwiftUI preview builds, rebuilt the next time a preview runs."
        ),
        KnowledgeEntry(
            id: "xcode.device-logs", name: "iOS device logs", pathPattern: "Library/Developer/Xcode/iOS Device Logs",
            owners: xcode, kind: .log, verdict: .safe, action: .remove,
            regenerates: "Crash logs Xcode collected from your devices. It collects new ones when you connect a device."
        ),
        KnowledgeEntry(
            id: "xcode.documentation-cache", name: "Xcode documentation cache",
            pathPattern: "Library/Developer/Xcode/DocumentationCache", owners: xcode, kind: .cache, verdict: .safe, action: .remove,
            regenerates: "Developer documentation Xcode downloaded. It downloads it again when you open the docs."
        ),
        KnowledgeEntry(
            id: "xcode.playground-devices", name: "Playground simulators", pathPattern: "Library/Developer/XCPGDevices",
            owners: xcode, kind: .cache, verdict: .safe, action: .remove,
            regenerates: "Simulators Xcode made to run playgrounds. It makes them again when a playground runs."
        ),
        KnowledgeEntry(
            id: "simulator.caches", name: "Simulator caches", pathPattern: "Library/Developer/CoreSimulator/Caches",
            owners: simulator, kind: .cache, verdict: .safe, action: .remove,
            regenerates: "Shared caches simulators build at first boot. Rebuilt the next time a simulator starts."
        ),
        KnowledgeEntry(
            id: "simulator.device", name: "A simulator device", pathPattern: "Library/Developer/CoreSimulator/Devices/*",
            owners: simulator, kind: .userData, verdict: .blocked,
            action: .command("xcrun simctl delete unavailable"),
            regenerates: "One simulated device with the apps and data installed on it.",
            guidance: "Delete or erase devices in Xcode › Window › Devices and Simulators so Xcode's list stays right."
        ),
        KnowledgeEntry(
            id: "simulator.runtimes", name: "Simulator runtimes", pathPattern: "/Library/Developer/CoreSimulator/Volumes",
            owners: simulator, kind: .download, verdict: .blocked, action: .command("xcrun simctl runtime delete --unusable"),
            regenerates: "iOS, watchOS, tvOS and visionOS runtimes for simulators, mounted from disk images.",
            guidance: "Remove runtimes in Xcode › Settings › Components."
        ),
    ]

    // MARK: Android

    private static let androidEntries: [KnowledgeEntry] = [
        KnowledgeEntry(
            id: "android.system-images", name: "Android system images", pathPattern: "Library/Android/sdk/system-images",
            kind: .download, verdict: .caution, action: .remove,
            regenerates: "Android emulator system images. The SDK Manager downloads them again, but emulators that use one won't start until it does."
        ),
        KnowledgeEntry(
            id: "android.avd", name: "Android emulators", pathPattern: ".android/avd",
            kind: .userData, verdict: .caution, action: .remove,
            regenerates: "Your Android emulators and everything installed or saved in them. You can make new ones, but these can't be brought back.",
            guidance: "Android Studio › Device Manager deletes them one by one."
        ),
        cache("android.cache", "Android SDK cache", ".android/cache", "Downloads the Android tools fetch again."),
    ]

    // MARK: Package managers and toolchains

    private static let packageEntries: [KnowledgeEntry] = [
        cache("npm.cache", "npm cache", ".npm", action: .command("npm cache clean --force"),
              "Packages npm downloaded. The next install downloads what it needs."),
        cache("bun.cache", "Bun install cache", ".bun/install/cache", action: .command("bun pm cache rm"),
              "Packages Bun downloaded. The next install downloads what it needs."),
        cache("pnpm.store", "pnpm store", "Library/pnpm/store", action: .command("pnpm store prune"),
              "Packages pnpm keeps for every project. The next install downloads what it needs."),
        cache("yarn.cache", "Yarn cache", "Library/Caches/Yarn", "Packages Yarn downloaded."),
        cache("yarn.berry-cache", "Yarn cache (Berry)", ".yarn/berry/cache", "Packages Yarn downloaded."),
        cache("pip.cache", "pip cache", "Library/Caches/pip", action: .command("pip3 cache purge"),
              "Packages pip downloaded. The next install downloads what it needs."),
        cache("uv.cache", "uv cache", ".cache/uv", action: .command("uv cache prune"),
              "Packages and Python builds uv downloaded. The next sync downloads what it needs."),
        cache("uv.cache-library", "uv cache", "Library/Caches/uv", action: .command("uv cache prune"),
              "Packages and Python builds uv downloaded. The next sync downloads what it needs."),
        cache("cocoapods.cache", "CocoaPods cache", "Library/Caches/CocoaPods", action: .command("pod cache clean --all"),
              "Pods CocoaPods downloaded. The next pod install downloads what it needs."),
        cache("cocoapods.repos", "CocoaPods spec repos", ".cocoapods/repos",
              "The index of every pod. pod install or pod repo update downloads it again."),
        cache("swiftpm.cache", "Swift package cache", "Library/Caches/org.swift.swiftpm",
              "Package checkouts SwiftPM keeps for every project. Resolved again on the next build."),
        cache("carthage.cache", "Carthage cache", "Library/Caches/org.carthage.CarthageKit",
              "Dependencies Carthage downloaded."),
        cache("deno.cache", "Deno cache", "Library/Caches/deno", action: .command("deno clean"),
              "Modules Deno downloaded and compiled."),
        cache("composer.cache", "Composer cache", "Library/Caches/composer", action: .command("composer clear-cache"),
              "Packages Composer downloaded."),
        cache("composer.cache-home", "Composer cache", ".composer/cache", action: .command("composer clear-cache"),
              "Packages Composer downloaded."),
        cache("go.modules", "Go module cache", "go/pkg/mod", action: .command("go clean -modcache"),
              "Modules Go downloaded. The next build downloads what it needs."),
        cache("go.build-cache", "Go build cache", "Library/Caches/go-build", action: .command("go clean -cache"),
              "Compiled packages Go reuses between builds."),
        cache("gradle.caches", "Gradle caches", ".gradle/caches",
              "Dependencies and build caches. The next Gradle build downloads and rebuilds what it needs."),
        cache("gradle.wrapper", "Gradle wrapper downloads", ".gradle/wrapper/dists",
              "Gradle versions downloaded by project wrappers. The next build downloads the one it needs."),
        cache("gradle.daemon", "Gradle daemon logs", ".gradle/daemon", "Logs and state of Gradle's background daemons."),
        KnowledgeEntry(
            id: "maven.repository", name: "Maven repository", pathPattern: ".m2/repository", kind: .download,
            verdict: .caution, action: .remove,
            regenerates: "Every library Maven has downloaded. Builds download them again, which can take a long time, and anything you installed locally with mvn install is gone."
        ),
        cache("cargo.registry", "Cargo registry", ".cargo/registry", action: .contents,
              "Crates Cargo downloaded. The next build downloads what it needs."),
        cache("cargo.git", "Cargo git checkouts", ".cargo/git", "Git dependencies Cargo checked out."),
        KnowledgeEntry(
            id: "cargo.bin", name: "Tools installed with cargo install", pathPattern: ".cargo/bin", kind: .download,
            verdict: .caution,
            regenerates: "Commands you installed, and the rustup shims. Your shell stops finding them until you install them again."
        ),
        toolVersions("rustup.toolchains", "A Rust toolchain", ".rustup/toolchains/*", "rustup toolchain uninstall <name> removes one cleanly."),
        toolVersions("pyenv.versions", "A Python version (pyenv)", ".pyenv/versions/*", "pyenv uninstall <version> removes one cleanly."),
        toolVersions("nvm.versions", "A Node.js version (nvm)", ".nvm/versions/node/*", "nvm uninstall <version> removes one cleanly."),
        cache("nvm.cache", "nvm download cache", ".nvm/.cache", "Node.js downloads nvm keeps. It downloads them again when needed."),
        toolVersions("fnm.versions", "A Node.js version (fnm)", ".local/share/fnm/node-versions/*", "fnm uninstall <version> removes one cleanly."),
        toolVersions("conda.envs", "A conda environment", "*conda*/envs/*", "conda env remove --name <name> removes one cleanly."),
        toolVersions("conda.envs-forge", "A conda environment", "*forge3/envs/*", "conda env remove --name <name> removes one cleanly."),
        KnowledgeEntry(
            id: "conda.pkgs", name: "conda package cache", pathPattern: "*conda*/pkgs", kind: .cache,
            verdict: .caution, action: .command("conda clean --all --yes"),
            regenerates: "Packages conda downloaded. Environments may link to files in here, so let conda decide what's unused.",
            guidance: "conda clean --all removes what no environment needs."
        ),
        KnowledgeEntry(
            id: "conda.pkgs-forge", name: "conda package cache", pathPattern: "*forge3/pkgs", kind: .cache,
            verdict: .caution, action: .command("conda clean --all --yes"),
            regenerates: "Packages conda downloaded. Environments may link to files in here, so let conda decide what's unused.",
            guidance: "conda clean --all removes what no environment needs."
        ),
        KnowledgeEntry(
            id: "conda.pkgs-home", name: "conda package cache", pathPattern: ".conda/pkgs", kind: .cache,
            verdict: .caution, action: .command("conda clean --all --yes"),
            regenerates: "Packages conda downloaded. Environments may link to files in here, so let conda decide what's unused.",
            guidance: "conda clean --all removes what no environment needs."
        ),
        cache("pub.hosted", "Dart and Flutter packages", ".pub-cache/hosted",
              "Packages pub downloaded. flutter pub get or dart pub get downloads them again."),
        cache("pub.git", "Dart and Flutter git packages", ".pub-cache/git", "Git packages pub checked out."),
        KnowledgeEntry(
            id: "pub.cache", name: "Dart and Flutter pub cache", pathPattern: ".pub-cache", kind: .cache,
            verdict: .caution,
            regenerates: "Downloaded packages, plus tools you installed with pub global activate, which don't come back on their own."
        ),
        cache("homebrew.cache", "Homebrew downloads", "Library/Caches/Homebrew", action: .command("brew cleanup -s --prune=all"),
              "Bottles and source Homebrew downloaded. It downloads them again for the next install or upgrade."),
        KnowledgeEntry(
            id: "homebrew.intel", name: "Homebrew (Intel)", pathPattern: "/usr/local/Homebrew", kind: .system,
            verdict: .blocked, action: .command("brew cleanup -s --prune=all"),
            regenerates: "Homebrew itself on an Intel Mac or under Rosetta.",
            guidance: "Remove packages with brew uninstall."
        ),
    ]

    // MARK: Build tools and test browsers

    private static let buildEntries: [KnowledgeEntry] = [
        cache("playwright.browsers", "Playwright browsers", "Library/Caches/ms-playwright",
              "Browsers Playwright downloaded for tests. npx playwright install fetches them again."),
        cache("puppeteer.browsers", "Puppeteer browsers", ".cache/puppeteer",
              "Browsers Puppeteer downloaded. The next install downloads them again."),
        cache("electron.downloads", "Electron downloads", "Library/Caches/electron",
              "Electron builds npm packages downloaded. The next install downloads them again."),
        cache("electron-builder.cache", "electron-builder cache", "Library/Caches/electron-builder",
              "Tools electron-builder downloaded to package apps."),
        cache("node-gyp.headers", "node-gyp headers", "Library/Caches/node-gyp",
              "Node.js headers for compiling native modules. Downloaded again on the next native build."),
        cache("node-gyp.headers-home", "node-gyp headers", ".node-gyp",
              "Node.js headers for compiling native modules. Downloaded again on the next native build."),
        KnowledgeEntry(
            id: "bazel.output", name: "Bazel output", pathPattern: "/private/var/tmp/_bazel_*", kind: .buildOutput,
            verdict: .safe, action: .command("bazel clean --expunge"),
            regenerates: "Bazel's build outputs and downloaded dependencies. The next build makes them again.",
            guidance: "bazel clean --expunge in each workspace removes them the way Bazel expects."
        ),
        cache("bazelisk.cache", "Bazelisk downloads", "Library/Caches/bazelisk", "Bazel versions Bazelisk downloaded."),
        cache("ccache.cache", "ccache", "Library/Caches/ccache", action: .command("ccache --clear"),
              "Compiler results ccache reuses. Builds are slower until it fills again."),
        cache("ccache.cache-home", "ccache", ".ccache", action: .command("ccache --clear"),
              "Compiler results ccache reuses. Builds are slower until it fills again."),
        cache("sccache.cache", "sccache", "Library/Caches/Mozilla.sccache",
              "Compiler results sccache reuses. Builds are slower until it fills again."),
        cache("unity.cache", "Unity cache", "Library/Unity/cache",
              "Packages and assets Unity downloaded. Downloaded again when a project needs them."),
        cache("pre-commit.cache", "pre-commit environments", ".cache/pre-commit",
              "Hook environments pre-commit installs again on the next commit."),
    ]

    // MARK: AI models

    private static let modelEntries: [KnowledgeEntry] = [
        model("models.huggingface", "Hugging Face models", ".cache/huggingface",
              "Models and datasets downloaded from Hugging Face. They download again when needed, which can take a long time."),
        model("models.lm-studio-cache", "LM Studio models", ".cache/lm-studio", owners: ["ai.elementlabs.lmstudio"],
              "Models you downloaded in LM Studio. You'd have to download them again to use them."),
        model("models.lm-studio", "LM Studio models", ".lmstudio/models", owners: ["ai.elementlabs.lmstudio"],
              "Models you downloaded in LM Studio. You'd have to download them again to use them."),
        model("models.torch", "PyTorch Hub models", ".cache/torch",
              "Models and weights PyTorch downloaded. Scripts download them again, which can take a long time."),
        model("models.whisper", "Whisper models", ".cache/whisper",
              "Speech-recognition models Whisper downloaded. They download again when used."),
        model("models.ollama", "Ollama models", ".ollama/models", owners: ["com.electron.ollama", "Ollama"],
              "Models you pulled with Ollama. You'd have to pull them again to use them."),
    ]

    // MARK: Containers and virtual machines

    private static let containerEntries: [KnowledgeEntry] = [
        virtualMachine("docker.desktop", "Docker Desktop's disk", "Library/Containers/com.docker.docker",
                       owners: ["com.docker.docker"], verdict: .blocked, action: .command(Catalog.dockerPrune),
                       guidance: "Free space with docker system prune, or Docker Desktop › Troubleshoot › Clean / Purge data. The disk file shrinks only after Docker compacts it."),
        virtualMachine("orbstack.disk", "OrbStack's disk", "Library/Group Containers/HUAQ24HBR6.dev.orbstack",
                       owners: ["dev.kdrag0n.MacVirt"], verdict: .blocked, action: .command(Catalog.dockerPrune),
                       guidance: "Free space with docker system prune, or delete machines in OrbStack."),
        virtualMachine("colima.disk", "Colima's virtual machines", ".colima", action: .command(Catalog.dockerPrune),
                       guidance: "colima delete removes a machine cleanly."),
        virtualMachine("lima.disk", "Lima virtual machines", ".lima", guidance: "limactl delete <name> removes one cleanly."),
        virtualMachine("podman.machines", "Podman machines", ".local/share/containers/podman/machine",
                       guidance: "podman machine rm removes one cleanly."),
        virtualMachine("rancher.disk", "Rancher Desktop's virtual machine", "Library/Application Support/rancher-desktop/lima",
                       owners: ["io.rancherdesktop.app"], verdict: .blocked, guidance: "Use Troubleshooting › Factory Reset in Rancher Desktop."),
        virtualMachine("utm.machines", "A UTM virtual machine", "Library/Containers/com.utmapp.UTM/Data/Documents/*.utm",
                       owners: ["com.utmapp.UTM"], guidance: "Delete machines in UTM."),
        virtualMachine("parallels.machines", "A Parallels virtual machine", "Parallels/*.pvm",
                       owners: ["com.parallels.desktop.console"], guidance: "Remove machines in Parallels Desktop's Control Center."),
    ]
}
