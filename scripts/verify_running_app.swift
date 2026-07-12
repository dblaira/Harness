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

func frontWindowID(for pid: pid_t) -> CGWindowID? {
    guard let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return nil
    }
    for window in windows {
        guard
            (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
            (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
            let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
            bounds.width >= 200,
            bounds.height >= 120
        else {
            continue
        }
        return windowID
    }
    return nil
}

do {
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
    var budget = 10_000
    guard hasIdentifier(application, expected: options.identifier, remaining: &budget) else {
        throw NSError(domain: "HarnessRunningAppVerifier", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "candidate PID does not expose the contracted accessibility identifier"
        ])
    }
    guard let windowID = frontWindowID(for: options.pid) else {
        throw NSError(domain: "HarnessRunningAppVerifier", code: 8, userInfo: [
            NSLocalizedDescriptionKey: "candidate PID has no visible application window"
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
    ]
    let data = try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: options.output), options: .atomic)
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
