import ApplicationServices
import CoreGraphics
import Foundation

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("Accessibility permission is not granted to the handoff process.\n".utf8))
    exit(1)
}

guard CGPreflightScreenCaptureAccess() else {
    FileHandle.standardError.write(Data("Screen Recording permission is not granted to the handoff process.\n".utf8))
    exit(1)
}

let session = CGSessionCopyCurrentDictionary() as? [String: Any]
let screenIsLocked = (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
guard !screenIsLocked else {
    FileHandle.standardError.write(Data("The Mac screen is locked; signed visible UI evidence requires Adam's active unlocked session.\n".utf8))
    exit(1)
}

print("Accessibility, Screen Recording, and unlocked-session preflight passed.")
