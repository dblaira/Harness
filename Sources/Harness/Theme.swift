import SwiftUI

/// Notorious Recall palette — canonical source: `Re_Call/ios/ReCall/App/Theme.swift` (`Brand`).
/// Page surfaces are deep navy; entry forms are cream; tan band + crimson accents.
enum Theme {
    // MARK: - Notorious Recall (Brand)

    static let recallPage = Color(hex: 0x0A1626)
    static let recallCard = Color(hex: 0xF3EAD5)
    static let recallTan = Color(hex: 0xD5C194)
    static let recallCrimson = Color(hex: 0xDC143C)
    static let recallDarkRed = Color(hex: 0xB00124)
    static let recallNearBlack = Color(hex: 0x0C1E33)
    static let recallBlue = Color(hex: 0x021784)
    static let recallCyan = Color(hex: 0x0C8A92)
    static let recallPrimaryBlue = Color(hex: 0x1D4ED8)
    static let recallPrimaryYellow = Color(hex: 0xF4C400)
    static let recallPrimaryGreen = Color(hex: 0x1E9E57)
    static let recallPaper = Color.white

    // MARK: - macOS Harness (maps Recall tokens to workbench surfaces)

    /// Main content background (navy page).
    static let macBg = recallPage
    /// Primary text on navy surfaces.
    static let macInk = Color.white
    /// Cream entry / form surfaces (Recall `Brand.card`).
    static let macEntry = recallCard
    /// Text on cream entry surfaces.
    static let macEntryInk = Color.black
    /// Bright answer cards (Recall Up Next #1).
    static let macCardBright = recallPaper
    /// Text on bright cards.
    static let macCardInk = recallNearBlack
    /// Tan toolbar band (Recall hero).
    static let macBarBg = recallTan
    /// Text on tan toolbar.
    static let macBarInk = recallNearBlack
    static let macHair = recallTan.opacity(0.55)
    static let macRed = recallCrimson
    static let macTan = recallTan
    /// Placeholder on cream fields.
    static let macFaint = Color.black.opacity(0.42)
    /// Muted text on navy.
    static let macMuted = Color.white.opacity(0.58)

    // Legacy suite tokens (delegation board, etc.)
    static let tan = recallTan
    static let navy = recallNearBlack
    static let red = recallCrimson
    static let blue = recallPrimaryBlue
    static let yellow = recallPrimaryYellow
    static let paper = recallPaper

    static let background = recallPage
    static let accent = recallCrimson
    static let surface = recallCard

    static let savyDeepNavy = Color(hex: 0x08172D)
    static let savyCrimson = Color(hex: 0xE60E44)
    static let savyCard = recallCard
    static let savyPaper = Color(hex: 0xF8F4ED)
    static let savyPaperAccent = Color(hex: 0xEFE7D6)
    static let savyBottomNavTan = Color(red: 0.80, green: 0.70, blue: 0.58)
    static let savySecondaryText = Color.black.opacity(0.62)
    static let savyTertiaryText = Color.black.opacity(0.45)

    static let statusLive = Color(red: 0.16, green: 0.72, blue: 0.35)
    static let statusPending = Color(red: 0.86, green: 0.45, blue: 0.12)

    // MARK: - Typography (Recall — desktop sizes, not phone hero scale)

    static func recallSerif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom("BodoniModa-Regular", size: size).weight(weight)
    }

    static func recallBody(_ size: CGFloat = 17, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func recallLabel(_ size: CGFloat = 14) -> Font {
        .system(size: size, weight: .heavy)
    }

    static func savyDisplaySerif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        recallSerif(size, weight: weight)
    }

    static func savyRobotoMedium(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium)
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}