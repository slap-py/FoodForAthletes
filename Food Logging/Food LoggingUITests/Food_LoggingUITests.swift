//
//  Food_LoggingUITests.swift
//  Food LoggingUITests
//
//  Created by Kai Bergman on 8/16/26.
//

import XCTest

final class Food_LoggingUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testFirstDayShowsNeutralEmptyStateAndCapture() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launch()

        XCTAssertTrue(app.staticTexts["Nutrition so far"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No meals logged today"].exists)

        app.buttons["Log meal"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Log food"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Search foods"].exists)
        XCTAssertTrue(app.buttons["AI estimate"].exists)
        XCTAssertTrue(app.staticTexts["REPEAT A MEAL"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments.append("-ui-testing")
            app.launch()
        }
    }
}
