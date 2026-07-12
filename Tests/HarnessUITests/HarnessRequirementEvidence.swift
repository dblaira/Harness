import XCTest

enum HarnessRequirementEvidence {
    static func attachVisibleResult(
        of window: XCUIElement,
        to testCase: XCTestCase
    ) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "HARNESS_REQUIREMENT_VISIBLE_RESULT"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }
}
