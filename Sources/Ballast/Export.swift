import SwiftUI
import UniformTypeIdentifiers

/// One folder in an exported list.
struct ExportRow: Codable, Sendable, Hashable {
    /// Display path.
    let path: String
    let name: String
    /// Allocated bytes, as `du` counts them. Not measured when `locked`.
    let bytes: Int64
    /// The same, the way Ballast shows it ("1.2 GB").
    let size: String
    /// Fraction of the listed folder (Explorer) or of everything measured (Largest folders).
    let share: Double
    /// Newest change anywhere inside, ISO 8601; nil when unknown.
    let lastModified: String?
    /// Ballast couldn't read this folder, so `bytes` isn't its real size.
    let locked: Bool

    init(path: String, row: DirRow, of whole: Int64) {
        self.path = path
        name = path == "/" ? Paths.volumeName : row.name
        bytes = row.total
        size = row.total.bytes
        share = whole > 0 ? Double(row.total) / Double(whole) : 0
        lastModified = row.newest > 0
            ? Date(timeIntervalSince1970: TimeInterval(row.newest)).formatted(.iso8601)
            : nil
        locked = row.err != 0
    }

    static let csvHeader = ["path", "name", "bytes", "size", "share", "last_modified", "locked"]

    var csvFields: [String] {
        [path, name, String(bytes), size, String(format: "%.4f", share), lastModified ?? "", locked ? "true" : "false"]
    }
}

/// RFC 4180 CSV: fields with a comma, quote or line break are quoted, and
/// quotes inside are doubled. Folder names can contain all three.
enum CSV {
    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func line(_ fields: [String]) -> String {
        fields.map(field).joined(separator: ",")
    }

    /// Header plus one line per row, CRLF-terminated as the RFC asks.
    static func document(_ rows: [ExportRow]) -> String {
        ([ExportRow.csvHeader] + rows.map(\.csvFields)).map(line).joined(separator: "\r\n") + "\r\n"
    }
}

/// A folder list for File › Export…, written as CSV or JSON, whichever the
/// save panel's format menu is set to.
struct FolderExport: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .json]

    let rows: [ExportRow]

    init(rows: [ExportRow]) {
        self.rows = rows
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try Self.data(rows, as: configuration.contentType))
    }

    static func data(_ rows: [ExportRow], as type: UTType) throws -> Data {
        if type.conforms(to: .json) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(rows)
        }
        return Data(CSV.document(rows).utf8)
    }
}

/// What File › Export… does in the frontmost window, if anything.
///
/// Focused values are compared on every update, and the toolbar re-vends
/// its items whenever they change. A closure never compares equal to a
/// rebuilt one, so without `Equatable` each redraw reads as new focus:
/// while the inspector animates open, that re-vend schedules another
/// layout pass, AppKit runs out of passes and throws (the Cleanup List
/// crash). Equal means "exports the same thing": `id` names what
/// `perform` would export.
struct ExportAction: Equatable {
    let id: String
    let title: String
    let perform: () -> Void

    static func == (lhs: ExportAction, rhs: ExportAction) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title
    }
}

/// ⌘F: jump to Explorer's search field. Always the same action, so any
/// two are equal (see ExportAction for why that matters).
struct FindAction: Equatable {
    let perform: () -> Void

    static func == (lhs: FindAction, rhs: FindAction) -> Bool { true }
}

extension FocusedValues {
    @Entry var exportAction: ExportAction?
    @Entry var findAction: FindAction?
}
