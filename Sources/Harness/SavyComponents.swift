import SwiftUI

/// SAVY design-parity components, ported faithfully from SAVY-iOS
/// (`RootView.swift`, `SavyReminderScreens.swift`, `ReminderFormView.swift`,
/// `SavyTypography.swift`) and adapted for macOS 14. Every name and value here
/// is recorded in `Docs/design-vocabulary.md` — if it is not in that file, it
/// is not used.

// MARK: - Typography helpers

/// SAVY `SavyTypography.timesNewRoman` (SavyTypography.swift:82-89) —
/// Times New Roman ships on both platforms; system serif is the fallback.
/// Used by the home leverage carousel titles and the featured quote.
enum SavyComponentTypography {
    static let timesNewRomanRegular = "TimesNewRomanPSMT"
    static let timesNewRomanBold = "TimesNewRomanPS-BoldMT"

    static func timesSerif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let usesBold = weight == .bold || weight == .heavy || weight == .semibold
        let name = usesBold ? timesNewRomanBold : timesNewRomanRegular
        if Theme.savyFontAvailable(name) {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - HeroHeader

/// SAVY hero header: display-serif wordmark with the crimson divider.
/// Navy variant matches the home hero (`EditorialHomeView.header`,
/// RootView.swift:270-305 — white wordmark 64, tan eyebrow, 3pt divider).
/// Paper variant matches the tab heroes (`SavyReminderKindTabScreen.hero`,
/// SavyReminderScreens.swift:89-103 — deep navy wordmark 48, crimson eyebrow,
/// 2pt divider).
struct SavyHeroHeader: View {
    enum Style {
        /// Deep navy hero — white wordmark, tan eyebrow, 3pt crimson divider.
        case onNavy
        /// White hero — deep navy wordmark, crimson eyebrow, 2pt crimson divider.
        case onPaper
    }

    let title: String
    var eyebrow: String?
    var style: Style = .onNavy
    /// SAVY heroes run 48 (tab heroes) to 64 (home wordmark); clamped to that range.
    var titleSize: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.savyDisplaySerif(min(max(titleSize, 48), 64), weight: .bold))
                .foregroundStyle(style == .onNavy ? .white : Theme.savyDeepNavy)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            if let eyebrow, !eyebrow.isEmpty {
                Text(eyebrow)
                    .font(.system(size: style == .onNavy ? 20 : 18, weight: .heavy))
                    .foregroundStyle(style == .onNavy ? Theme.savyBottomNavTan : Theme.savyCrimson)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .background(style == .onNavy ? Theme.savyDeepNavy : .white)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.savyCrimson)
                .frame(height: style == .onNavy ? 3 : 2)
        }
    }
}

// MARK: - EyebrowBand

/// SAVY band label (`SavyReminderKindTabScreen.activeBand`,
/// SavyReminderScreens.swift:105-116): ALL CAPS 15pt heavy, tracking 2.5,
/// tan on deep navy, optional trailing count in white @45%.
struct SavyEyebrowBand: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title)
                .font(.system(size: 15, weight: .heavy))
                .tracking(2.5)
                .textCase(.uppercase)
                .foregroundStyle(Theme.savyBottomNavTan)

            Spacer(minLength: 0)

            if let count {
                Text("\(count)")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.savyDeepNavy)
    }
}

// MARK: - Card species

/// SAVY home leverage carousel card (`HomeLeverageCardView`,
/// RootView.swift:537-568): white 12pt-radius card, tracked eyebrow,
/// Times New Roman title, tracked footer count.
struct SavyLeverageCard: View {
    let eyebrow: String
    let title: String
    /// e.g. `"4 ITEMS"` — rendered in the tracked footer label style.
    var footer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            Text(eyebrow)
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundStyle(Theme.savySecondaryText)

            Text(title)
                .font(SavyComponentTypography.timesSerif(24))
                .lineSpacing(3)
                .foregroundStyle(.black)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.savyTertiaryText)
            }
        }
        .padding(.top, 28)
        .padding(.horizontal, 30)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }
}

