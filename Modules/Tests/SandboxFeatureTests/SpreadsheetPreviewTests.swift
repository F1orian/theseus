import Foundation
@testable import SandboxFeature
import Testing

/// #143: Office spreadsheets skip Quick Look, which shrinks them to fit a desktop-width page.
@Suite("Spreadsheet preview (#143)")
struct SpreadsheetPreviewTests {
    @Test(arguments: ["planets.xlsx", "Budget.XLSX", "macro.xlsm", "old.xls"])
    func spreadsheetsUseTheSheetPreview(name: String) {
        #expect(SpreadsheetPreview.handles(URL(filePath: "/tmp/\(name)")))
    }

    @Test(arguments: ["report.pdf", "data.csv", "notes.txt", "deck.pptx", "xlsx"])
    func otherFilesStayInQuickLook(name: String) {
        #expect(!SpreadsheetPreview.handles(URL(filePath: "/tmp/\(name)")))
    }

    @Test func thePageGetsThePhoneWidth() {
        #expect(SpreadsheetPreview.script.contains("width=device-width, initial-scale=1"))
    }
}
