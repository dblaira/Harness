#if os(macOS)
import AppKit
import SwiftUI
import OntologyKit
import UniformTypeIdentifiers

/// Shell for the v6-mockup cockpit screen (WO-F/WO-G/WO-H/WO-I). Five
/// regions per docs/design-brief-ios-workbench.md: Step Rail, Sources
/// pool, Delegate composer, Organize, Ledger strip -- plus the
/// FASCINATION carousel, added later directly under the Step Rail
/// (Adam, verbatim: "I could envision another layer below the Adam
/// Pattern boxes... a carousel feature may be the answer to how it's
/// presented"). The Step Rail is live, bound to PatternGateChecker
/// (fail-closed), and carries the v6 ink (Benday tan band, crimson
/// contours, cornerRadius 0, one breathing dot). The four original
/// placeholder regions stay plain scaffolding until their own work
/// orders — the ink is not yet a whole-screen retrofit. No local copy
/// of the v6 mockup artifact exists in this repo to diff against
/// pixel-for-pixel; this is a mechanical read of the written spec.
struct MacBlueprintView: View {
    @ObservedObject var model: MacWorkbenchModel

    /// The mockup's one real click-interaction (its `#rail .cell` ->
    /// `#loop .stage` script): tapping a Step Rail cell jumps to and
    /// highlights its matching detail card in `loopSection` below. Adam,
    /// after we shipped a static rail: "it actually had interactivity to
    /// it" — this was the missing piece.
    @State private var highlightedStepID: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    stepRail(jumpTo: { stepID in
                        highlightedStepID = stepID
                        withAnimation(.easeInOut(duration: 0.4)) {
                            proxy.scrollTo(stepID, anchor: .top)
                        }
                    })
                    loopSection
                    fascinationCarousel
                    blueprintSection(title: "Sources", icon: "tray") {
                        sourcesPool
                    }
                    blueprintSection(title: "Delegate", icon: "text.cursor") {
                        placeholderNote("The three fields (Intent/PreferredApproach/DoneCondition) are live in the Chat composer (WO-J) — embedding them here is still open.")
                    }
                    blueprintSection(title: "Organize", icon: "square.stack.3d.up") {
                        VStack(alignment: .leading, spacing: 8) {
                            mindMapTree
                            placeholderNote("Slide Deck / Audio are still open — read-only Mind Map tree only, per the plan (\"navigation takeover only after it survives daily use\").")
                        }
                    }
                    blueprintSection(title: "Ledger", icon: "chart.bar") {
                        fleetLedger
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    Theme.macBg
                    // Mockup: `.canvas{background-image:radial-gradient(rgba(8,23,45,.09)...)}`
                    // -- a faint navy dot field across the whole canvas, not
                    // just the Step Rail band.
                    SavyBendayGround(dotColor: Theme.savyDeepNavy, dotOpacity: 0.09, spacing: 10, dotDiameter: 2.2)
                }
            }
            .task { await model.refreshPatternGate() }
            .task { model.refreshFascinationCards() }
            .task { await model.refreshFleetLedger() }
            .task { model.refreshSourcePool() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blueprint")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(Theme.macInk)

            Text("Shell only — the sources pool, composer, organize panel, and ledger arrive in later work orders.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.macInk.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
    }

    // MARK: - Step Rail (WO-G gate wiring, WO-H ink)

    /// The Step Rail's own container, not the shared `blueprintSection`:
    /// tan band + Benday ground per the design brief ("Step Rail (top,
    /// tan band)"), crimson 2.5pt contour, cornerRadius 0 — the v6
    /// mechanical pass. The other four regions keep the plain scaffold
    /// treatment until their own work orders reach them.
    private func stepRail(jumpTo: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.number")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.macRed)
                    .frame(width: 16)
                Text("Step Rail")
                    .font(.system(size: 13).weight(.bold))
                    .foregroundStyle(Theme.macInk.opacity(0.78))
                Spacer()
                Text("tap a step to jump to it below")
                    .font(.caption2)
                    .foregroundStyle(Theme.macInk.opacity(0.4))
            }

            gateStatusLine

            HStack(alignment: .top, spacing: 8) {
                ForEach(observationalSteps) { step in
                    PatternObservationalCell(
                        step: step,
                        rating: model.patternGateState.ratings[step.id],
                        onSubmit: { rating, note in
                            model.submitPatternRating(step: step.id, rating: rating, evidenceNote: note)
                        }
                    )
                    // Only jump once the cell is display-only (rated) --
                    // a tap gesture over the live Stepper/TextField/Button
                    // form would steal taps meant for those controls.
                    .onTapGesture {
                        if model.patternGateState.ratings[step.id] != nil { jumpTo(step.id) }
                    }
                }
            }

            HStack(alignment: .top, spacing: 8) {
                ForEach(executionSteps) { step in
                    PatternExecutionCell(step: step, unlocked: model.patternGateState.executionUnlocked)
                        .onTapGesture { jumpTo(step.id) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Theme.macTan.opacity(0.30)
                SavyBendayGround()
            }
        }
        .clipShape(Rectangle())
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 2.5))
    }

    // MARK: - The loop (jump target for Step Rail taps)

    /// Mockup's `#loop .stage` cards -- the mockup's own copy, ported
    /// verbatim from the approved v6 artifact, not written fresh here.
    /// Two rows of four, same 1/2/3/4 + 5/6/7/8 split as the rail above.
    private var loopSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.macRed.opacity(0.9))
                    .frame(width: 16)
                Text("The loop")
                    .font(.system(size: 13).weight(.bold))
                    .foregroundStyle(Theme.macInk.opacity(0.78))
                Spacer()
            }
            Text("SPEAK SENTENCES · RATE FOUR NUMBERS · PRESS CONTINUE — THAT IS THE WHOLE JOB")
                .font(.system(size: 10).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(Theme.macInk.opacity(0.4))

            HStack(alignment: .top, spacing: 8) {
                ForEach(observationalSteps) { step in
                    LoopStepDetailCard(step: step, detail: LoopStepCopy.detail(for: step.id), highlighted: highlightedStepID == step.id)
                        .id(step.id)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(executionSteps) { step in
                    LoopStepDetailCard(step: step, detail: LoopStepCopy.detail(for: step.id), highlighted: highlightedStepID == step.id)
                        .id(step.id)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
    }

    // MARK: - FASCINATION carousel (WO-I)

    private var fascinationCarousel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "quote.opening")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.macRed.opacity(0.9))
                    .frame(width: 16)
                Text("Fascinations")
                    .font(.system(size: 13).weight(.bold))
                    .foregroundStyle(Theme.macInk.opacity(0.78))
                Spacer()
                Button {
                    model.refreshFascinationCards()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.macInk.opacity(0.5))
                .help("Re-scan ~/Documents/Harness/Fascinations")
            }

            if model.fascinationCards.isEmpty {
                placeholderNote("Drop a quote .md file in ~/Documents/Harness/Fascinations — its body becomes the card, verbatim.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(Array(model.fascinationCards.enumerated()), id: \.element.id) { index, card in
                            SavyQuoteCard(quote: card.quote, attribution: attributionLine(for: card))
                                .frame(width: 260)
                                .rotationEffect(.degrees(fascinationTilt(for: index)))
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
    }

    /// WO-I calls for +/-2-4 degree tilts, cycling for an organic,
    /// hand-placed feel rather than one repeated angle.
    private func fascinationTilt(for index: Int) -> Double {
        let magnitude = 2.0 + Double(index % 3)
        return index.isMultiple(of: 2) ? magnitude : -magnitude
    }

    /// "his own captured observations dated and attributed to ADAM" —
    /// an external source (a book, a paper) just names itself.
    private func attributionLine(for card: FascinationCard) -> String {
        guard card.attribution == "ADAM" else { return card.attribution }
        return "ADAM · \(Self.fascinationDisplayDateFormatter.string(from: card.date))"
    }

    private static let fascinationDisplayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    // MARK: - Mind Map, read-only (WO-O)

    /// Read-only tree first -- "navigation takeover only after it
    /// survives daily use" (the plan's own words). Extends the
    /// treeColumn pattern (MacCockpitView.swift) with the one status
    /// distinction the data model actually has today: is this row the
    /// same top-priority row the UP NEXT card shows (warm), or not
    /// (cool, receded to 45% ink -- same treatment WO-H's locked Step
    /// Rail cells use, no new color invented outside the vocabulary).
    private var mindMapTree: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mindMapGroups.isEmpty {
                placeholderNote("No delegation items yet — the tree fills in as the queue does.")
            } else {
                ForEach(mindMapGroups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.macInk.opacity(0.4))
                            Text(group.app.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.macInk.opacity(0.6))
                        }
                        ForEach(group.rows) { row in
                            mindMapNode(row)
                        }
                    }
                }
            }
        }
    }

    private var mindMapGroups: [OpportunityBoardAppGroup] {
        OpportunityBoardProjection(rows: model.opportunityBoardRows).groupsByApp()
    }

    /// The same top-priority row the UP NEXT card starts locked onto
    /// (MacChatView.upNextRowID) -- computed independently here since
    /// this view has no access to that screen's local @State. Matches
    /// in the common case; can diverge only if UP NEXT stays locked
    /// onto a row that's since fallen out of the top spot.
    private var mindMapWarmRowID: String? {
        OpportunityBoardProjection(rows: model.opportunityBoardRows).rows.first?.id
    }

    private func mindMapNode(_ row: OpportunityBoardRow) -> some View {
        let isWarm = row.id == mindMapWarmRowID
        let title = row.card.envelope.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 5) {
            Circle()
                .fill(isWarm ? Theme.macRed : Theme.macInk.opacity(0.3))
                .frame(width: 5, height: 5)
            Text(title?.isEmpty == false ? title! : row.id)
                .font(.system(size: 10, weight: isWarm ? .semibold : .regular))
                .foregroundStyle(isWarm ? Theme.macInk : Theme.macInk.opacity(0.45))
                .lineLimit(1)
        }
        .padding(.leading, 14)
    }

    // MARK: - Sources pool (WO-N)

    /// Unlabeled by design -- no title field, no folder picker.
    /// "Capture-from-anywhere" for v1 is the watched Delegations folder
    /// (a Shortcut can share into it from iPhone) plus this in-app
    /// drop/paste; a real Share Extension is v2, per the plan.
    private var sourcesPool: some View {
        Group {
            if model.sourcePoolCards.isEmpty {
                placeholderNote("Paste a link or drop a file here — recognition-only, no names, no folders.")
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 84), spacing: 14)], spacing: 14) {
                    ForEach(Array(model.sourcePoolCards.enumerated()), id: \.element.contentHash) { index, card in
                        sourcePoolCell(card, index: index)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Theme.macEntry.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.macHair, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .dropDestination(for: URL.self) { items, _ in
            guard !items.isEmpty else { return false }
            for url in items {
                if url.isFileURL {
                    model.captureSourcePoolFile(url)
                } else {
                    model.captureSourcePoolLink(url)
                }
            }
            return true
        }
        .onPasteCommand(of: [.url, .plainText]) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        model.captureSourcePoolLink(url)
                    }
                }
            }
        }
    }

    /// Mockup: `.pc:nth-child(3n){rotate(3deg)}`,
    /// `.pc:nth-child(3n+1){rotate(-2.6deg)}`,
    /// `.pc:nth-child(3n+2){rotate(1.6deg) translateY(4px)}` -- a
    /// 3-cycle so the grid reads as hand-placed, not a repeated tic.
    private func sourcePoolCell(_ card: OpportunitySourceCard, index: Int) -> some View {
        let cycle = index % 3
        let tilt: Double = cycle == 0 ? 3 : (cycle == 1 ? -2.6 : 1.6)
        let yOffset: CGFloat = cycle == 2 ? 4 : 0

        return Group {
            if let thumbnail = poolThumbnail(for: card) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 15, weight: .semibold))
                    Text(poolResourceLabel(card))
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.macInk.opacity(0.5))
            }
        }
        .frame(width: 84, height: 84)
        .background(Theme.macCardBright, in: Rectangle())
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 4))
        .clipShape(Rectangle())
        .rotationEffect(.degrees(tilt))
        .offset(y: yOffset)
        .help(card.envelope.resource ?? "")
    }

    private func poolThumbnail(for card: OpportunitySourceCard) -> NSImage? {
        guard let resource = card.envelope.resource, let url = URL(string: resource), url.isFileURL else { return nil }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp"]
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func poolResourceLabel(_ card: OpportunitySourceCard) -> String {
        guard let resource = card.envelope.resource, let url = URL(string: resource) else { return "source" }
        return url.host ?? url.lastPathComponent
    }

    // MARK: - Fleet ledger (WO-M, flat v1)

    private var fleetLedger: some View {
        HStack(spacing: 0) {
            ledgerFigure(
                label: "spend today",
                value: "\(model.delegationAgentDailySpend)/\(model.delegationAgentDailyCreditLimit)",
                help: "Firecrawl credits used today vs the daily Kill Switch cap"
            )
            ledgerDivider
            ledgerFigure(
                label: "runs",
                value: "\(model.runs.count)",
                help: "Runs in the GRDB ledger (most recent \(model.runs.count))"
            )
            ledgerDivider
            ledgerFigure(
                label: "shipped this week",
                value: "\(model.fleetLedgerShippedThisWeek)",
                help: "Pursue actions recorded in the last 7 days — v1 stand-in for a dedicated shipped event"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ledgerFigure(label: String, value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.macInk)
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.macInk.opacity(0.46))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
    }

    private var ledgerDivider: some View {
        Rectangle()
            .fill(Theme.macHair)
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    private var observationalSteps: [PatternStep] {
        model.ontology.pattern.filter { $0.zone == .observational }
    }

    private var executionSteps: [PatternStep] {
        model.ontology.pattern.filter { $0.zone == .execution }
    }

    private var gateStatusLine: some View {
        HStack(spacing: 8) {
            // The ONE breathing dot (WO-H) — it only breathes when the gate
            // is genuinely live and open; a locked gate gets a still dot,
            // since motion here should mean something, not decorate.
            if model.patternGateState.executionUnlocked {
                SavyBreathingDot(color: Theme.savyGreen, diameter: 7)
            } else {
                Circle()
                    .fill(Theme.macRed.opacity(0.7))
                    .frame(width: 7, height: 7)
            }
            Text(model.patternGateState.executionUnlocked ? "unlocked" : "locked")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.macInk.opacity(0.7))
            Text("· \(model.patternGateState.source.rawValue)")
                .font(.caption2)
                .foregroundStyle(Theme.macInk.opacity(0.46))
            Spacer()
            Button {
                Task { await model.refreshPatternGate() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.macInk.opacity(0.5))
            .help(model.patternGateState.detail)
        }
    }

    private func blueprintSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.macRed.opacity(0.9))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13).weight(.bold))
                    .foregroundStyle(Theme.macInk.opacity(0.78))
                Spacer()
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
    }

    private func placeholderNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.macInk.opacity(0.46))
    }
}

