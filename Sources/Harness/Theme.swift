import SwiftUI

/// Notorious color scheme — pulled from the app screenshot.
/// Plain names on the left, exact hex on the right.
enum Theme {
    static let tan    = Color(hex: 0xD8C49A)  // header background
    static let navy   = Color(hex: 0x0E1B2A)  // dark panel / text
    static let red    = Color(hex: 0xC8102E)  // accent / action
    static let blue   = Color(hex: 0x2E5BFF)  // reminder card
    static let yellow = Color(hex: 0xF5C518)  // reminder card
    static let paper  = Color(hex: 0xFFFFFF)  // white card

    static let background = navy
    static let accent     = red
    static let surface    = paper

    // macOS subtle palette — low-contrast, privacy-friendly indoors.
    static let macBg      = Color(hex: 0x0E1B2A)  // navy everywhere
    static let macInk     = Color(hex: 0xC9B79A)  // light brown text
    static let macEntry   = Color(hex: 0x2A2E35)  // grey entry box
    static let macHair    = Color(hex: 0x4A5568).opacity(0.4)  // faint grey hairline
    static let macRed     = Color(hex: 0xC8102E)  // sidebar lettering
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
