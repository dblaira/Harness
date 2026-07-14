import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct Options {
    let pid: pid_t
    let executable: String
    let bundleIdentifier: String
    let contract: String
    let output: String?
    let windowProof: String?
    let prepareOnly: Bool
}

struct WindowBounds: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var dictionary: [String: Double] { ["x": x, "y": y, "width": width, "height": height] }
}

struct RunningWindowProof: Decodable {
    let status: String
    let pid: Int
    let executable: String
    let window_id: Int
    let window_bounds: WindowBounds
}

struct Contract: Decodable {
    let ui_automation: [AutomationStep]
    let final_accessibility_identifier: String
}

struct AutomationStep: Decodable, Encodable, Equatable {
    let action: String
    let identifier: String
    let timeout_seconds: Int?
    let value: String?
}

func fail(_ message: String, code: Int = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(Int32(code))
}

func parseOptions() -> Options {
    let arguments = Array(CommandLine.arguments.dropFirst())
    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
    guard
        let pidText = value(after: "--pid"),
        let pid = pid_t(pidText), pid > 0,
        let executable = value(after: "--executable"),
        let bundleIdentifier = value(after: "--bundle-identifier"),
        let contract = value(after: "--contract")
    else {
        fail("usage: run_accessibility_contract.swift --pid PID --executable PATH --bundle-identifier ID --contract FILE [--output FILE --window-proof FILE | --prepare-only]", code: 2)
    }
    let prepareOnly = arguments.contains("--prepare-only")
    let output = value(after: "--output")
    let windowProof = value(after: "--window-proof")
    if prepareOnly == (output != nil) {
        fail("choose exactly one of --prepare-only or --output FILE", code: 2)
    }
    if prepareOnly == (windowProof != nil) {
        fail("--window-proof is required exactly when --output is used", code: 2)
    }
    return Options(
        pid: pid,
        executable: executable,
        bundleIdentifier: bundleIdentifier,
        contract: contract,
        output: output,
        windowProof: windowProof,
        prepareOnly: prepareOnly
    )
}

func pause(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? String
}

func children(of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
        return []
    }
    return value as? [AXUIElement] ?? []
}

func findElements(
    in root: AXUIElement,
    identifier: String,
    remaining: inout Int,
    depth: Int = 0,
    matches: inout [AXUIElement]
) {
    guard remaining > 0, depth < 30 else { return }
    remaining -= 1
    if stringAttribute(root, kAXIdentifierAttribute as CFString) == identifier {
        matches.append(root)
    }
    for child in children(of: root) {
        findElements(
            in: child,
            identifier: identifier,
            remaining: &remaining,
            depth: depth + 1,
            matches: &matches
        )
    }
}

func elements(in window: AXUIElement, identifier: String) -> [AXUIElement] {
    var budget = 10_000
    var matches: [AXUIElement] = []
    findElements(in: window, identifier: identifier, remaining: &budget, matches: &matches)
    return matches
}

func identifierMatchCountIsUnambiguous(_ count: Int) -> Bool {
    count <= 1
}

func waitForElement(
    in window: AXUIElement,
    identifier: String,
    timeout: TimeInterval,
) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        let matches = elements(in: window, identifier: identifier)
        if !identifierMatchCountIsUnambiguous(matches.count) {
            fail("accessibility identifier is ambiguous inside the bound window: \(identifier)")
        }
        if let match = matches.first { return match }
        pause(0.1)
    } while Date() < deadline
    return nil
}

func waitUntilAbsent(in window: AXUIElement, identifier: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if elements(in: window, identifier: identifier).isEmpty { return true }
        pause(0.1)
    } while Date() < deadline
    return false
}

func pointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
}

func sizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
}

func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 4) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance
        && abs(lhs.minY - rhs.minY) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}

