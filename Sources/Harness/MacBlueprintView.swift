#if os(macOS)
import AppKit
import SwiftUI
import OntologyKit
import UniformTypeIdentifiers

/// The v6-mockup cockpit, laid out as the approved artifact actually
/// renders (claude.ai/code/artifact/1bb1be7b...): one full-height canvas
/// -- navy railbar, ONE row of 8 rail cells, tilted shingled FASCINATION
/// band, then a three-column body (sources pool 24% / center / organize
/// 29%) over a 3D-tilted navy fleet ledger -- not a vertical stack of
/// labeled sections. Every geometry number below (border widths, tilts,
/// column fractions, the 16-degree ledger plane) is the mockup's own CSS
/// value, cited inline. "The loop" detail cards sit below the fold as
/// the rail's tap-to-jump target, same as the artifact page.
struct MacBlueprintView: View {
    @ObservedObject var model: MacWorkbenchModel
    @EnvironmentObject private var audioBriefPlayer: AudioBriefPlayer

    /// Rail tap -> scroll to + highlight the matching loop card below
    /// (the artifact's one real click interaction).
    @State private var highlightedStepID: Int?
    /// Which observational cell is showing its rating popover.
    @State private var ratingPopoverStep: Int?
    /// WO-L lock, mirrored from MacChatView (private there): once shown,
    /// the UP NEXT row is never swapped while it still exists.
    @State private var upNextRowID: String?

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        cockpitCanvas
                            .frame(height: max(geo.size.height, 560))
                            .clipped()
                        loopSection
                    }
                }
                .onAppear { jumpToLoop = { stepID in
                    highlightedStepID = stepID
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(stepID, anchor: .center)
                    }
                } }
            }
        }
        .background(Theme.macBg)
        .task { await model.refreshPatternGate() }
        .task { model.refreshFascinationCards() }
        .task { await model.refreshFleetLedger() }
        .task { model.refreshSourcePool() }
        .onAppear { refreshUpNextLock() }
        .onChange(of: model.opportunityBoardRows.map(\.id)) { refreshUpNextLock() }
    }

    /// Set in onAppear so rail cells (built outside ScrollViewReader's
    /// closure) can trigger the proxy scroll.
    @State private var jumpToLoop: (Int) -> Void = { _ in }

    // MARK: - The cockpit canvas (one viewport-height screen)

    private var cockpitCanvas: some View {
        VStack(spacing: 0) {
            railbar
            stepRailRow
            fascinationBand
                .zIndex(2)
            canvasBody
                .zIndex(1)
        }
        .background {
            ZStack {
                Theme.macBg
                // .canvas{radial-gradient(rgba(8,23,45,.09) 1.1px...) 10px}
                SavyBendayGround(dotColor: Theme.savyDeepNavy, dotOpacity: 0.09, spacing: 10, dotDiameter: 2.2)
            }
        }
    }

    // MARK: - Railbar (navy status bar)

    /// .railbar -- HARNESS wordmark, breathing dot + current step,
    /// kill-switch spend readout in tan tabular figures.
    private var railbar: some View {
        HStack(spacing: 14) {
            Text("HARNESS")
                .font(Theme.savyDisplaySerif(18, weight: .regular))
                .kerning(0.5)
                .foregroundStyle(Theme.savyCard)

            HStack(spacing: 6) {
                if model.patternGateState.executionUnlocked {
                    SavyBreathingDot(color: Theme.savyGreen, diameter: 8)
                } else {
                    Circle().fill(Theme.macRed).frame(width: 8, height: 8)
                }
                Text(currentStepReadout)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.savyCard.opacity(0.92))
            }

            Spacer()

            Text("Kill Switch  \(model.delegationAgentDailySpend) of \(model.delegationAgentDailyCreditLimit) today")
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(Theme.macTan)
                .help("Firecrawl credits used today vs the daily Kill Switch cap")

            Button {
                Task { await model.refreshPatternGate() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.savyCard.opacity(0.6))
            .help(model.patternGateState.detail)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(Theme.savyDeepNavy)
    }

    private var currentStepReadout: String {
        if let step = currentStep {
            return "Step \(step.id) — \(step.title)"
        }
        return model.patternGateState.executionUnlocked ? "unlocked" : "locked"
    }

    /// The "cur" cell: first unrated observational step; once all four
    /// are rated and the gate opens, Step 5 (the build) is current.
    private var currentStep: PatternStep? {
        if let firstUnrated = observationalSteps.first(where: { model.patternGateState.ratings[$0.id] == nil }) {
            return firstUnrated
        }
        return model.patternGateState.executionUnlocked ? executionSteps.first : nil
    }

    // MARK: - Step Rail (ONE row of 8, borders collapsed)

    /// .rail -- 8 equal cells, 4px crimson borders collapsing via
    /// margin-right:-4px, no tilts. done=warm "N/10", cur=cream +
    /// inset ring + scale(1.045), locked=cool + grey dot field.
    private var stepRailRow: some View {
        HStack(spacing: -4) {
            ForEach(model.ontology.pattern) { step in
                railCell(step)
            }
        }
        .zIndex(3)
    }

    private func railCell(_ step: PatternStep) -> some View {
        let state = railState(for: step)
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(step.id)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(state == .locked ? Theme.macCoolInk : Theme.macInk.opacity(0.5))
            Text(step.title)
                .font(.system(size: 13, weight: .bold))
                .kerning(0.3)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundStyle(state == .locked ? Theme.macCoolInk : Theme.macInk)
            Text(railEvidenceText(for: step, state: state))
                .font(.system(size: state == .locked ? 12 : 15, weight: state == .locked ? .bold : .heavy).monospacedDigit())
                .foregroundStyle(state == .locked ? Theme.macCoolInk : (state == .current ? Theme.macRed : Theme.macInk))
                .padding(.top, 2)
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 7, trailing: 8))
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background {
            switch state {
            case .done: Theme.macWarmCream
            case .current: Theme.savyCard
            case .waiting: Theme.macTan
            case .locked:
                ZStack {
                    Theme.macCoolBg
                    SavyBendayGround(dotColor: Theme.macCoolInk, dotOpacity: 0.3, spacing: 7, dotDiameter: 2.2)
                }
            }
        }
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 4))
        .overlay {
            // .cell.cur{box-shadow:inset 0 0 0 2px var(--crimson)}
            if state == .current {
                Rectangle().stroke(Theme.macRed, lineWidth: 2).padding(4)
            }
        }
        .scaleEffect(state == .current ? 1.045 : 1)
        .zIndex(state == .current ? 2 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            if step.zone == .observational && model.patternGateState.ratings[step.id] == nil {
                ratingPopoverStep = step.id
            } else {
                jumpToLoop(step.id)
            }
        }
        .popover(isPresented: railRatingBinding(for: step)) {
            RailRatingForm(step: step) { rating, note in
                model.submitPatternRating(step: step.id, rating: rating, evidenceNote: note)
                ratingPopoverStep = nil
            }
        }
        .help(step.description)
    }

    private enum RailCellState { case done, current, waiting, locked }

    private func railState(for step: PatternStep) -> RailCellState {
        if step.zone == .observational {
            if model.patternGateState.ratings[step.id] != nil { return .done }
            return step.id == currentStep?.id ? .current : .waiting
        }
        guard model.patternGateState.executionUnlocked else { return .locked }
        return step.id == currentStep?.id ? .current : .waiting
    }

    private func railEvidenceText(for step: PatternStep, state: RailCellState) -> String {
        switch state {
        case .done: return "\(model.patternGateState.ratings[step.id] ?? 0)/10"
        case .current: return step.zone == .execution ? "building" : "rate"
        case .waiting: return step.zone == .execution ? "ready" : "rate"
        case .locked: return "locked"
        }
    }

    private func railRatingBinding(for step: PatternStep) -> Binding<Bool> {
        Binding(
            get: { ratingPopoverStep == step.id },
            set: { if !$0 { ratingPopoverStep = nil } }
        )
    }

    // MARK: - FASCINATION band (tilted, shingled)

    /// .fasc{transform:rotate(-1.2deg)} with a small two-line lead label
    /// and a snap-scrolling row of 246px white cards shingled by
    /// margin-right:-14px; odd tilt -2.4deg, even +2deg +5px.
    private var fascinationBand: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FASCINATION")
                    .font(.system(size: 10, weight: .heavy))
                    .kerning(2)
                    .foregroundStyle(Theme.macFaint)
                Text("what holds it now")
                    .font(.system(size: 10, design: .serif).italic())
                    .foregroundStyle(Theme.macFaint)
            }
            .padding(.leading, 20)
            .padding(.trailing, 14)

            // Adam: "I'm not gonna read any directions. It should read
            // me." Empty regions stay quiet -- never instructions.
            if model.fascinationCards.isEmpty {
                Spacer().frame(height: 34)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: -14) {
                        ForEach(Array(model.fascinationCards.enumerated()), id: \.element.id) { index, card in
                            fascinationCard(card, index: index)
                        }
                    }
                    .padding(EdgeInsets(top: 10, leading: 6, bottom: 12, trailing: 20))
                }
            }
        }
        .rotationEffect(.degrees(-1.2))
        .padding(.top, 8)
    }

    private func fascinationCard(_ card: FascinationCard, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.quote)
                .font(.system(size: 12.5, design: .serif).italic())
                .foregroundStyle(Theme.macInk)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Text(attributionLine(for: card))
                .font(.system(size: 10))
                .kerning(1)
                .foregroundStyle(Theme.macFaint)
        }
        .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
        .frame(width: 246, alignment: .topLeading)
        .background(Color.white, in: Rectangle())
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 4))
        // .fc.quote{border-left-width:10px} -- the quote-card edge.
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.macRed).frame(width: 10)
        }
        .rotationEffect(.degrees(index.isMultiple(of: 2) ? -2.4 : 2))
        .offset(y: index.isMultiple(of: 2) ? 0 : 5)
        .zIndex(Double(100 - index))
    }

    /// "his own captured observations dated and attributed to ADAM" --
    /// an external source (a book, a paper) just names itself.
    private func attributionLine(for card: FascinationCard) -> String {
        guard card.attribution == "ADAM" else { return card.attribution }
        return "ADAM — \(Self.fascinationDisplayDateFormatter.string(from: card.date))"
    }

    private static let fascinationDisplayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Canvas body (pool 24% / center / organize 29% over ledger)

    private var canvasBody: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // .povline -- crimson gradient rising from the ledger.
                LinearGradient(
                    colors: [Theme.macRed.opacity(0.05), Theme.macRed],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(width: 4)
                .padding(.bottom, 96)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .zIndex(0)

                fleetLedgerBand(width: geo.size.width)
                    .zIndex(1)

                Text("POINT-OF-VIEW")
                    .font(.system(size: 9, weight: .heavy))
                    .kerning(2)
                    .foregroundStyle(Theme.macFaint)
                    .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                    .background(Theme.macBg)
                    .padding(.bottom, 88)
                    .zIndex(2)

                HStack(alignment: .top, spacing: 0) {
                    sourcesPoolColumn
                        .frame(width: geo.size.width * 0.24, height: geo.size.height - 14, alignment: .topLeading)
                    centerColumn(width: geo.size.width * 0.47 - 28)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .frame(height: geo.size.height - 14, alignment: .top)
                        .padding(.horizontal, 10)
                        .zIndex(3)
                    organizeColumn
                        .frame(width: geo.size.width * 0.29, height: geo.size.height - 14, alignment: .topLeading)
                        .clipped()
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, 14)
                .zIndex(2)
            }
        }
    }

    // MARK: - Sources pool (left, 24%)

    private var sourcesPoolColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.sourcePoolCards.isEmpty {
                Spacer().frame(height: 34)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                    ForEach(Array(model.sourcePoolCards.enumerated()), id: \.element.contentHash) { index, card in
                        sourcePoolCell(card, index: index)
                    }
                }
                .padding(.trailing, 8)
            }

            // .pfoot -- the mockup's own caption, verbatim.
            Text("New arrivals warm. The past cools but never leaves the canvas.")
                .font(.system(size: 12, design: .serif).italic())
                .foregroundStyle(Theme.macMuted)
                .padding(.top, 14)
                .padding(.trailing, 12)

            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .padding(.bottom, 120)
        .contentShape(Rectangle())
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

    /// .pc tilt cycle: 3n -> +3deg, 3n+1 -> -2.6deg, 3n+2 -> +1.6deg +4px.
    /// "New arrivals warm. The past cools but never leaves the canvas" --
    /// cards older than a week take the mockup's `.pc.old` treatment
    /// (cool grey fill + grey dot field + cool ink); fresh ones stay warm.
    /// Tap opens the thing the card holds.
    private func sourcePoolCell(_ card: OpportunitySourceCard, index: Int) -> some View {
        let cycle = index % 3
        let tilt: Double = cycle == 0 ? -2.6 : (cycle == 1 ? 1.6 : 3)
        let yOffset: CGFloat = cycle == 1 ? 4 : 0
        let cooled = poolCardIsCooled(card)

        return VStack(alignment: .leading, spacing: 3) {
            Text(poolKicker(card))
                .font(.system(size: 10, weight: .heavy))
                .kerning(1.5)
                .foregroundStyle(cooled ? Theme.macCoolInk : Theme.macRed)
                .lineLimit(1)
            if let thumbnail = poolThumbnail(for: card) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 34)
                    .clipped()
                    .opacity(cooled ? 0.55 : 1)
            }
            Text(poolResourceLabel(card))
                .font(.system(size: 11.5))
                .foregroundStyle(cooled ? Theme.macCoolInk : Theme.macInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            if cooled {
                ZStack {
                    Theme.macCoolBg
                    SavyBendayGround(dotColor: Theme.macCoolInk, dotOpacity: 0.35, spacing: 7, dotDiameter: 2.4)
                }
            } else {
                Color(hex: 0xF5F0E6)
            }
        }
        .overlay(Rectangle().stroke(Theme.macRed.opacity(cooled ? 0.55 : 1), lineWidth: 4))
        .rotationEffect(.degrees(tilt))
        .offset(y: yOffset)
        .contentShape(Rectangle())
        .onTapGesture { openPoolCard(card) }
        .help(card.envelope.resource ?? "")
    }

    private func poolKicker(_ card: OpportunitySourceCard) -> String {
        card.retrievedBy.isEmpty ? "SOURCE" : card.retrievedBy.uppercased()
    }

    /// Warm for the first week, cool after -- from the card's own
    /// frontmatter timestamp. No timestamp = stays warm (never cool a
    /// card on a guess).
    private func poolCardIsCooled(_ card: OpportunitySourceCard) -> Bool {
        guard let stamp = card.envelope.timestamp,
              let date = Self.poolTimestampFormatter.date(from: stamp) else { return false }
        return Date().timeIntervalSince(date) > 7 * 24 * 3600
    }

    private static let poolTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func openPoolCard(_ card: OpportunitySourceCard) {
        guard let resource = card.envelope.resource, let url = URL(string: resource) else { return }
        NSWorkspace.shared.open(url)
    }

    private func poolThumbnail(for card: OpportunitySourceCard) -> NSImage? {
        guard let resource = card.envelope.resource, let url = URL(string: resource), url.isFileURL else { return nil }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp"]
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func poolResourceLabel(_ card: OpportunitySourceCard) -> String {
        if let title = card.envelope.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        guard let resource = card.envelope.resource, let url = URL(string: resource) else { return "source" }
        return url.host ?? url.lastPathComponent
    }

    // MARK: - Center column (UP NEXT deck + composer)

    private func centerColumn(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("UP NEXT")
                .font(.system(size: 12, weight: .heavy))
                .kerning(2.5)
                .foregroundStyle(Theme.macFaint)
                .padding(.bottom, 6)

            upNextDeck(width: max(width, 200))

            // The lap: what comes back lands HERE, center screen,
            // between the deck and your words -- this canvas is the
            // chat page, not a separate room. Empty = breathing space,
            // exactly like the mockup's middle gap.
            if model.chatThread.isEmpty {
                Spacer(minLength: 4)
            } else {
                landedStack
                    .padding(.vertical, 6)
            }

            composerCard
                .padding(.bottom, 10)
        }
        .padding(.leading, 8)
    }

    /// Newest last, auto-scrolled to the latest turn. Adam's words show
    /// as the small italic line they are; what agents return comes as a
    /// bordered card in his lap.
    private var landedStack: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.chatThread) { turn in
                        landedTurn(turn).id(turn.id)
                    }
                    if model.isRunning {
                        HStack(spacing: 6) {
                            SavyBreathingDot(color: Theme.savyGreen, diameter: 7)
                            Text("working")
                                .font(.caption.weight(.bold))
                                .textCase(.uppercase)
                                .foregroundStyle(Theme.macFaint)
                        }
                        .id("working-indicator")
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity)
            .onChange(of: model.chatThread.count) {
                if let lastID = model.chatThread.last?.id {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func landedTurn(_ turn: ConversationTurn) -> some View {
        if turn.role == .user {
            Text(turn.text)
                .font(.system(size: 12, design: .serif).italic())
                .foregroundStyle(Theme.macMuted)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        } else {
            Text(turn.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.macInk)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white, in: Rectangle())
                .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 3))
        }
    }

    private var upNextRow: OpportunityBoardRow? {
        model.opportunityBoardRows.first { $0.id == upNextRowID }
    }

    private func refreshUpNextLock() {
        if let id = upNextRowID, model.opportunityBoardRows.contains(where: { $0.id == id }) { return }
        upNextRowID = OpportunityBoardProjection(rows: model.opportunityBoardRows).rows.first?.id
    }

    /// .deck2 -- dissent card behind (right, +3.2deg), warm deck card in
    /// front (62%, -1.6deg, 6px border, the heaviest ink on the canvas).
    /// Sized by the deck card's natural height, never greedy -- the
    /// composer below must always stay inside the viewport.
    private func upNextDeck(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let caseAgainst = upNextRow?.card.caseAgainst?.trimmingCharacters(in: .whitespacesAndNewlines),
               !caseAgainst.isEmpty {
                dissentCard(caseAgainst)
                    .frame(width: width * 0.46)
                    .rotationEffect(.degrees(3.2))
                    .offset(x: width * 0.54, y: 34)
                    .zIndex(1)
            }
            deckCard
                .frame(width: width * 0.62)
                .rotationEffect(.degrees(-1.6))
                .zIndex(2)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var deckCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let row = upNextRow {
                HStack(alignment: .top) {
                    Text(deckTitle(row))
                        .font(.system(size: 14.5, weight: .bold))
                        .lineLimit(1)
                        .help(deckTitle(row))
                        .foregroundStyle(Theme.macInk)
                    Spacer()
                    if let fit = row.card.fit {
                        Text(String(format: "%.1f", fit))
                            .font(.system(size: 17, weight: .heavy).monospacedDigit())
                            .foregroundStyle(Theme.macRed)
                    }
                }

                if let pitch = row.card.envelope.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !pitch.isEmpty {
                    Text(pitch)
                        .font(.system(size: 12, design: .serif).italic())
                        .foregroundStyle(Theme.macMuted)
                        .lineLimit(1)
                        .help(pitch)
                }

                // .verbs{flex-wrap:wrap} -- two rows here since SwiftUI
                // has no flow layout on macOS 14.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        deckVerb("Continue", filled: true) {
                            model.recordOpportunityBoardAction(.pursue, rows: [row])
                            model.draft = "Pursue delegation \(row.id): \(deckTitle(row))"
                        }
                        deckVerb("Change") {
                            model.draft = "Change delegation \(row.id): "
                        }
                        deckVerb("Retry") {
                            model.draft = "Retry delegation \(row.id): \(deckTitle(row))"
                        }
                    }
                    deckVerb("Hold it in my hand") {
                        model.recordOpportunityBoardAction(.hold, rows: [row])
                    }
                }
            } else {
                Spacer().frame(minHeight: 80)
            }
        }
        .padding(12)
        .background(Theme.macWarmCream, in: Rectangle())
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 6))
    }

    private func deckTitle(_ row: OpportunityBoardRow) -> String {
        let title = row.card.envelope.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title! : row.id
    }

    private func deckVerb(_ label: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(filled ? .white : Theme.macInk)
                .padding(EdgeInsets(top: 5, leading: 13, bottom: 5, trailing: 13))
                .background(filled ? Theme.macRed : Color.white, in: Rectangle())
                .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 3.5))
        }
        .buttonStyle(.plain)
    }

    /// THE CASE AGAINST -- the one agent-speech surface, visually marked
    /// by the 10px left edge (hard rule 4: dissent cards are marked).
    private func dissentCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("THE CASE AGAINST")
                .font(.system(size: 10, weight: .heavy))
                .kerning(1.5)
                .foregroundStyle(Theme.macRed)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.macInk)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(hex: 0xF5F0E6), in: Rectangle())
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 4))
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.macRed).frame(width: 10)
        }
    }

    // MARK: - Composer (bottom center, live bindings)

    /// .composer -- cream, 6px border, pinned to the column bottom.
    /// The three fields bind the SAME @Published storage the chat
    /// composer uses (WO-J): draft / preferredApproach / doneCondition.
    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            composerField(label: "WHAT DO I WANT?", text: $model.draft)
            composerField(label: "WHEN I AM...I LIKE TO", text: $model.preferredApproach)
            composerField(label: "DONE LOOKS LIKE...", text: $model.doneCondition)
        }
        .padding(8)
        .background(Theme.savyCard, in: Rectangle())
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 6))
    }

    private func composerField(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .heavy))
                .kerning(1.5)
                .foregroundStyle(Theme.macFaint)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.macInk)
                // Return sends -- the mockup composer has no send button,
                // and send() already guards empty drafts and running state.
                .onSubmit { model.send() }
        }
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: Rectangle())
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 3))
    }

    // MARK: - Organize column (right, 29%)

    private var organizeColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ORGANIZE")
                .font(.system(size: 12, weight: .heavy))
                .kerning(2.5)
                .foregroundStyle(Theme.macFaint)
                .padding(.bottom, 4)

            organizeSlot(
                name: "Mind Map",
                status: "pending (\(model.opportunityBoardRows.count))",
                dotColor: Theme.statusPending
            ) {
                mindMapPlanView
                Text("PLAN VIEW — SAME BUILD, FROM ABOVE")
                    .font(.system(size: 9, weight: .heavy))
                    .kerning(1.5)
                    .foregroundStyle(Theme.macFaint)
                    .padding(.top, 5)
                Text("The map of leverage. The only navigation there is.")
                    .font(.system(size: 12, design: .serif).italic())
                    .foregroundStyle(Theme.macMuted)
            }
            .rotationEffect(.degrees(-2.2))
            .offset(y: -8)
            .zIndex(2)

            organizeSlot(
                name: "Slide Deck",
                status: "live · \(max(model.opportunityBoardRows.count, 1)) slides",
                dotColor: Theme.statusLive
            ) {
                slideFilmstrip
                Text("FRONT VIEW — SAME BUILD, FACE ON · WARM SLIDE = UP NEXT")
                    .font(.system(size: 9, weight: .heavy))
                    .kerning(1.5)
                    .foregroundStyle(Theme.macFaint)
                    .padding(.top, 5)
            }
            .rotationEffect(.degrees(2))
            .zIndex(1)

            organizeSlot(
                name: "Audio",
                status: "live · what changed",
                dotColor: Theme.statusLive,
                breathing: audioBriefPlayer.isSpeaking
            ) {
                audioPlayerRow
            }
            .rotationEffect(.degrees(1.4))
            .offset(y: -14)
            .zIndex(0)
        }
        // Trailing 28 (was 16): the slots' tilts may lean their BORDERS
        // toward the edge, but headers and statuses stay whole.
        .padding(.trailing, 28)
        .padding(.leading, 6)
        .padding(.bottom, 120)
    }

    private func organizeSlot<Content: View>(
        name: String,
        status: String,
        dotColor: Color,
        breathing: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if breathing {
                    SavyBreathingDot(color: dotColor, diameter: 8)
                } else {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                }
                Text(name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.macInk)
                Spacer()
                Text(status)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.macFaint)
            }
            content()
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.white, in: Rectangle())
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 4))
    }

    /// .slides -- one 26px cell per board row (capped), first navy,
    /// the UP NEXT row's cell warm. Real rows, and now real steering:
    /// tap a slide and that delegation becomes the UP NEXT decision.
    private var slideFilmstrip: some View {
        HStack(spacing: 4) {
            let rows = OpportunityBoardProjection(rows: model.opportunityBoardRows).rows.prefix(6)
            if rows.isEmpty {
                Rectangle()
                    .fill(Theme.savyDeepNavy)
                    .frame(height: 26)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    Rectangle()
                        .fill(index == 0 ? Theme.savyDeepNavy : (row.id == upNextRowID ? Theme.macWarmCream : Theme.macBg))
                        .frame(height: 26)
                        .overlay(Rectangle().stroke(
                            index == 0 ? Theme.savyDeepNavy : (row.id == upNextRowID ? Theme.macTan : Theme.macRed),
                            lineWidth: 2
                        ))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) { upNextRowID = row.id }
                        }
                        .help(deckTitle(row))
                }
            }
        }
    }

    /// "live · what changed" -- plays the newest run's own summary text
    /// verbatim (never new wording); falls back to the UP NEXT pitch
    /// when no run exists yet. The bar is the synthesizer's real
    /// position in the text, not a timer.
    private var audioPlayerRow: some View {
        HStack(spacing: 8) {
            Button {
                if audioBriefPlayer.isSpeaking {
                    audioBriefPlayer.stop()
                } else if let brief = whatChangedBrief {
                    audioBriefPlayer.speak(brief)
                }
            } label: {
                Image(systemName: audioBriefPlayer.isSpeaking ? "stop.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Theme.macRed, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(whatChangedBrief == nil && !audioBriefPlayer.isSpeaking)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.macTan)
                    Rectangle()
                        .fill(Theme.macRed)
                        .frame(width: geo.size.width * audioBriefPlayer.progress)
                }
            }
            .frame(height: 6)
        }
    }

    private var whatChangedBrief: String? {
        if let latest = model.runs.first {
            let answer = latest.finalAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty { return answer }
        }
        guard let row = upNextRow else { return nil }
        let pitch = row.card.envelope.description ?? ""
        return "\(deckTitle(row)). \(pitch)"
    }

    // MARK: - Mind Map tree (WO-O, read-only)

    /// The mockup's plan-view node map, from real rows: center navy
    /// ellipse = the UP NEXT delegation (the build's intent, white
    /// italic), leaf ellipses = the next rows by priority on tan
    /// spokes. The warm leaf's spoke is crimson. Tap ANY leaf and it
    /// becomes UP NEXT -- "The map of leverage. The only navigation
    /// there is."
    private var mindMapPlanView: some View {
        Group {
            if let center = upNextRow {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    let leaves = mindMapLeaves
                    // Right anchors sit at 0.72, not 0.80 -- leaf ovals are
                    // up to 110pt wide, and 0.80 pushed their labels past
                    // the slot (and the window) edge. The DESIGN leans
                    // borders off the edge; it never amputates words.
                    let anchors: [CGPoint] = [
                        CGPoint(x: w * 0.24, y: h * 0.16),
                        CGPoint(x: w * 0.72, y: h * 0.14),
                        CGPoint(x: w * 0.22, y: h * 0.86),
                        CGPoint(x: w * 0.72, y: h * 0.84)
                    ]
                    let centerPoint = CGPoint(x: w * 0.5, y: h * 0.5)

                    ZStack {
                        // Spokes first, under the nodes.
                        ForEach(Array(leaves.enumerated()), id: \.element.id) { index, leaf in
                            if index < anchors.count {
                                Path { path in
                                    path.move(to: centerPoint)
                                    path.addLine(to: anchors[index])
                                }
                                .stroke(
                                    leaf.id == upNextRowID ? Theme.macRed : Theme.macTan,
                                    lineWidth: leaf.id == upNextRowID ? 3.5 : 3
                                )
                            }
                        }

                        mindMapCenterNode(center)
                            .position(centerPoint)

                        ForEach(Array(leaves.enumerated()), id: \.element.id) { index, leaf in
                            if index < anchors.count {
                                mindMapLeafNode(leaf)
                                    .position(anchors[index])
                            }
                        }
                    }
                }
                .frame(height: 148)
            } else {
                Spacer().frame(height: 60)
            }
        }
    }

    /// The rows orbiting the center: the next four by priority,
    /// excluding the center itself.
    private var mindMapLeaves: [OpportunityBoardRow] {
        Array(
            OpportunityBoardProjection(rows: model.opportunityBoardRows).rows
                .filter { $0.id != upNextRowID }
                .prefix(4)
        )
    }

    /// Still feeds the fleet ledger's per-app counts.
    private var mindMapGroups: [OpportunityBoardAppGroup] {
        OpportunityBoardProjection(rows: model.opportunityBoardRows).groupsByApp()
    }

    private func mindMapCenterNode(_ row: OpportunityBoardRow) -> some View {
        Text(deckTitle(row))
            .font(.system(size: 10, design: .serif).italic())
            .foregroundStyle(Theme.savyCard)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: 170)
            .background(Ellipse().fill(Theme.savyDeepNavy))
            .overlay(Ellipse().stroke(Theme.macRed, lineWidth: 3.5))
    }

    private func mindMapLeafNode(_ row: OpportunityBoardRow) -> some View {
        Text(deckTitle(row))
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Theme.macInk)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 110)
            .background(Ellipse().fill(Theme.macBg))
            .overlay(Ellipse().stroke(Theme.macRed, lineWidth: 3))
            .contentShape(Ellipse())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.25)) { upNextRowID = row.id }
            }
            .help("Make this the UP NEXT decision")
    }

    // MARK: - Fleet ledger (bottom, tilted plane)

    /// .ledger -- navy, crimson benday dots, 10px crimson top border,
    /// rotateX(16deg) from the bottom edge with perspective: the
    /// "distant operational world leaning into view."
    private func fleetLedgerBand(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 26) {
            ledgerGroup("SPEND") {
                Text("\(model.delegationAgentDailySpend) of \(model.delegationAgentDailyCreditLimit)")
            }
            ledgerGroup("RUNS") {
                HStack(spacing: 7) {
                    if model.isRunning {
                        SavyBreathingDot(color: Theme.statusLive, diameter: 8)
                        Text("live 1")
                    } else {
                        Circle().fill(Theme.statusLive).frame(width: 8, height: 8)
                        Text("\(model.runs.count)")
                    }
                }
            }
            ledgerGroup("SHIPPED THIS WEEK") {
                Text("\(model.fleetLedgerShippedThisWeek)")
            }
            Spacer()
            ledgerGroup("FLEET") {
                HStack(spacing: 10) {
                    ForEach(mindMapGroups) { group in
                        HStack(spacing: 5) {
                            Circle().fill(Theme.statusLive).frame(width: 8, height: 8)
                            Text("\(group.app.rawValue) \(group.rows.count)")
                        }
                    }
                    if mindMapGroups.isEmpty {
                        Text("—")
                    }
                }
            }
        }
        .font(.system(size: 12.5).monospacedDigit())
        .foregroundStyle(Theme.savyCard)
        .padding(EdgeInsets(top: 14, leading: width * 0.06, bottom: 0, trailing: width * 0.06))
        .frame(width: width * 1.06, height: 104, alignment: .top)
        .background {
            ZStack {
                Theme.savyDeepNavy
                SavyBendayGround(dotColor: Theme.macRed, dotOpacity: 0.3, spacing: 9, dotDiameter: 2.8)
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.macRed).frame(height: 10)
        }
        .rotation3DEffect(.degrees(16), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.7)
        .offset(y: 6)
    }

    private func ledgerGroup<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .kerning(1.5)
                .foregroundStyle(Theme.macTan)
            content()
        }
    }

    // MARK: - The loop (below the fold; jump target for rail taps)

    private var observationalSteps: [PatternStep] {
        model.ontology.pattern.filter { $0.zone == .observational }
    }

    private var executionSteps: [PatternStep] {
        model.ontology.pattern.filter { $0.zone == .execution }
    }

    /// Mockup's `#loop .stage` cards -- copy ported verbatim from the
    /// approved v6 artifact, not written fresh here.
    private var loopSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The loop")
                .font(.system(size: 22, design: .serif).weight(.semibold))
                .foregroundStyle(Theme.macInk)
            Text("SPEAK SENTENCES · RATE FOUR NUMBERS · PRESS CONTINUE — THAT IS THE WHOLE JOB")
                .font(.system(size: 10, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(Theme.macFaint)

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
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The rail cell's rating entry, moved out of the cell into a popover so
/// the rail keeps the mockup's compact one-row silhouette. Ratings stay
/// write-once (PatternEvidenceStore.record throws on a second rating).
private struct RailRatingForm: View {
    let step: PatternStep
    let onSubmit: (Int, String) -> Void

    @State private var draftRating: Double = 7
    @State private var evidenceNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(step.id) \(step.title)")
                .font(.system(size: 13, weight: .bold))
            Text(step.description)
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .padding(14)
        .frame(width: 260)
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

/// A jump target for the rail's tap gesture -- `highlighted` mirrors
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
                .kerning(0.4)
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
