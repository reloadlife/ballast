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
    "Can Ballast check SSD health and Mac security?",
    "Yes. Health reads SMART status, SSD endurance, spare capacity, and media errors where macOS exposes them, plus free space, FileVault, SIP, Gatekeeper, and firewall status. Missing readings show Unavailable. These are read-only checks, not a guarantee against drive failure or a replacement for backups.",
  ],
  [
    "Does Ballast check for known vulnerabilities?",
    "With your confirmation, Ballast checks installed Homebrew core formula versions in /opt/homebrew and /usr/local against OSV advisories. Mac apps, casks, third-party taps, custom prefixes, and other package managers are not covered. No known match is not a security guarantee; Ballast does not provide malware protection.",
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
    "Disk indexing and cleanup happen on your Mac. App update checks and anonymous usage sharing are opt-in. Usage events exclude file names, paths, and exact sizes. Homebrew operations contact Homebrew when you request them. Health checks stay local unless you confirm an OSV lookup, which sends reviewed Homebrew package names and versions; OSV also receives your IP address.",
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
    slug: "mac-health-checks",
    title: "Check Mac storage health and security settings",
    description:
      "Read SMART and SSD health data, review Mac security settings, and check supported Homebrew packages for known vulnerabilities with Ballast.",
    sections: [
      {
        title: "Start with a read-only check",
        paragraphs: [
          "In Ballast 0.6.0 and later, open Health in the sidebar and choose Check This Mac. You do not need to finish a disk scan first. These checks run locally and do not change settings, repair disks, or start drive self-tests.",
          "The results show the source and check time. Unrecognized output, permissions errors, and missing data appear as Unavailable rather than Passed. Run the check again when you want a fresh reading.",
        ],
      },
      {
        title: "What SMART and SSD endurance tell you",
        paragraphs: [
          "Ballast asks macOS for the SMART status of physical drives. Where the drive and macOS expose them, it also shows SSD endurance used, available spare capacity, and cumulative media errors. Some external enclosures do not expose these readings. Startup disk space is flagged below 10% free.",
          "Endurance used is the share of the manufacturer’s estimated write endurance already consumed, not an estimate of years remaining. A passed SMART result cannot rule out future failure. Back up important files; if the drive reports failure, prioritize a backup and replacement. Use the Open Disk Utility action for manual filesystem checks.",
        ],
      },
      {
        title: "Review the Mac’s security settings",
        paragraphs: [
          "Health checks FileVault disk encryption, System Integrity Protection, Gatekeeper, and the application firewall. It explains disabled settings without changing them. An unfamiliar or transitional status is not treated as enabled.",
          "The Software Update link opens System Settings, where macOS checks update availability. Ballast does not infer that your Mac is up to date from its version number. These checks are not malware detection or a complete security audit.",
        ],
      },
      {
        title: "Check supported packages against known advisories",
        paragraphs: [
          "Choose Review Packages to read Homebrew installation receipts locally. Ballast includes stable homebrew/core formula versions in /opt/homebrew and /usr/local, including installed revision numbers. It does not run Homebrew or refresh remote package metadata during review.",
          "After reviewing the names and versions, choose Check These Versions Online and confirm. Ballast sends those names, versions, and the Homebrew ecosystem to api.osv.dev. OSV also sees your IP address; file paths, disk metrics, receipts, and app inventory are not uploaded. Permission applies only to that check.",
          "Matches link to OSV advisories for affected-version and remediation details. Mac apps, casks, third-party taps, custom prefixes, HEAD builds, and other package managers are outside the current coverage. An incomplete request is an error, not a clean result. No known matches does not guarantee security, and Ballast does not update or uninstall packages automatically.",
        ],
      },
    ],
  },
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