func boundWindow(application: AXUIElement, proof: RunningWindowProof, options: Options) -> AXUIElement {
    guard proof.status == "PASS", proof.pid == Int(options.pid) else {
        fail("window proof is not bound to the exact candidate PID")
    }
    let expectedExecutable = URL(fileURLWithPath: options.executable).standardizedFileURL.path
    guard URL(fileURLWithPath: proof.executable).standardizedFileURL.path == expectedExecutable else {
        fail("window proof is bound to a different executable")
    }
    guard let visible = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        CGWindowID(proof.window_id)
    ) as? [[String: Any]], visible.contains(where: { item in
        (item[kCGWindowNumber as String] as? NSNumber)?.intValue == proof.window_id
            && (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == options.pid
            && (item[kCGWindowBounds as String] as? NSDictionary)
                .flatMap(CGRect.init(dictionaryRepresentation:))
                .map { approximatelyEqual($0, proof.window_bounds.rect) } == true
    }) else {
        fail("window proof no longer identifies the exact visible candidate window")
    }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        fail("candidate PID does not expose Accessibility windows")
    }
    let matches = windows.filter { window in
        guard let position = pointAttribute(window, kAXPositionAttribute as CFString),
              let size = sizeAttribute(window, kAXSizeAttribute as CFString) else { return false }
        return approximatelyEqual(CGRect(origin: position, size: size), proof.window_bounds.rect)
    }
    guard matches.count == 1 else {
        fail("window proof does not map to exactly one Accessibility window")
    }
    return matches[0]
}

func visibleWindowCount(for pid: pid_t) -> Int {
    guard let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else { return 0 }
    return windows.filter { window in
        (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
            && (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
            && ((window[kCGWindowBounds as String] as? NSDictionary)
                .flatMap(CGRect.init(dictionaryRepresentation:))?.width ?? 0) >= 200
    }.count
}

func sendNewWindow(to pid: pid_t) {
    guard
        let source = CGEventSource(stateID: .hidSystemState),
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 45, keyDown: true),
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 45, keyDown: false)
    else { return }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.postToPid(pid)
    keyUp.postToPid(pid)
}

func activateCandidate(_ running: NSRunningApplication, pid: pid_t) {
    _ = running.activate(options: [.activateAllWindows])
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if visibleWindowCount(for: pid) > 0 { return }
        pause(0.1)
    }
    sendNewWindow(to: pid)
    let newWindowDeadline = Date().addingTimeInterval(10)
    while Date() < newWindowDeadline {
        if visibleWindowCount(for: pid) > 0 { return }
        pause(0.1)
    }
    fail("the exact candidate PID did not expose a visible application window")
}

func verifyCandidate(options: Options) -> (NSRunningApplication, AXUIElement) {
    guard AXIsProcessTrusted() else {
        fail("the installed accessibility verifier lacks macOS Accessibility authority")
    }
    guard let running = NSRunningApplication(processIdentifier: options.pid) else {
        fail("candidate PID is not running")
    }
    guard running.bundleIdentifier == options.bundleIdentifier else {
        fail("candidate PID has the wrong bundle identifier")
    }
    let actualExecutable = running.executableURL?.standardizedFileURL.path
    let expectedExecutable = URL(fileURLWithPath: options.executable).standardizedFileURL.path
    guard actualExecutable == expectedExecutable else {
        fail("candidate PID is running a different executable")
    }
    let application = AXUIElementCreateApplication(options.pid)
    var reportedPID: pid_t = 0
    guard AXUIElementGetPid(application, &reportedPID) == .success, reportedPID == options.pid else {
        fail("Accessibility application PID does not match the exact candidate PID")
    }
    return (running, application)
}

func validate(_ contract: Contract) {
    guard !contract.ui_automation.isEmpty, contract.ui_automation.count <= 40 else {
        fail("the committed UI automation must contain 1 to 40 actions")
    }
    guard contract.ui_automation.first?.action == "wait_for" else {
        fail("the committed UI automation must begin with wait_for")
    }
    let allowed = Set(["wait_for", "press", "set_value", "assert_not_present"])
    for step in contract.ui_automation {
        guard allowed.contains(step.action), !step.identifier.isEmpty else {
            fail("the committed UI automation contains an unsupported action")
        }
        let timeout = step.timeout_seconds ?? 10
        guard (1...60).contains(timeout) else { fail("UI automation timeout is outside 1 to 60 seconds") }
        if step.action == "set_value" {
            guard let value = step.value, value.count <= 1000 else {
                fail("set_value requires a committed value no longer than 1000 characters")
            }
        } else if step.value != nil {
            fail("only set_value may contain a value")
        }
    }
}

