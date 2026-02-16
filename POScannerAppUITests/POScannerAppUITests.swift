import XCTest

final class POScannerAppUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTabNavigationAndSettingsControls() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Purchase Orders"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["scan.dashboardTitle"].exists)
        XCTAssertTrue(app.buttons["scan.scanButton"].exists)
        XCTAssertTrue(app.switches["scan.ignoreTaxToggle"].exists)
        XCTAssertTrue(app.buttons["scan.quickHistory"].exists)
        XCTAssertTrue(app.buttons["scan.quickSettings"].exists)

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["settings.apiKeyField"].exists)
        XCTAssertTrue(app.switches["settings.saveHistoryToggle"].exists)
        XCTAssertTrue(app.switches["settings.ignoreTaxToggle"].exists)
        XCTAssertTrue(app.buttons["settings.testConnectionButton"].exists)

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testReviewFixtureFlow() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-test-review-fixture"]
        app.launch()

        let fixtureButton = app.buttons["scan.openReviewFixture"]
        XCTAssertTrue(fixtureButton.waitForExistence(timeout: 5))
        fixtureButton.tap()

        XCTAssertTrue(app.navigationBars["Review"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["review.vendorField"].exists)
        XCTAssertTrue(app.segmentedControls["review.modePicker"].exists)
        XCTAssertTrue(app.buttons["review.submitButton"].exists)

        XCTAssertTrue(app.staticTexts["Front Brake Pad Set - Ceramic"].exists)
        XCTAssertTrue(app.staticTexts["225/60/16 Primacy Michelin"].exists)
        XCTAssertTrue(app.staticTexts["Shipping"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
