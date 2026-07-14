import XCTest

final class HarnessHostedSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDelegationSurfaceAppears() throws {
        let app = XCUIApplication()
        app.launch()
        app.activate()

        if !app.windows.firstMatch.waitForExistence(timeout: 5) {
            app.typeKey("n", modifierFlags: .command)
        }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "Harness never exposed a visible app window")
        let delegation = window.descendants(matching: .any)["Delegation"]
        XCTAssertTrue(
            delegation.waitForExistence(timeout: 15),
            "The visible Delegation surface did not appear in the Harness window"
        )
        HarnessRequirementEvidence.attachVisibleResult(of: window, to: self)
    }
}
