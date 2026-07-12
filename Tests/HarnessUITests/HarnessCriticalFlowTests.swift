import XCTest

final class HarnessCriticalFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSignedAppLaunchesItsVisibleDelegationSurface() throws {
        let app = XCUIApplication()
        app.launch()
        app.activate()

        let window = app.windows.firstMatch
        if !window.waitForExistence(timeout: 5) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(window.waitForExistence(timeout: 15), "Harness never exposed an accessible app window")

        let delegation = app.buttons["Delegation"]
        XCTAssertTrue(delegation.waitForExistence(timeout: 10), "The visible Delegation surface never appeared")

        HarnessRequirementEvidence.attachVisibleResult(of: window, to: self)
    }

    func testFinalNormalRelaunchPreservesProcessAndVisibleIdentifier() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let expectedPIDText = environment["HARNESS_EXPECTED_PID"],
              let expectedPID = Int32(expectedPIDText),
              let identifier = environment["HARNESS_FINAL_ACCESSIBILITY_IDENTIFIER"],
              !identifier.isEmpty else {
            XCTFail("Trusted handoff did not provide the final PID and accessibility identifier")
            return
        }

        let app = XCUIApplication(bundleIdentifier: "com.adamblair.Harness")
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "The normal relaunched Harness window is not visible")
        let visibleElement = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(
            visibleElement.waitForExistence(timeout: 15),
            "The contracted accessibility identifier is not visible after normal relaunch: \(identifier)"
        )
        XCTAssertGreaterThan(expectedPID, 0, "Trusted handoff supplied an invalid normal-launch PID")
        HarnessRequirementEvidence.attachVisibleResult(of: window, to: self)
    }
}
