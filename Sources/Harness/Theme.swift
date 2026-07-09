import SwiftUI
import CoreText
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Harness mac surfaces follow SAVY (`SAVY-iOS/SAVY/RootView.swift` `SavyTheme`): paper page, cream forms, crimson accents.
/// Recall tokens remain for legacy references.
enum Theme {
    // MARK: - SAVY

    static let savyDeepNavy = Color(hex: 0x08172D)
    static let savyCrimson = Color(hex: 0xE60E44)
    /// SAVY `SavyTheme.green` — live/leverage dot (`RootView.swift:1129`).
    static let savyGreen = Color(hex: 0x2AB860)
    static let savyCard = Color(hex: 0xF3EAD5)
    static let savyPaper = Color(hex: 0xF8F4ED)
    /// SAVY `SavyTheme.paperAccent` (`RootView.swift:1131` — 239/235/228).
    static let savyPaperAccent = Color(hex: 0xEFEBE4)
    /// SAVY `SavyTheme.beliefCard` (`RootView.swift:1132`).
    static let savyBeliefCard = Color(red: 0.96, green: 0.94, blue: 0.90)
    /// SAVY `SavyTheme.sectionBand` (`RootView.swift:1134` — 244/239/231).
    static let savySectionBand = Color(hex: 0xF4EFE7)
    /// SAVY `Brand.tabActive` — active tab label on tan (`ReminderBrandTheme.swift:24`).
    static let savyTabActive = Color(hex: 0x2E2716)
    static let savyBottomNavTan = Color(red: 0.80, green: 0.70, blue: 0.58)
    static let savySecondaryText = Color.black.opacity(0.62)
    static let savyTertiaryText = Color.black.opacity(0.45)

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

    // MARK: - macOS Harness (SAVY light — paper page, cream forms, crimson accents)

    /// Main content background (SAVY paper).
    static let macBg = savyPaper
    /// Primary text on paper surfaces.
    static let macInk = Color.black
    /// Cream entry / form surfaces (SAVY `Brand.card`).
    static let macEntry = savyCard
    /// Text on cream entry surfaces.
    static let macEntryInk = Color.black
    /// Bright cards on paper.
    static let macCardBright = Color.white
    /// Text on bright cards.
    static let macCardInk = Color.black
    /// Tan toolbar band (workbench views).
    static let macBarBg = savyBottomNavTan
    /// Text on tan toolbar.
    static let macBarInk = Color.black
    static let macHair = Color.black.opacity(0.08)
    static let macRed = savyCrimson
    static let macTan = savyBottomNavTan
    /// Placeholder on cream fields.
    static let macFaint = savyTertiaryText
    /// Muted text on paper.
    static let macMuted = savySecondaryText
    /// v6 mockup tokens (`--coolink`, `--coolbg`, `--warm` in the
    /// approved Blueprint mockup CSS) -- cool = locked/past/receded,
    /// warm = rated/done. Not in design-vocabulary.md because that file
    /// predates this mockup; these are the mockup's own literal hex
    /// values, not invented ones.
    static let macCoolInk = Color(hex: 0x5A6472)
    static let macCoolBg = Color(hex: 0xE7E8E6)
    static let macWarmCream = Color(hex: 0xF7E9CE)

    // Legacy suite tokens (delegation board, etc.)
    static let tan = recallTan
    static let navy = recallNearBlack
    static let red = recallCrimson
    static let blue = recallPrimaryBlue
    static let yellow = recallPrimaryYellow
    static let paper = recallPaper

    static let background = savyPaper
    static let accent = savyCrimson
    static let surface = savyCard

    static let statusLive = Color(red: 0.16, green: 0.72, blue: 0.35)
    static let statusPending = Color(red: 0.86, green: 0.45, blue: 0.12)

    // MARK: - Typography (Recall — desktop sizes, not phone hero scale)

    /// Same faces SAVY resolves (`SavyTypography`, SAVY-iOS): Bodoni 72 Oldstyle first, bundled Moda second.
    static let savyRecallSerifName = "Bodoni 72 Oldstyle"
    static let savyBodoniModaName = "BodoniModa-Regular"
    static let savyRobotoMediumName = "Roboto-Medium"

    /// One-time registration of the bundled display fonts so `Font.custom` can find them.
    /// `HarnessApp.init` also registers at launch; this static is the safety net for
    /// previews and tests where the App initializer never runs. Re-registering is harmless.
    private static let bundledFontsRegistered: Bool = {
        for resource in ["PlayfairDisplay", "BodoniModa-Regular", "Roboto-Medium"] {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()

    /// Whether a font family/PostScript name resolves on this platform (post-registration).
    static func savyFontAvailable(_ name: String) -> Bool {
        _ = bundledFontsRegistered
        #if canImport(AppKit)
        return NSFont(name: name, size: 12) != nil
        #elseif canImport(UIKit)
        return UIFont(name: name, size: 12) != nil
        #else
        return false
        #endif
    }

    /// SAVY's display-serif source, resolved once: Bodoni 72 Oldstyle → bundled BodoniModa → nil (system serif).
    private static let resolvedDisplaySerifName: String? = {
        if savyFontAvailable(savyRecallSerifName) { return savyRecallSerifName }
        if savyFontAvailable(savyBodoniModaName) { return savyBodoniModaName }
        return nil
    }()

    private static let robotoMediumAvailable: Bool = savyFontAvailable(savyRobotoMediumName)

    static func recallSerif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom("BodoniModa-Regular", size: size).weight(weight)
    }

    static func recallBody(_ size: CGFloat = 17, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func recallLabel(_ size: CGFloat = 14) -> Font {
        .system(size: size, weight: .heavy)
    }

    /// Editorial serif — SAVY's chain (`SavyTypography.displaySerif`):
    /// Bodoni 72 Oldstyle → bundled BodoniModa-Regular → system serif.
    static func savyDisplaySerif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        if let name = resolvedDisplaySerifName {
            return .custom(name, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    /// SAVY belief-list sans (`SavyTypography.robotoMedium`) — the bundled
    /// Roboto-Medium.ttf when registered, system medium otherwise.
    static func savyRobotoMedium(_ size: CGFloat) -> Font {
        if robotoMediumAvailable {
            return .custom(savyRobotoMediumName, size: size)
        }
        return .system(size: size, weight: .medium)
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