/// SAVY pinned story card (`NewsPinnedStoryCard`, RootView.swift:661-681):
/// cream 12pt-radius card, display-serif title, semibold summary; optional
/// crimson kicker per `NewsMoreStoryRow` (RootView.swift:742-747). No shadow —
/// cream cards sit flat on paper.
struct SavyStoryCard: View {
    var kicker: String?
    let title: String
    var summary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let kicker, !kicker.isEmpty {
                Text(kicker)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.savyCrimson)
            }

            Text(title)
                .font(Theme.savyDisplaySerif(25))
                .foregroundStyle(.black)
                .fixedSize(horizontal: false, vertical: true)

            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 15, weight: .semibold))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.savySecondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(Theme.savyCard, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// SAVY featured principle card (`EditorialHomeView.principleCard`,
/// RootView.swift:354-382): white 8pt-radius card, 4×74 crimson bar, quote in
/// Times New Roman with curly quotes, tracked attribution eyebrow.
struct SavyQuoteCard: View {
    let quote: String
    /// SAVY uses `"FEATURED SIGNAL"` (design-vocabulary band label).
    var attribution: String = "FEATURED SIGNAL"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Theme.savyCrimson)
                    .frame(width: 4, height: 74)

                Text("\u{201C}\(quote)\u{201D}")
                    .font(SavyComponentTypography.timesSerif(22))
                    .lineSpacing(3)
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(attribution)
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundStyle(Theme.savyTertiaryText)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
    }
}

/// SAVY dark band card (`SavyReminderBandCard`, SavyReminderScreens.swift:566-624):
/// near-black 8pt-radius card with tracked kind badge, display-serif title,
/// 36×2 accent rule, bold detail line, and a white @8% hairline stroke.
struct SavyDarkCard: View {
    var badge: String?
    var badgeIcon: String?
    let title: String
    var detail: String?
    /// SAVY rotates `.white` / `Brand.darkRed` / tan; near-black is the default dark card.
    var background: Color = Theme.recallNearBlack
    var foreground: Color = .white
    var accent: Color = Theme.savyCrimson

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if badge != nil || badgeIcon != nil {
                HStack(spacing: 6) {
                    if let badgeIcon {
                        Image(systemName: badgeIcon)
                            .font(.system(size: 11, weight: .bold))
                    }
                    if let badge, !badge.isEmpty {
                        Text(badge)
                            .font(.system(size: 11, weight: .heavy))
                            .tracking(1.5)
                            .textCase(.uppercase)
                    }
                }
                .foregroundStyle(foreground.opacity(0.7))
            }

            Text(title)
                .font(Theme.savyDisplaySerif(26, weight: .regular))
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)

            Rectangle()
                .fill(accent)
                .frame(width: 36, height: 2)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(foreground.opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))
    }
}

// MARK: - LockedInToast

/// SAVY save confirmation (`ReminderFormView.savedToast`,
/// ReminderFormView.swift:101-114): dimmed backdrop, white 22pt-radius panel,
/// crimson checkmark, serif message. Overlay it and toggle briefly:
/// `.overlay { if showSaved { SavyLockedInToast() } }`.
struct SavyLockedInToast: View {
    /// Default is the suite save toast copy (design-vocabulary: `"Locked In"`).
    var message: String = "Locked In"
    var systemImage: String = "checkmark.circle.fill"

    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 46))
                    .foregroundStyle(Theme.recallCrimson)
                Text(message)
                    .font(Theme.savyDisplaySerif(30))
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.2), radius: 28, y: 12)
        }
        .transition(.opacity)
    }
}

// MARK: - TagChip

/// SAVY tag capsule (`ReminderFormView` tags row, ReminderFormView.swift:316-325):
/// 15pt semibold label on a light-gray capsule with an optional remove button.
struct SavyTagChip: View {
    let tag: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove \(tag)")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(Color(white: 0.92))
        .clipShape(Capsule())
    }
}

// MARK: - v6 ink (WO-H: PLAN-blueprint-cockpit-v1.md)

/// The Blueprint cockpit's Benday-dot halftone ground, for the Step
/// Rail's tan band. A fixed offset-row dot grid, rasterized once via
/// `.drawingGroup()` so resizing/scrolling doesn't repaint per-dot.
/// Motion-free — texture, not animation.
struct SavyBendayGround: View {
    var dotColor: Color = Theme.macInk
    var dotOpacity: Double = 0.06
    var spacing: CGFloat = 9
    var dotDiameter: CGFloat = 2
    /// Adam's memo 21: "give them larger in some area and smaller in
    /// some other areas so it kind of feels like this waving gradient
    /// effect ... not going to be really pronounced." A slow sine field
    /// swells dot size (and a touch of ink) across the plane. Still
    /// motion-free -- texture, not animation.
    var waves: Bool = false