/// Cells 1-4: an isolated rating number once recorded (ratings are
/// write-once — PatternEvidenceStore.record throws on a second rating
/// for the same step), otherwise the entry control. WO-H ink: cornerRadius
/// 0, crimson 2pt contour. The tilt applies only once the cell is
/// display-only (rated) — a tilted Stepper/TextField/Button while Adam
/// is actively rating would be a usability regression, not "chaos is
/// soothing."
private struct PatternObservationalCell: View {
    let step: PatternStep
    let rating: Int?
    let onSubmit: (Int, String) -> Void

    @State private var draftRating: Double = 7
    @State private var evidenceNote = ""

    private var tiltDegrees: Double { step.id.isMultiple(of: 2) ? 1.2 : -1.2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cellHeader

            if let rating {
                Text("\(rating)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.macRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Stepper("Rating: \(Int(draftRating))", value: $draftRating, in: 1...10, step: 1)
                        .font(.caption)
                    TextField("Evidence note", text: $evidenceNote)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Rate") {
                        onSubmit(Int(draftRating), evidenceNote)
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(evidenceNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(rating != nil ? Theme.macWarmCream : Theme.macCardBright, in: Rectangle())
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 4))
        .rotationEffect(.degrees(rating != nil ? tiltDegrees : 0))
    }

    private var cellHeader: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text("\(step.id)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.macRed)
                Text(step.title)
                    .font(.system(size: 12).weight(.semibold))
                    .foregroundStyle(Theme.macInk.opacity(0.85))
            }
            Text(step.description)
                .font(.caption2)
                .foregroundStyle(Theme.macInk.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Cells 5-8: locked at 45% ink until PatternGateChecker says
/// executionUnlocked — never derived any other way. Matches the
/// mockup's actual `.rail .cell.locked` treatment precisely: cool
/// grey-blue fill + ink (not just dimmed crimson-on-cream), its own
/// Benday dot texture in that same cool tone, uniform 4px crimson
/// border regardless of state (the mockup never varies border weight
/// by state -- only the fill and text color carry that meaning).
/// Always display-only, so the tilt is always safe to apply.
private struct PatternExecutionCell: View {
    let step: PatternStep
    let unlocked: Bool

    private var tiltDegrees: Double { step.id.isMultiple(of: 2) ? -1.4 : 1.4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("\(step.id)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
                    .font(.caption2)
            }
            Text(step.title)
                .font(.system(size: 12).weight(.semibold))
            Text(step.description)
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(unlocked ? Theme.macInk.opacity(0.9) : Theme.macCoolInk)
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background {
            if unlocked {
                Theme.macWarmCream
            } else {
                ZStack {
                    Theme.macCoolBg
                    SavyBendayGround(dotColor: Theme.macCoolInk, dotOpacity: 0.3, spacing: 7, dotDiameter: 2.2)
                }
            }
        }
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 4))
        .rotationEffect(.degrees(tiltDegrees))
    }
}

/// "YOU SEE" / "YOU DO" copy per step, ported verbatim from the approved
/// v6 mockup's `#loop .stage` cards -- not written fresh for this build.
private enum LoopStepCopy {
    struct Detail {
        let youSee: String
        let youDo: String
    }

