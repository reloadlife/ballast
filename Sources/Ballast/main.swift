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

BallastApp.main()
