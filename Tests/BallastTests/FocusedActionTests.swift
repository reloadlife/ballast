import Testing
@testable import Ballast

/// The window's focused values must compare equal when rebuilt for the
/// same target. If a rebuilt closure reads as a change, the toolbar re-vends
/// its items on every redraw, adding a layout pass to every update.
struct FocusedActionTests {
    @Test func exportActionsForTheSameTargetAreEqual() {
        let first = ExportAction(id: "explorer:Macintosh HD:42", title: "Export Folder List…") {}
        let rebuilt = ExportAction(id: "explorer:Macintosh HD:42", title: "Export Folder List…") {}
        #expect(first == rebuilt)
    }

    @Test func exportActionsForAnotherTargetDiffer() {
        let folder = ExportAction(id: "explorer:Macintosh HD:42", title: "Export Folder List…") {}
        let other = ExportAction(id: "explorer:Macintosh HD:43", title: "Export Folder List…") {}
        let overview = ExportAction(id: "overview:Macintosh HD", title: "Export Largest Folders…") {}
        #expect(folder != other)
        #expect(folder != overview)
    }

    @Test func findActionsAreAlwaysEqual() {
        #expect(FindAction {} == FindAction {})
    }
}