    static func detail(for stepID: Int) -> Detail {
        table[stepID] ?? Detail(youSee: "", youDo: "")
    }

    private static let table: [Int: Detail] = [
        1: Detail(
            youSee: "one Context slide + audio brief — what already exists: your repos, your apps, the graph, the market",
            youDo: "rate the evidence 1–10 — beside it, the case-against card argues why this is still Step 1. You rate the dispute, not the pitch."
        ),
        2: Detail(
            youSee: "a landscape Mind Map + audio walkthrough — competitors, App Store, prior art, sources quoted verbatim",
            youDo: "rate the evidence 1–10"
        ),
        3: Detail(
            youSee: "one slide per gap: the gap / what closes it / recommended default",
            youDo: "rate the evidence 1–10"
        ),
        4: Detail(
            youSee: "your spoken sentences split into numbered Done conditions — each one becomes a test. If a sentence is ambiguous, agents build BOTH artifacts. Never a paraphrase.",
            youDo: "rate the cell — all four at 7+ unlocks the build. \"If I can't say, I can't play.\""
        ),
        5: Detail(
            youSee: "one slide per screen: real render + your sentence beneath + numbers in cells (evals, advisors, breaker kills)",
            youDo: "Continue / Change (speak it) / Retry — or \"Hold it in my hand\" to run it live. Architectural forks are never asked: the reversible option is built and a Hold is logged with its return condition."
        ),
        6: Detail(
            youSee: "one card of numbers: spend caps, crash threshold, eval floor",
            youDo: "Save. The caps live in the top bar from then on."
        ),
        7: Detail(
            youSee: "the install card — the icon on YOUR phone doing what your sentence said. Every un-passed sentence blocks the ship; nothing uploads to TestFlight without your Pursue.",
            youDo: "Pursue to ship. Then listen: unprompted third-party words arrive as quote cards, verbatim, with who and when."
        ),
        8: Detail(
            youSee: "one \"what compounds\" slide + an Add button that turns this whole build into a named routine — a repeat order on the menu",
            youDo: "accept or pass per candidate. Crashes, deletions, and store outcomes feed the next Context on what WORKED, not on what was easy to approve."
        )
    ]
}

/// A jump target for `stepRail`'s tap gesture -- `highlighted` mirrors
/// the mockup's `.hl` class toggle (thicker crimson ring + warm fill)
/// for the card a rail tap just scrolled to.
private struct LoopStepDetailCard: View {
    let step: PatternStep
    let detail: LoopStepCopy.Detail
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STEP \(step.id) · \(step.zone == .observational ? "OBSERVE" : "EXECUTE")")
                .font(.system(size: 10).weight(.bold))
                .tracking(0.4)
                .foregroundStyle(Theme.macRed)
            Text(step.title)
                .font(.system(size: 14).weight(.bold))
                .foregroundStyle(Theme.macInk)

            Text("YOU SEE")
                .font(.system(size: 9).weight(.bold))
                .foregroundStyle(Theme.macInk.opacity(0.4))
            Text(detail.youSee)
                .font(.caption2)
                .foregroundStyle(Theme.macInk.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            Text("YOU DO")
                .font(.system(size: 9).weight(.bold))
                .foregroundStyle(Theme.macInk.opacity(0.4))
            Text(detail.youDo)
                .font(.caption2)
                .foregroundStyle(Theme.macInk.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .background(highlighted ? Theme.macWarmCream : Theme.macCardBright, in: Rectangle())
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: highlighted ? 5 : 1.5))
        .animation(.easeInOut(duration: 0.3), value: highlighted)
    }
}
#endif
