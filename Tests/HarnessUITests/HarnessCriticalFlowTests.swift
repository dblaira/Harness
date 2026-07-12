import XCTest

final class HarnessCriticalFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSignedAppLaunchesItsVisibleDelegationSurface() throws {
        let app = XCUIApplication(bundleIdentifier: "com.adamblair.Harness")
        let environment = ProcessInfo.processInfo.environment
        let attachExisting = environment["HARNESS_ATTACH_EXISTING_APP"] == "1"
        if attachExisting {
            app.activate()
        } else {
            app.launch()
            app.activate()
        }

        let window = app.windows.firstMatch
        if !window.waitForExistence(timeout: 5) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(window.waitForExistence(timeout: 15), "Harness never exposed an accessible app window")

        let delegation = app.buttons["Delegation"]
        XCTAssertTrue(delegation.waitForExistence(timeout: 10), "The visible Delegation surface never appeared")

        HarnessRequirementEvidence.attachVisibleResult(of: window, to: self)
    }

}
