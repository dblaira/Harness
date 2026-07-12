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

print("Accessibility and Screen Recording TCC preflight passed.")
