export const faqs = [
  [
    "What is Ballast?",
    "Ballast is a free, open-source disk analyzer and cleaner for macOS 26 and later. It maps your disk, finds large files and cleanup opportunities, and explains the safety of each item before you remove it.",
  ],
  [
    "Is Ballast really free?",
    "Yes. Ballast is fully open source under AGPL-3.0. There is no subscription or paid feature tier. You can download the app, inspect its source, and build it yourself.",
  ],
  [
    "Is Ballast an alternative to CleanMyMac?",
    "For finding what uses disk space and reviewing cleanup, yes. Ballast focuses on storage analysis, careful file cleanup, and developer tools. It does not claim to replace every maintenance or security feature in other Mac utilities.",
  ],
  [
    "Will it delete my files automatically?",
    "Ordinary cleanup starts with your review. Files go to the Trash by default. Optional auto-clean rules start disabled and must be configured by you; each rule chooses Trash or permanent deletion. Tool commands and permanent deletion cannot be undone.",
  ],
  [
    "What makes repeat scans fast?",
    "Ballast stores a full disk index and uses the macOS FSEvents change log to find changed folders. It can update those folders instead of measuring the entire disk again. Timing depends on your disk, permissions, and how much changed.",
  ],
  [
    "Does my file data leave my Mac?",
    "Disk indexing and cleanup happen on your Mac. App update checks and anonymous usage sharing are opt-in. Usage events exclude file names, paths, and exact sizes. Homebrew operations contact Homebrew when you request them.",
  ],
] as const;
export type Guide = {
  slug: string;
  title: string;
  description: string;
  sections: { title: string; paragraphs: string[] }[];
};
export const guides: Guide[] = [
  {
    slug: "mac-system-data",
    title: "What is System Data on a Mac?",
    description:
      "System Data is a catch-all storage category, not a single folder you can safely delete. Identify what is inside it before choosing a cleanup.",
    sections: [
      {
        title: "Why the number can be so large",
        paragraphs: [
          "macOS groups many different kinds of storage under System Data. Caches, logs, swap, local snapshots, downloaded system assets, and files outside familiar categories can contribute. Some space is necessary for the operating system; some is temporary or reclaimable.",
          "A large System Data number does not mean that the same amount is safe to remove. Deleting a Library folder wholesale can remove app settings, saved logins, or data you still need.",
        ],
      },
      {
        title: "Start by identifying the space",
        paragraphs: [
          "Open Ballast and let the disk index finish. The Overview separates applications, your files, caches, build files, and system storage. Its System Data breakdown explains macOS itself, boot and update files, swap, Recovery, snapshots, downloaded assets, system caches and logs, Homebrew, and anything it could not measure.",
          "Unreadable folders and filesystem bookkeeping are named explicitly. Granting Full Disk Access can let Ballast measure privacy-protected locations; an administrator scan is a separate option for Unix-permission errors. Neither permission is an instruction to delete those files.",
        ],
      },
      {
        title: "Review the recoverable parts",
        paragraphs: [
          "Start with recognized caches, old installers, and build output in Suggestions. Review each safety explanation, close an app if requested, and prefer Move to Trash. Keep backups of irreplaceable files.",
          "Ballast can list local Time Machine snapshots and ask macOS to thin them. That is a separate, confirmed action; it does not remove backups from your backup disk. Leave swap and protected system files to macOS.",
        ],
      },
      {
        title: "Check the result without chasing a perfect number",
        paragraphs: [
          "Storage figures can differ because APFS shares blocks, snapshots retain data, and some folders cannot be read. Emptying the Trash makes a cleanup permanent. Review what went there before doing so; Ballast’s Put Back can restore items while they are still present.",
        ],
      },
    ],
  },
  {
    slug: "developer-cache-cleanup",
    title: "Clean developer caches on a Mac",
    description:
      "Find node_modules, Xcode DerivedData, build folders, and tool caches with enough context to decide what can be rebuilt.",
    sections: [
      {
        title: "Separate rebuildable files from your work",
        paragraphs: [
          "Source files, Git history, credentials, and project settings are different from dependencies and build output. Ballast recognizes project artifacts using context: for example, a Rust target folder next to Cargo.toml. A matching folder name alone is not enough.",
          "Supported categories include node_modules, Next.js .next, SwiftPM .build, Rust and Maven target, Gradle build output, Python virtual environments and caches, and Xcode DerivedData. Some generated directories also require the project’s ignore rules to confirm their role.",
        ],
      },
      {
        title: "Review caches by tool",
        paragraphs: [
          "Suggestions cover caches from npm, Bun, pnpm, Yarn, pip, uv, Go, Cargo, Gradle, and other tools. Removing rebuildable data can mean your next install or build downloads files again. Consider whether you need those dependencies offline.",
          "Where a tool has a supported cleanup command, Ballast uses it. A command such as brew cleanup or go clean -modcache is not the same as moving a folder to the Trash, and cannot be reversed with Put Back.",
        ],
      },
      {
        title: "Treat worktrees and packages as managed resources",
        paragraphs: [
          "Homebrew packages are updated or uninstalled through brew. Pinned formulae remain pinned. Git worktrees are checked before removal and removed through Git, retaining their branches and commits.",
          "Changed, untracked, ignored, locked, and unreferenced detached work is protected during worktree removal. Clean Build Files offers a separate review of recognized ignored build folders, including in the main worktree.",
        ],
      },
      {
        title: "Stop related work before temporary-file cleanup",
        paragraphs: [
          "Large temporary folders can belong to active builds or deployment work. Review them and stop related work first. Ballast protects other users’ and system services’ temporary files rather than treating everything in /tmp as disposable.",
        ],
      },
    ],
  },
  {
    slug: "safe-mac-cleanup",
    title: "How to clean Mac storage carefully",
    description:
      "Understand what you are removing, review safety verdicts, and keep a path back for ordinary file cleanup.",
    sections: [
      {
        title: "Understand before deleting",
        paragraphs: [
          "Begin with a storage overview and look at the largest folders. A large file is not automatically junk. Photos, virtual machines, mail, app containers, and source repositories may be large because they hold valuable work.",
          "Ballast adds context to cleanup suggestions and checks every item again at removal time. Its four verdicts are Safe to clean, Quit the app first, Check first, and Protected.",
        ],
      },
      {
        title: "Use the Trash by default",
        paragraphs: [
          "Regular file cleanup moves items to the Trash by default. Permanent deletion is a separate choice. Tool-managed cleanup runs the tool’s command instead; those operations do not become recoverable merely because Trash is selected for other items.",
          "Ballast keeps a cleanup history with the destination of trashed items. Put Back can restore them while they remain in the Trash. It will not overwrite a file or folder that has since appeared at the original location.",
        ],
      },
      {
        title: "Keep app data attached to the right app",
        paragraphs: [
          "An installed app’s data is protected on its own. App uninstall reviews the app and its matching data together, checks them again, and moves them to the Trash. Root-owned apps are skipped instead of escalating privileges to delete them.",
          "Running apps’ caches are left alone during parent-cache cleanup. Files Ballast cannot confidently identify remain protected. These checks reduce risk; they do not replace a backup of your important data.",
        ],
      },
      {
        title: "Be deliberate about automation",
        paragraphs: [
          "Auto-clean rules are optional and start disabled. Each rule chooses its targets, age, and Trash or permanent deletion. Review the consequences before enabling one. Automatic cleanup is not a requirement for using Ballast.",
        ],
      },
    ],
  },
  {
    slug: "how-ballast-works",
    title: "How Ballast keeps disk scans fast",
    description:
      "A persistent disk index and macOS FSEvents let Ballast revisit changed folders instead of starting from zero.",
    sections: [
      {
        title: "Measure the disk once",
        paragraphs: [
          "Ballast’s first scan measures folders on the data volume and stores the results in a local SQLite index. This creates a map that the Overview, Explorer, and Suggestions can share. Locked or unreadable folders are reported rather than silently treated as empty.",
          "The repository documents a first scan of around two minutes on a 500 GB Mac with roughly four million files. That is one example, not a promise for every Mac or a comparison against a competing app.",
        ],
      },
      {
        title: "Follow the changes macOS already records",
        paragraphs: [
          "macOS maintains a filesystem event log called FSEvents. Ballast replays that log and rechecks changed folders, keeping the stored index current. Reopening can therefore take seconds instead of another full scan when relatively little has changed.",
          "Drive size, file count, access permissions, hardware, and the amount of intervening activity all affect timings. Ballast does not publish a controlled head-to-head speed benchmark against CleanMyMac or other utilities.",
        ],
      },
      {
        title: "Keep the interface native",
        paragraphs: [
          "The app is written in Swift and SwiftUI for macOS 26. Its storage map, cleanup review, menu bar item, desktop widget, and Shortcuts integrations use native macOS capabilities. The website’s 3D illustration is separate from the app.",
        ],
      },
      {
        title: "Other drives have their own rules",
        paragraphs: [
          "Ballast scans external drives only when asked and keeps a separate index for each. APFS and Mac OS Extended drives can be updated from their own change logs. ExFAT and FAT drives need rescanning after reconnection. Read-only drives can be explored but not cleaned; network drives are not supported.",
        ],
      },
    ],
  },
];
