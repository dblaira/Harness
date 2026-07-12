import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct Options {
    let pid: pid_t
    let executable: String
    let identifier: String
    let output: String
}

func parseOptions() throws -> Options {
    let arguments = Array(CommandLine.arguments.dropFirst())
    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
    guard
        let pidText = value(after: "--pid"),
        let pid = pid_t(pidText),
        let executable = value(after: "--executable"),
        let identifier = value(after: "--identifier"),
        let output = value(after: "--output")
    else {
        throw NSError(domain: "HarnessRunningAppVerifier", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "usage: verify_running_app.swift --pid PID --executable PATH --identifier AX_ID --output FILE"
        ])
    }
    return Options(pid: pid, executable: executable, identifier: identifier, output: output)
}

func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }
    return value as? String
}

func hasIdentifier(
    _ element: AXUIElement,
    expected: String,
    remaining: inout Int,
    depth: Int = 0
) -> Bool {
    guard remaining > 0, depth < 30 else { return false }
    remaining -= 1
    if stringAttribute(element, kAXIdentifierAttribute as CFString) == expected {
        return true
    }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let children = value as? [AXUIElement] else {
        return false
    }
    return children.contains { child in
        hasIdentifier(child, expected: expected, remaining: &remaining, depth: depth + 1)
    }
}

struct WindowDescriptor {
    let id: CGWindowID
    let bounds: CGRect
}

func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 4) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance
        && abs(lhs.minY - rhs.minY) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}

func boundWindowID(
    visibleWindows: [WindowDescriptor],
    identifierWindowBounds: [CGRect]
) -> CGWindowID? {
    let matches = visibleWindows.filter { candidate in
        identifierWindowBounds.contains { approximatelyEqual(candidate.bounds, $0) }
    }
    return matches.count == 1 ? matches[0].id : nil
}

func visibleWindows(for pid: pid_t) -> [WindowDescriptor] {
    guard let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return []
    }
    return windows.compactMap { window in
        guard
            (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
            (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
            let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
            bounds.width >= 200,
            bounds.height >= 120
        else {
            return nil
        }
        return WindowDescriptor(id: windowID, bounds: bounds)
    }
}

func pointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard
          AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
}

func sizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard
          AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
}

func identifierWindowBounds(
    application: AXUIElement,
    identifier: String
) -> [CGRect] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return [] }
    return windows.compactMap { window in
        var budget = 10_000
        guard hasIdentifier(window, expected: identifier, remaining: &budget),
              let position = pointAttribute(window, kAXPositionAttribute as CFString),
              let size = sizeAttribute(window, kAXSizeAttribute as CFString),
              size.width >= 200,
              size.height >= 120 else { return nil }
        return CGRect(origin: position, size: size)
    }
}

do {
    if CommandLine.arguments.contains("--self-test-window-binding") {
        let front = WindowDescriptor(id: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let identified = WindowDescriptor(id: 2, bounds: CGRect(x: 900, y: 0, width: 700, height: 500))
        guard boundWindowID(
            visibleWindows: [front, identified],
            identifierWindowBounds: [identified.bounds]
        ) == identified.id else {
            throw NSError(domain: "HarnessRunningAppVerifier", code: 99, userInfo: [
                NSLocalizedDescriptionKey: "two-window binding regression failed"
            ])
        }
        let ambiguous = WindowDescriptor(id: 3, bounds: identified.bounds)
        guard boundWindowID(
            visibleWindows: [front, identified, ambiguous],
            identifierWindowBounds: [identified.bounds]
        ) == nil else {
            throw NSError(domain: "HarnessRunningAppVerifier", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "ambiguous window binding did not fail closed"
            ])
        }
        print("Two-window accessibility binding self-test passed.")
        exit(0)
    }
    let options = try parseOptions()
    guard let running = NSRunningApplication(processIdentifier: options.pid) else {
        throw NSError(domain: "HarnessRunningAppVerifier", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "candidate PID is not running"
        ])
    }
    guard running.bundleIdentifier == "com.adamblair.Harness" else {
        throw NSError(domain: "HarnessRunningAppVerifier", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "candidate PID has the wrong bundle identifier"
        ])
    }
    let actualExecutable = running.executableURL?.standardizedFileURL.path
    let expectedExecutable = URL(fileURLWithPath: options.executable).standardizedFileURL.path
    guard actualExecutable == expectedExecutable else {
        throw NSError(domain: "HarnessRunningAppVerifier", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "candidate PID is running a different executable"
        ])
    }

    let application = AXUIElementCreateApplication(options.pid)
    var reportedPID: pid_t = 0
    guard AXUIElementGetPid(application, &reportedPID) == .success, reportedPID == options.pid else {
        throw NSError(domain: "HarnessRunningAppVerifier", code: 6, userInfo: [
            NSLocalizedDescriptionKey: "Accessibility application PID does not match the candidate PID"
        ])
    }
    let identifierBounds = identifierWindowBounds(application: application, identifier: options.identifier)
    guard !identifierBounds.isEmpty else {
        throw NSError(domain: "HarnessRunningAppVerifier", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "candidate PID does not expose the contracted accessibility identifier"
        ])
    }
    let candidateWindows = visibleWindows(for: options.pid)
    guard let windowID = boundWindowID(
        visibleWindows: candidateWindows,
        identifierWindowBounds: identifierBounds
    ) else {
        throw NSError(domain: "HarnessRunningAppVerifier", code: 8, userInfo: [
            NSLocalizedDescriptionKey: "no unique visible candidate window contains the contracted accessibility identifier"
        ])
    }
    guard let boundWindow = candidateWindows.first(where: { $0.id == windowID }) else {
        throw NSError(domain: "HarnessRunningAppVerifier", code: 9, userInfo: [
            NSLocalizedDescriptionKey: "bound candidate window disappeared during verification"
        ])
    }

    let proof: [String: Any] = [
        "status": "PASS",
        "pid": Int(options.pid),
        "accessibility_pid": Int(reportedPID),
        "bundle_identifier": running.bundleIdentifier ?? "",
        "executable": actualExecutable ?? "",
        "accessibility_identifier": options.identifier,
        "window_id": Int(windowID),
        "window_bounds": [
            "x": boundWindow.bounds.origin.x,
            "y": boundWindow.bounds.origin.y,
            "width": boundWindow.bounds.size.width,
            "height": boundWindow.bounds.size.height,
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: options.output), options: .atomic)
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