    var body: some View {
        Canvas { context, size in
            let columns = Int(size.width / spacing) + 2
            let rows = Int(size.height / spacing) + 2
            let flatShading = GraphicsContext.Shading.color(dotColor.opacity(dotOpacity))
            for row in 0..<rows {
                let rowOffset = row.isMultiple(of: 2) ? 0 : spacing / 2
                for column in 0..<columns {
                    let cx = CGFloat(column) * spacing + rowOffset
                    let cy = CGFloat(row) * spacing
                    var diameter = dotDiameter
                    var shading = flatShading
                    if waves {
                        let swell = sin(cx * 0.012) * cos(cy * 0.015)
                        diameter = dotDiameter * (1 + 0.45 * swell)
                        shading = GraphicsContext.Shading.color(
                            dotColor.opacity(dotOpacity * (1 + 0.3 * swell))
                        )
                    }
                    let dot = Path(ellipseIn: CGRect(
                        x: cx - diameter / 2, y: cy - diameter / 2,
                        width: diameter, height: diameter
                    ))
                    context.fill(dot, with: shading)
                }
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

/// The ONE breathing dot the v6 mockup allows — a live pulse, never
/// decoration sprinkled across the screen. `TimelineView` keeps time
/// without a `Timer`; freezes to a still dot when Reduce Motion is on.
struct SavyBreathingDot: View {
    var color: Color = Theme.savyGreen
    var diameter: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0.5 : Self.breathingPhase(at: timeline.date)
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
                .opacity(0.55 + 0.45 * phase)
                .scaleEffect(0.85 + 0.3 * phase)
        }
    }

    private static func breathingPhase(at date: Date) -> Double {
        let period = 2.4
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return (sin(t * 2 * .pi) + 1) / 2
    }
}

/// The ledger's tilt lives in this background trapezoid only — WO-M's
/// row content must stay un-tilted and legible. Never
/// `rotation3DEffect` on a data table; lean the card, not the numbers.
struct SavyLedgerTiltBackground: Shape {
    var skew: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + skew, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - skew, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Previews

#Preview("Hero headers") {
    VStack(spacing: 0) {
        SavyHeroHeader(title: "Harness", eyebrow: "The Adam Pattern", style: .onNavy, titleSize: 64)
        SavyHeroHeader(title: "Reminders", eyebrow: "What matters next.", style: .onPaper)
    }
    .frame(width: 480)
    .background(Theme.savyPaper)
}

#Preview("Eyebrow band") {
    VStack(spacing: 0) {
        SavyEyebrowBand(title: "UP NEXT", count: 3)
        SavyEyebrowBand(title: "PRIORITY")
    }
    .frame(width: 480)
    .background(Theme.savyDeepNavy)
}

#Preview("Card species") {
    ScrollView {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                SavyLeverageCard(eyebrow: "NEWS CHANNEL", title: "News Channel", footer: "4 ITEMS")
                    .frame(width: 220, height: 200)
                SavyQuoteCard(quote: "Start with the move already shaped.")
                    .frame(width: 282)
            }

            SavyStoryCard(
                kicker: "VALIDATED PRINCIPLE",
                title: "The map of leverage.",
                summary: "Principles worth keeping close."
            )

            SavyDarkCard(
                badge: "REMINDER",
                badgeIcon: "clock",
                title: "Choose the move that matters.",
                detail: "Due Today"
            )
        }
        .padding(24)
    }
    .frame(width: 600, height: 620)
    .background(Theme.savyPaper)
}

#Preview("Locked In toast") {
    Theme.savyPaper
        .frame(width: 480, height: 360)
        .overlay { SavyLockedInToast() }
}

#Preview("Tag chips") {
    HStack(spacing: 6) {
        SavyTagChip(tag: "Leverage")
        SavyTagChip(tag: "Health", onRemove: {})
    }
    .padding(24)
    .background(Theme.savyPaper)
}

#Preview("v6 ink") {
    VStack(spacing: 20) {
        ZStack {
            Theme.macTan.opacity(0.35)
            SavyBendayGround()
        }
        .frame(height: 80)

        HStack(spacing: 8) {
            SavyBreathingDot()
            Text("live").font(.caption.weight(.bold))
        }

        SavyLedgerTiltBackground()
            .fill(Theme.recallNearBlack)
            .frame(height: 60)
    }
    .padding(24)
    .background(Theme.savyPaper)
}
