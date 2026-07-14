import XCTest

enum HarnessRequirementEvidence {
    static func parseBounds(_ value: String) -> CGRect? {
        let values = value.split(separator: ",").compactMap { Double($0) }
        guard values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    static func matchingWindowIndices(
        frames: [CGRect],
        expected: CGRect,
        tolerance: CGFloat = 4
    ) -> [Int] {
        frames.indices.filter { index in
            let frame = frames[index]
            return abs(frame.minX - expected.minX) <= tolerance
                && abs(frame.minY - expected.minY) <= tolerance
                && abs(frame.width - expected.width) <= tolerance
                && abs(frame.height - expected.height) <= tolerance
        }
    }

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
