import XCTest

final class HarnessCriticalFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSignedAppLaunchesItsVisibleDelegationSurface() throws {
        let app = XCUIApplication(bundleIdentifier: "com.adamblair.Harness")
        let environment = ProcessInfo.processInfo.environment
        let attachExisting = environment["HARNESS_ATTACH_EXISTING_APP"] == "1"
        guard let expectedPID = Int(environment["HARNESS_EXPECTED_PID"] ?? ""), expectedPID > 0 else {
            XCTFail("HARNESS_EXPECTED_PID must name the exact candidate process")
            return
        }
        guard let expectedBounds = HarnessRequirementEvidence.parseBounds(
            environment["HARNESS_EXPECTED_WINDOW_BOUNDS"] ?? ""
        ) else {
            XCTFail("HARNESS_EXPECTED_WINDOW_BOUNDS must name the exact evidence window")
            return
        }
        if attachExisting {
            app.activate()
        } else {
            app.launch()
            app.activate()
        }

        if !app.windows.firstMatch.waitForExistence(timeout: 5) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "Harness never exposed an accessible app window")

        let expectedSynthetic = CGRect(x: 100, y: 80, width: 900, height: 700)
        XCTAssertEqual(
            HarnessRequirementEvidence.matchingWindowIndices(
                frames: [CGRect(x: 0, y: 0, width: 500, height: 500), expectedSynthetic],
                expected: expectedSynthetic
            ),
            [1]
        )
        XCTAssertEqual(
            HarnessRequirementEvidence.matchingWindowIndices(
                frames: [expectedSynthetic, expectedSynthetic],
                expected: expectedSynthetic
            ).count,
            2,
            "Ambiguous same-bounds windows must not be accepted as unique"
        )

        let windows = app.windows
        let indices = HarnessRequirementEvidence.matchingWindowIndices(
            frames: (0..<windows.count).map { windows.element(boundBy: $0).frame },
            expected: expectedBounds
        )
        XCTAssertEqual(indices.count, 1, "Exactly one XCUITest window must match the recorded evidence bounds")
        guard let index = indices.first else { return }
        let window = windows.element(boundBy: index)
        let processMarker = window.descendants(matching: .any)["HarnessProcess-\(expectedPID)"]
        XCTAssertTrue(processMarker.waitForExistence(timeout: 10), "The evidence window is not owned by HARNESS_EXPECTED_PID")

        let delegation = window.buttons["Delegation"]
        XCTAssertTrue(delegation.waitForExistence(timeout: 10), "The visible Delegation surface never appeared")

        HarnessRequirementEvidence.attachVisibleResult(of: window, to: self)
    }

}
