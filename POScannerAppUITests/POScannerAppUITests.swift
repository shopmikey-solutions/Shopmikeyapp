import XCTest

final class POScannerAppUITests: XCTestCase {

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
        XCTAssertTrue(app.switches["scan.ignoreTaxToggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scan.quickHistory"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scan.quickSettings"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Shopmonkey Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["settings.apiKeyField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["settings.saveHistoryToggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["settings.ignoreTaxToggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.testConnectionButton"].waitForExistence(timeout: 5))

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
        XCTAssertTrue(fixtureButton.waitForExistence(timeout: 5))
        fixtureButton.tap()

        XCTAssertTrue(app.navigationBars["Parts Intake Review"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["review.vendorField"].waitForExistence(timeout: 5))
        let modePicker = app.segmentedControls["review.modePicker"]
        if !modePicker.exists {
            app.swipeUp()
        }
        XCTAssertTrue(modePicker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["review.submitButton"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.staticTexts["Front Brake Pad Set - Ceramic"].exists)
        XCTAssertTrue(app.staticTexts["225/60/16 Primacy Michelin"].exists)
        XCTAssertTrue(app.staticTexts["Shipping"].exists)

        let saveDraftButton = app.buttons["review.saveDraftButton"]
        XCTAssertTrue(saveDraftButton.waitForExistence(timeout: 5))
        saveDraftButton.tap()
        let savedTimestamp = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] 'Saved '")).firstMatch
        XCTAssertTrue(savedTimestamp.waitForExistence(timeout: 5))

        let backButton = app.navigationBars["Parts Intake Review"].buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()

        XCTAssertTrue(app.navigationBars["ShopMikey"].waitForExistence(timeout: 5))
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["Purchase Order History"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["history.scopePicker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["METRO AUTO PARTS SUPPLY"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
