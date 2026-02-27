import XCTest

final class POScannerAppUITests: XCTestCase {

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) -> Bool {
        if element.waitForExistence(timeout: 1.0) {
            return true
        }

        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 0.5) {
                return true
            }
        }

        for _ in 0..<maxSwipes {
            app.swipeDown()
            if element.waitForExistence(timeout: 0.5) {
                return true
            }
        }

        return false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTabNavigationAndSettingsControls() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["ShopMikey"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["scan.dashboardTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scan.scanButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(app.switches["scan.ignoreTaxToggle"], in: app))
        XCTAssertTrue(reveal(app.buttons["scan.quickHistory"], in: app))
        XCTAssertTrue(reveal(app.buttons["scan.quickSettings"], in: app))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(app.switches["settings.saveHistoryToggle"], in: app))
        XCTAssertTrue(reveal(app.switches["settings.ignoreTaxToggle"], in: app))
        XCTAssertTrue(reveal(app.buttons["settings.testConnectionButton"], in: app))

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["Purchase Order History"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSmokeFlowLaunchToReviewFixtureAndHistory() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-test-review-fixture"]
        app.launch()

        XCTAssertTrue(app.navigationBars["ShopMikey"].waitForExistence(timeout: 5))
        let fixtureButton = app.buttons["scan.openReviewFixture"]
        XCTAssertTrue(reveal(fixtureButton, in: app))
        fixtureButton.tap()

        XCTAssertTrue(app.navigationBars["Parts Intake Review"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["review.vendorField"].waitForExistence(timeout: 5))
        let modePicker = app.segmentedControls["review.modePicker"]
        if !modePicker.exists {
            app.swipeUp()
        }

        XCTAssertTrue(app.staticTexts["Front Brake Pad Set - Ceramic"].exists)
        XCTAssertTrue(app.staticTexts["225/60/16 Primacy Michelin"].exists)
        XCTAssertTrue(app.staticTexts["Shipping"].exists)

        let backButton = app.navigationBars["Parts Intake Review"].buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()

        XCTAssertTrue(app.navigationBars["ShopMikey"].waitForExistence(timeout: 5))
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["Purchase Order History"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["METRO AUTO PARTS SUPPLY"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testBulkSelectionTypeAndDeleteFlow() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-test-review-fixture"]
        app.launch()

        XCTAssertTrue(app.navigationBars["ShopMikey"].waitForExistence(timeout: 5))
        let fixtureButton = app.buttons["scan.openReviewFixture"]
        XCTAssertTrue(reveal(fixtureButton, in: app))
        fixtureButton.tap()

        XCTAssertTrue(app.navigationBars["Parts Intake Review"].waitForExistence(timeout: 5))

        let selectButton = app.buttons["review.selectModeButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5))
        selectButton.tap()

        let lineA = app.staticTexts["Front Brake Pad Set - Ceramic"]
        let lineB = app.staticTexts["225/60/16 Primacy Michelin"]
        XCTAssertTrue(lineA.waitForExistence(timeout: 5))
        XCTAssertTrue(lineB.waitForExistence(timeout: 5))
        lineA.tap()
        lineB.tap()

        let selectedCount = app.staticTexts["review.selectedCountLabel"]
        XCTAssertTrue(selectedCount.waitForExistence(timeout: 5))
        XCTAssertTrue(selectedCount.label.contains("2"))

        let setTypeButton = app.buttons["review.bulkSetTypeButton"]
        XCTAssertTrue(setTypeButton.waitForExistence(timeout: 5))
        setTypeButton.tap()

        let feeButton = app.buttons["Fee"]
        XCTAssertTrue(feeButton.waitForExistence(timeout: 5))
        feeButton.tap()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Fee")).count >= 2)

        lineA.tap()
        lineB.tap()

        let deleteButton = app.buttons["review.bulkDeleteButton"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()

        let confirmDelete = app.buttons["Delete"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()

        XCTAssertFalse(lineA.waitForExistence(timeout: 3))
        XCTAssertFalse(lineB.waitForExistence(timeout: 3))

        selectButton.tap()

        let remainingLine = app.staticTexts["Shipping"]
        if remainingLine.waitForExistence(timeout: 5) {
            remainingLine.tap()
            XCTAssertTrue(app.navigationBars["Line Item"].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