func execute(
    _ step: AutomationStep,
    window: AXUIElement,
    options: Options,
    proof: RunningWindowProof
) -> [String: Any] {
    let timeout = TimeInterval(step.timeout_seconds ?? 10)
    if step.action == "assert_not_present" {
        guard waitUntilAbsent(in: window, identifier: step.identifier, timeout: timeout) else {
            fail("accessibility identifier remained present: \(step.identifier)")
        }
        return [
            "action": step.action,
            "identifier": step.identifier,
            "status": "PASS",
            "target_pid": Int(options.pid),
            "target_window_id": proof.window_id,
            "target_window_bounds": proof.window_bounds.dictionary,
        ]
    }
    guard let target = waitForElement(in: window, identifier: step.identifier, timeout: timeout) else {
        fail("accessibility identifier did not appear: \(step.identifier)")
    }
    var targetPID: pid_t = 0
    guard AXUIElementGetPid(target, &targetPID) == .success else {
        fail("could not bind the target element to a process")
    }
    let result: [String: Any] = [
        "action": step.action,
        "identifier": step.identifier,
        "status": "PASS",
        "target_pid": Int(targetPID),
        "target_window_id": proof.window_id,
        "target_window_bounds": proof.window_bounds.dictionary,
    ]
    switch step.action {
    case "wait_for":
        break
    case "press":
        guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else {
            fail("AXPress failed for accessibility identifier: \(step.identifier)")
        }
    case "set_value":
        guard let value = step.value,
              AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, value as CFTypeRef) == .success else {
            fail("AXValue assignment failed for accessibility identifier: \(step.identifier)")
        }
    default:
        fail("unsupported accessibility action")
    }
    return result
}

do {
    if CommandLine.arguments.contains("--self-test-window-scope") {
        guard identifierMatchCountIsUnambiguous(0),
              identifierMatchCountIsUnambiguous(1),
              !identifierMatchCountIsUnambiguous(2) else {
            fail("duplicate accessibility identifier regression failed", code: 99)
        }
        print("Exact-window duplicate identifier self-test passed.")
        exit(0)
    }
    let options = parseOptions()
    let data = try Data(contentsOf: URL(fileURLWithPath: options.contract))
    let contract = try JSONDecoder().decode(Contract.self, from: data)
    validate(contract)
    let (running, application) = verifyCandidate(options: options)
    activateCandidate(running, pid: options.pid)
    if options.prepareOnly {
        guard let first = contract.ui_automation.first,
              waitForElement(
                in: application,
                identifier: first.identifier,
                timeout: TimeInterval(first.timeout_seconds ?? 10)
              ) != nil else {
            fail("the first committed identifier did not appear in the exact candidate PID")
        }
        print("Exact candidate PID is active with a visible window.")
        exit(0)
    }

    let windowProofData = try Data(contentsOf: URL(fileURLWithPath: options.windowProof!))
    let windowProof = try JSONDecoder().decode(RunningWindowProof.self, from: windowProofData)
    let window = boundWindow(application: application, proof: windowProof, options: options)

    var actionResults: [[String: Any]] = []
    for step in contract.ui_automation {
        let result = execute(step, window: window, options: options, proof: windowProof)
        guard result["target_pid"] == nil || result["target_pid"] as? Int == Int(options.pid) else {
            fail("a committed UI action escaped the exact candidate PID")
        }
        actionResults.append(result)
    }
    let finalMatches = elements(in: window, identifier: contract.final_accessibility_identifier)
    guard finalMatches.count == 1 else {
        fail("the final contracted accessibility identifier is not present")
    }
    let encodedSteps = try JSONEncoder().encode(contract.ui_automation)
    let contractActions = try JSONSerialization.jsonObject(with: encodedSteps)
    let proof: [String: Any] = [
        "schema_version": 2,
        "status": "PASS",
        "pid": Int(options.pid),
        "bundle_identifier": running.bundleIdentifier ?? "",
        "executable": running.executableURL?.standardizedFileURL.path ?? "",
        "window_id": windowProof.window_id,
        "window_bounds": windowProof.window_bounds.dictionary,
        "final_accessibility_identifier": contract.final_accessibility_identifier,
        "contract_actions": contractActions,
        "action_results": actionResults,
    ]
    let outputData = try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
    try outputData.write(to: URL(fileURLWithPath: options.output!), options: .atomic)
} catch {
    fail(error.localizedDescription)
}
