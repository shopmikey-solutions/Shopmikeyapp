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
        let scanList = scrollContainer(in: app)
        let ignoreTaxToggle = app.switches["scan.ignoreTaxToggle"]
        if let scanList {
            ensureVisible(ignoreTaxToggle, in: scanList)
        }
        XCTAssertTrue(ignoreTaxToggle.waitForExistence(timeout: 5))
        let quickHistoryButton = app.buttons["scan.quickHistory"]
        if let scanList {
            ensureVisible(quickHistoryButton, in: scanList)
        }
        XCTAssertTrue(quickHistoryButton.waitForExistence(timeout: 5))
        let quickSettingsButton = app.buttons["scan.quickSettings"]
        if let scanList {
            ensureVisible(quickSettingsButton, in: scanList)
        }
        XCTAssertTrue(quickSettingsButton.waitForExistence(timeout: 5))

        app.tabBars.buttons["Settings"].tap()
        let brandedSettingsNavBar = app.navigationBars["Shopmonkey Settings"]
        let fallbackSettingsNavBar = app.navigationBars["Settings"]
        XCTAssertTrue(
            brandedSettingsNavBar.waitForExistence(timeout: 5)
                || fallbackSettingsNavBar.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.textFields["settings.apiKeyField"].waitForExistence(timeout: 5)
                || app.secureTextFields["settings.apiKeyField"].waitForExistence(timeout: 5)
        )
        let settingsList = scrollContainer(in: app)
        let saveHistoryToggle = app.switches["settings.saveHistoryToggle"]
        if let settingsList {
            ensureVisible(saveHistoryToggle, in: settingsList)
        }
        XCTAssertTrue(saveHistoryToggle.waitForExistence(timeout: 5))
        let settingsIgnoreTaxToggle = app.switches["settings.ignoreTaxToggle"]
        if let settingsList {
            ensureVisible(settingsIgnoreTaxToggle, in: settingsList)
        }
        XCTAssertTrue(settingsIgnoreTaxToggle.waitForExistence(timeout: 5))
        let testConnectionButton = app.buttons["settings.testConnectionButton"]
        if let settingsList {
            ensureVisible(testConnectionButton, in: settingsList)
        }
        XCTAssertTrue(testConnectionButton.waitForExistence(timeout: 5))

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["Purchase Order History"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSmokeFlowLaunchToReviewFixtureAndHistory() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-test-review-fixture"]
        app.launch()

        XCTAssertTrue(app.navigationBars["ShopMikey"].waitForExistence(timeout: 5))
        let scanTab = app.tabBars.buttons["Scan"]
        if scanTab.exists {
            scanTab.tap()
        }
        let fixtureButton = app.buttons["scan.openReviewFixture"]
        if let scanList = scrollContainer(in: app) {
            ensureVisible(fixtureButton, in: scanList)
        }
        XCTAssertTrue(fixtureButton.waitForExistence(timeout: 5))
        fixtureButton.tap()

        XCTAssertTrue(app.navigationBars["Parts Intake Review"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["review.vendorField"].waitForExistence(timeout: 5))
        let reviewList = scrollContainer(in: app)
        let modePicker = app.segmentedControls["review.modePicker"]
        if let reviewList {
            ensureVisible(modePicker, in: reviewList)
        }
        if modePicker.exists {
            XCTAssertTrue(modePicker.waitForExistence(timeout: 5))
        }
        let submitButton = app.buttons["review.submitButton"]
        if let reviewList {
            ensureVisible(submitButton, in: reviewList)
        }
        XCTAssertTrue(submitButton.waitForExistence(timeout: 5))

        let saveDraftButton = app.buttons["review.saveDraftButton"]
        if let reviewList {
            ensureVisible(saveDraftButton, in: reviewList)
        }
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
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    private func ensureVisible(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        maxScrollAttempts: Int = 6
    ) {
        if !scrollView.exists {
            _ = scrollView.waitForExistence(timeout: 2)
        }
        guard scrollView.exists else { return }
        if element.exists && element.isHittable { return }

        var attempts = 0
        while attempts < maxScrollAttempts && (!element.exists || !element.isHittable) {
            scrollView.swipeUp()
            attempts += 1
        }

        attempts = 0
        while attempts < maxScrollAttempts && (!element.exists || !element.isHittable) {
            scrollView.swipeDown()
            attempts += 1
        }
    }

    @MainActor
    private func scrollContainer(in app: XCUIApplication) -> XCUIElement? {
        let candidates: [XCUIElement] = [
            app.tables.firstMatch,
            app.collectionViews.firstMatch,
            app.scrollViews.firstMatch
        ]

        for candidate in candidates where candidate.waitForExistence(timeout: 1) {
            return candidate
        }

        return nil
    }
}
