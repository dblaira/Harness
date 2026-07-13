import Foundation

let domain = "com.apple.dt.Xcode" as CFString
let key = "IDEPackageSupportDisableManifestSandbox" as CFString
CFPreferencesSetAppValue(key, kCFBooleanTrue, domain)
guard CFPreferencesAppSynchronize(domain),
      let value = CFPreferencesCopyAppValue(key, domain) as? Bool,
      value else {
    fputs("Could not configure the isolated Xcode preference domain.\n", stderr)
    exit(1)
}
print("Configured nested Xcode manifest sandboxing for the outer confined build.")
