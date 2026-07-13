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
    let prepareOnly: Bool
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
        fail("usage: run_accessibility_contract.swift --pid PID --executable PATH --bundle-identifier ID --contract FILE [--output FILE | --prepare-only]", code: 2)
    }
    let prepareOnly = arguments.contains("--prepare-only")
    let output = value(after: "--output")
    if prepareOnly == (output != nil) {
        fail("choose exactly one of --prepare-only or --output FILE", code: 2)
    }
    return Options(
        pid: pid,
        executable: executable,
        bundleIdentifier: bundleIdentifier,
        contract: contract,
        output: output,
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

func findElement(
    in root: AXUIElement,
    identifier: String,
    remaining: inout Int,
    depth: Int = 0
) -> AXUIElement? {
    guard remaining > 0, depth < 30 else { return nil }
    remaining -= 1
    if stringAttribute(root, kAXIdentifierAttribute as CFString) == identifier {
        return root
    }
    for child in children(of: root) {
        if let match = findElement(in: child, identifier: identifier, remaining: &remaining, depth: depth + 1) {
            return match
        }
    }
    return nil
}

func element(in application: AXUIElement, identifier: String) -> AXUIElement? {
    var budget = 10_000
    return findElement(in: application, identifier: identifier, remaining: &budget)
}

func waitForElement(
    in application: AXUIElement,
    identifier: String,
    timeout: TimeInterval,
) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        let match = element(in: application, identifier: identifier)
        if let match { return match }
        pause(0.1)
    } while Date() < deadline
    return nil
}

func waitUntilAbsent(in application: AXUIElement, identifier: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if element(in: application, identifier: identifier) == nil { return true }
        pause(0.1)
    } while Date() < deadline
    return false
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

func execute(_ step: AutomationStep, application: AXUIElement) -> [String: Any] {
    let timeout = TimeInterval(step.timeout_seconds ?? 10)
    if step.action == "assert_not_present" {
        guard waitUntilAbsent(in: application, identifier: step.identifier, timeout: timeout) else {
            fail("accessibility identifier remained present: \(step.identifier)")
        }
        return ["action": step.action, "identifier": step.identifier, "status": "PASS"]
    }
    guard let target = waitForElement(in: application, identifier: step.identifier, timeout: timeout) else {
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

    var actionResults: [[String: Any]] = []
    for step in contract.ui_automation {
        let result = execute(step, application: application)
        guard result["target_pid"] == nil || result["target_pid"] as? Int == Int(options.pid) else {
            fail("a committed UI action escaped the exact candidate PID")
        }
        actionResults.append(result)
    }
    guard element(in: application, identifier: contract.final_accessibility_identifier) != nil else {
        fail("the final contracted accessibility identifier is not present")
    }
    let encodedSteps = try JSONEncoder().encode(contract.ui_automation)
    let contractActions = try JSONSerialization.jsonObject(with: encodedSteps)
    let proof: [String: Any] = [
        "schema_version": 1,
        "status": "PASS",
        "pid": Int(options.pid),
        "bundle_identifier": running.bundleIdentifier ?? "",
        "executable": running.executableURL?.standardizedFileURL.path ?? "",
        "final_accessibility_identifier": contract.final_accessibility_identifier,
        "contract_actions": contractActions,
        "action_results": actionResults,
    ]
    let outputData = try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
    try outputData.write(to: URL(fileURLWithPath: options.output!), options: .atomic)
} catch {
    fail(error.localizedDescription)
}
