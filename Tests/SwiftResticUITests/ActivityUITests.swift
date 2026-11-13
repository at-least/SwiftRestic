import XCTest

final class ActivityUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstBackupIsListed() throws {
        let folders = try UITestFolders.make("Activity")
        let app = UITest.launch(folders)
        UITest.backUpFirstFolder(folders, in: app)

        app.outlines["Sidebar"].staticTexts["Activity"].click()
        // A SwiftUI Table reaches accessibility as an outline of rows.
        let rows = app.outlines[AccessibilityID.Activity.table].outlineRows
        let one = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: rows)
        XCTAssertEqual(XCTWaiter().wait(for: [one], timeout: 10), .completed)
        let row = rows.element(boundBy: 0)
        for value in ["source", "Backup", "1 new · 0 changed"] {
            XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch.exists, value)
        }
        attachScreenshot()
    }
}
