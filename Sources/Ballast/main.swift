import Foundation

let arguments = CommandLine.arguments

// The same binary doubles as the privileged scanner: AdminScan relaunches it
// as root with `--admin-scan <output> <paths…>`.
if arguments.count >= 3, arguments[1] == AdminScan.flag {
    exit(AdminScan.main(output: arguments[2], paths: Array(arguments.dropFirst(3))))
}

// Headless index maintenance: `Ballast --index full|update`.
if arguments.count == 3, arguments[1] == "--index" {
    let report: StatusHandler = { status in
        let walk = status.walk.map { " \($0.dirs) dirs \($0.bytes.formatted(.byteCount(style: .file)))" } ?? ""
        FileHandle.standardError.write(Data("\r\(status.title)\(walk)\u{1B}[K".utf8))
    }
    let start = Date.now
    do {
        switch arguments[2] {
        case "full": try ScanEngine.fullScan(report: report, cancel: CancelFlag())
        case "update":
            do {
                try ScanEngine.update(report: report, cancel: CancelFlag())
            } catch ScanEngine.Failure.needsFullScan {
                try ScanEngine.fullScan(report: report, cancel: CancelFlag())
            }
        default: throw IndexError(message: "expected full or update")
        }
        print("\ndone in \(Int(Date.now.timeIntervalSince(start)))s")
        exit(0)
    } catch {
        print("\nfailed: \(error)")
        exit(1)
    }
}

// Daily background run (installed as a LaunchAgent from Settings):
// `Ballast --auto-clean [--dry-run]`.
if arguments.count >= 2, arguments[1] == "--auto-clean" {
    let dryRun = arguments.contains("--dry-run")
    let stamp = Date.now.formatted(date: .abbreviated, time: .shortened)
    do {
        let run = try AutoClean.run(dryRun: dryRun, apps: AppInventory.current())
        print("\(stamp) auto-clean\(dryRun ? " (dry run)" : ""): \(run.cleaned.count) folders, \(run.cleanedBytes.formatted(.byteCount(style: .file))); \(run.skipped) not eligible")
        for entry in run.entries {
            print("  \(entry.error == nil ? "✓" : "–") \(entry.kind.title): \(entry.path)\(entry.error.map { " (\($0))" } ?? "")")
        }
        if !dryRun, !run.cleaned.isEmpty {
            Notify.post(
                title: "Ballast cleaned \(run.cleaned.count) build folder\(run.cleaned.count == 1 ? "" : "s")",
                body: run.freed > 0 ? "\(run.freed.formatted(.byteCount(style: .file))) freed." : "Moved to the Trash."
            )
        }
        exit(0)
    } catch {
        print("\(stamp) auto-clean failed: \(error)")
        exit(1)
    }
}

BallastApp.main()
