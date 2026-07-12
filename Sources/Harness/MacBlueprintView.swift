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
                    // Adam's list, item 4 (voice memo): "I want to be able
                    // to copy and paste any text that I see on the page ...
                    // I don't want any small little icons that tell me I
                    // can do this." One switch at the root: every Text on
                    // the canvas is selectable, nothing announces it.
                    VStack(spacing: 0) {
                        cockpitCanvas
                            .frame(height: max(geo.size.height, 560))
                            .clipped()
                        loopSection
                    }
                    .textSelection(.enabled)
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
    /// Inline pool-card editing (Adam's list, item 3).
    @State private var wigglingPoolCardID: String?
    @State private var editingPoolCardID: String?
    @State private var editingPoolText = ""
    @FocusState private var poolEditFocus: String?
    /// Memo 22: which box the strip's plus/mic/formatting act on.
    @FocusState private var focusedComposerField: String?
    @State private var showPlusMenu = false
    @StateObject private var voiceDictation = VoiceDictationController()

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
                // Memo 22: "We might actually go supersonic with that and
                // just make those huge ... I don't want it to be subtle.
                // I want to absolutely rock my world and make it feel
                // like I'm looking at a Lichtenstein painting and I'm in
                // an art gallery I just happen to work at."
                SavyBendayGround(dotColor: Theme.savyDeepNavy, dotOpacity: 0.16, spacing: 30, dotDiameter: 12, waves: true)
            }
        }
    }

    // MARK: - Railbar (navy status bar)

    /// .railbar -- HARNESS wordmark, breathing dot + current step,
    /// kill-switch spend readout in tan tabular figures.
    /// A bare navy band -- Adam: "that navy strip can stay there" but
    /// the step readout, the dot, and "Kill Switch 0 of 50 today" all
    /// go ("I don't know what those are for. I don't care what they
    /// are for ... remove that"). The gate still refreshes on appear.
    private var railbar: some View {
        Rectangle()
            .fill(Theme.savyDeepNavy)
            .frame(height: 28)
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

    /// Adam's list, item 1 (2026-07-09 voice memo): "remove the number.
    /// I want the name ... then the brief description ... the name
    /// should actually be in black, the description should be in red,
    /// and then have it repeat that pattern throughout the eight steps."
    private func railCell(_ step: PatternStep) -> some View {
        let state = railState(for: step)
        return VStack(alignment: .leading, spacing: 2) {
            Text(step.title)
                .font(.system(size: 13, weight: .bold))
                .kerning(0.3)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundStyle(state == .locked ? Theme.macCoolInk : Theme.macInk)
            // Adam (voice follow-up): "remove the ratings below it that
            // seven out of 10 and the rate ... remove that." Name +
            // description only; the cell COLORS carry the state, and the
            // gate still enforces itself underneath.
            Text(step.description)
                .font(.system(size: 10.5))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(state == .locked ? Theme.macCoolInk : Theme.macRed)
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
    /// Adam's list, item 2, corrected in his words: "I move the
    /// carosel. it doesn't move on it's own." A hand-driven row --
    /// swipe/scroll through dozens of cards, nothing moves by itself.
    private var fascinationBand: some View {
        // No lead label -- the cards speak for themselves.
        HStack(alignment: .center, spacing: 0) {
            // Empty regions stay quiet -- never instructions.
            if model.fascinationCards.isEmpty {
                Spacer().frame(height: 34)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: -14) {
                        ForEach(Array(model.fascinationCards.enumerated()), id: \.element.id) { index, card in
                            fascinationCard(card, index: index)
                                .id(card.id)
                        }
                    }
                    .padding(EdgeInsets(top: 10, leading: 6, bottom: 12, trailing: 20))
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
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
                    Color.clear
                        .frame(maxWidth: .infinity)
                    organizeColumn
                        .frame(width: geo.size.width * 0.29, height: geo.size.height - 14, alignment: .topLeading)
                        .clipped()
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, 14)
                .zIndex(2)

                // Adam's memo 20: "the delegation three steps are in the
                // dead center of the page" -- centered on the PAGE, not
                // on the leftover space between unequal columns.
                VStack(spacing: 10) {
                    composerCard
                    if !model.delegationReceipts.isEmpty || model.delegationSubmissionError != nil {
                        landedStack
                            .frame(maxHeight: max(120, geo.size.height - 250))
                    }
                }
                    .frame(width: min(geo.size.width * 0.44, 660))
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .zIndex(3)

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

            // Phone arrivals -- what he captured out in the world,
            // waiting below the jumble for a calm look. Right-click to
            // archive (never delete); nothing here feeds the map.
            if !model.phoneArrivals.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.phoneArrivals.enumerated()), id: \.element.id) { index, row in
                        phoneArrivalCard(row, index: index)
                    }
                }
                .padding(.top, 16)
                .padding(.trailing, 8)
            }

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
            // Adam's list, item 3 (voice memo): "I want to be able just
            // to click on it, then it starts to shake and wiggle ...
            // there's an animation that lets me know that after I've
            // clicked on it that it's alive and ready and then I can
            // click inside it and change the wording of it if I want."
            // No pin, no icon.
            if editingPoolCardID == card.contentHash {
                TextField("", text: $editingPoolText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(cooled ? Theme.macCoolInk : Theme.macInk)
                    .focused($poolEditFocus, equals: card.contentHash)
                    .onSubmit { commitPoolEdit(card) }
            } else {
                Text(poolResourceLabel(card))
                    .font(.system(size: 11.5))
                    .foregroundStyle(cooled ? Theme.macCoolInk : Theme.macInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        .rotationEffect(.degrees(tilt + (wigglingPoolCardID == card.contentHash ? 2.2 : 0)))
        .animation(
            wigglingPoolCardID == card.contentHash
                ? .easeInOut(duration: 0.09).repeatCount(7, autoreverses: true)
                : .easeOut(duration: 0.15),
            value: wigglingPoolCardID == card.contentHash
        )
        .offset(y: yOffset)
        .contentShape(Rectangle())
        .onTapGesture { beginPoolEdit(card) }
        .help(card.envelope.resource ?? "")
    }

    /// Click -> wiggle for ~0.6s (alive and ready) -> rest -> editable.
    private func beginPoolEdit(_ card: OpportunitySourceCard) {
        guard editingPoolCardID != card.contentHash else { return }
        wigglingPoolCardID = card.contentHash
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            wigglingPoolCardID = nil
            editingPoolText = poolResourceLabel(card)
            editingPoolCardID = card.contentHash
            poolEditFocus = card.contentHash
        }
    }

    private func commitPoolEdit(_ card: OpportunitySourceCard) {
        let text = editingPoolText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingPoolCardID = nil
        poolEditFocus = nil
        guard !text.isEmpty, text != poolResourceLabel(card) else { return }
        model.updateSourcePoolCardTitle(card, title: text)
    }

    private func poolKicker(_ card: OpportunitySourceCard) -> String {
        card.retrievedBy.isEmpty ? "SOURCE" : card.retrievedBy.uppercased()
    }

    /// One phone capture: warm, tilted like the jumble above it, the
    /// app it came from as the kicker. Right-click -> Archive.
    private func phoneArrivalCard(_ row: OpportunityBoardRow, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text((row.card.app?.rawValue ?? "PHONE").uppercased())
                .font(.system(size: 10, weight: .heavy))
                .kerning(1.5)
                .foregroundStyle(Theme.macRed)
            Text(deckTitle(row))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.macInk)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.macWarmCream, in: Rectangle())
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 4))
        .rotationEffect(.degrees(index.isMultiple(of: 2) ? -1.6 : 1.8))
        .contextMenu {
            Button("Archive") { model.archivePhoneArrival(row) }
        }
        .help(row.card.body)
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

    // (centerColumn retired -- the composer floats dead-center on the
    // page per memo 20; the middle of the column row is open space.)

    /// Durable Delegation receipts live on the page where Adam submitted
    /// them. Newest first; the stack scrolls when earlier receipts exceed the
    /// remaining canvas height.
    private var landedStack: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.delegationSubmissionError {
                    Text(error)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Theme.macRed)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.macWarmCream, in: Rectangle())
                        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 3))
                }
                ForEach(model.delegationReceipts) { receipt in
                    delegationReceiptCard(receipt)
                }
            }
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func delegationReceiptCard(_ receipt: DelegationReceipt) -> some View {
        let isWorking = receipt.state == .submitted
            && model.activeDelegationReceiptID == receipt.id
            && model.isRunning
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if isWorking {
                    SavyBreathingDot(color: Theme.savyGreen, diameter: 7)
                }
                Text(isWorking ? "SAVED · WORKING" : receipt.state.label)
                    .font(.system(size: 10, weight: .heavy))
                    .kerning(1.4)
                    .foregroundStyle(receipt.state == .failed ? Theme.macRed : Theme.macMuted)
                Spacer(minLength: 0)
                Text(receipt.createdAt, style: .time)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.macFaint)
            }

            receiptLine("WHAT I WANT", receipt.intent)
            receiptLine("WHEN I AM… I LIKE TO", receipt.preferredApproach)
            receiptLine("DONE LOOKS LIKE", receipt.doneCondition)

            if let result = receipt.result, !result.isEmpty {
                Divider().overlay(Theme.macRed.opacity(0.35))
                Text(result)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.macInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macWarmCream, in: Rectangle())
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 3))
    }

    private func receiptLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8.5, weight: .heavy))
                .kerning(1.1)
                .foregroundStyle(Theme.macRed)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12, design: .serif))
                .foregroundStyle(Theme.macInk)
                .fixedSize(horizontal: false, vertical: true)
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
    /// Adam's memo 20: "the inside of the chat to be navy blue and then
    /// the text will be white ... when I'm typing I need to see some
    /// large letters ... as I type the box should expand ... I should
    /// be able to see everything I type." The surrounding cream frame
    /// stays exactly as it was ("I really love that").
    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            composerField(label: "WHAT DO I WANT?", text: $model.draft)
            composerField(label: "WHEN I AM...I LIKE TO", text: $model.preferredApproach)
            // Memo 25: the controls live INSIDE the chat, on the dark
            // ("I thought it was going to be inside the chat ... it
            // can't be this bright area right there in the center that
            // constantly is drawing my eyes").
            composerField(label: "DONE LOOKS LIKE...", text: $model.doneCondition, bottomStrip: true)
        }
        .padding(8)
        .background(Theme.savyCard, in: Rectangle())
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 6))
        // No BIU pill -- Adam: "you already have it down there at the
        // bottom ... so you just get rid of it." Formatting lives in
        // the dark strip inside the chat, nowhere else.
    }

    /// Memo 21: labels in red, fading into the background. Memo 22
    /// moved the controls out of the boxes into ONE strip at the bottom
    /// of the composer (send far left, then plus, mic, formatting,
    /// model) -- so the boxes themselves are just label + words + chips.
    private func composerField(label: String, text: Binding<String>, bottomStrip: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .kerning(1.5)
                .foregroundStyle(Theme.macRed)
            TextEditor(text: text)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .tint(.white)
                .frame(minHeight: 28)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, -5)
                .focused($focusedComposerField, equals: label)

            if let items = model.composerFieldAttachments[label], !items.isEmpty {
                fieldAttachmentChips(items, field: label)
                    .padding(.bottom, 2)
            }

            if bottomStrip {
                composerControlStrip
                    .padding(.top, 6)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 8, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.savyDeepNavy, in: Rectangle())
        .overlay(Rectangle().stroke(Theme.macRed, lineWidth: 3))
    }

    /// The box the strip acts on -- the focused one, else the first.
    private var actionField: String { focusedComposerField ?? "WHAT DO I WANT?" }

    private func fieldBinding(_ field: String) -> Binding<String> {
        switch field {
        case "WHEN I AM...I LIKE TO": return $model.preferredApproach
        case "DONE LOOKS LIKE...": return $model.doneCondition
        default: return $model.draft
        }
    }

    private func voiceField(_ field: String) -> ComposerVoiceField {
        switch field {
        case "WHEN I AM...I LIKE TO": return .preferredApproach
        case "DONE LOOKS LIKE...": return .doneCondition
        default: return .intent
        }
    }

    /// Memo 22 (typed): "we'll put the send button on the far left, so
    /// that's the arrow pointing up ... beside that will be the plus
    /// button to add files and then beside that will be a microphone
    /// icon ... and then the last thing would be the model that's being
    /// used ... the exact model." Plus the heading/bullet/numbered
    /// formatting buttons from the audio memo.
    private var composerControlStrip: some View {
        HStack(spacing: 10) {
            Button { model.sendDelegation() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Theme.macRed, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send the delegation")

            Button { showPlusMenu.toggle() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.macRed)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPlusMenu, arrowEdge: .bottom) { savyPlusMenu }

            Button {
                let field = actionField
                let binding = fieldBinding(field)
                voiceDictation.toggle(field: voiceField(field), currentText: binding.wrappedValue) { newText in
                    binding.wrappedValue = newText
                }
            } label: {
                Image(systemName: voiceDictation.activeField != nil ? "mic.fill" : "mic")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(voiceDictation.activeField != nil ? .white : Theme.macRed)
                    .frame(width: 24, height: 24)
                    .background(voiceDictation.activeField != nil ? Theme.macRed : .clear, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Dictate into the selected box — words appear as you speak")

            // The exact model, right beside the mic and kept dark --
            // Adam: "I want it next to the microphone and I want it
            // also dark and shaded ... I don't want this large amount
            // of contrast so I can focus." (No reasoning-effort knob
            // exists in the app yet -- nothing fake shown.)
            Menu {
                ForEach(Backend.allCases) { backend in
                    Button {
                        model.backend = backend
                    } label: {
                        if model.backend == backend {
                            Label("\(backend.rawValue) · \(backend.defaultModelName)", systemImage: "checkmark")
                        } else {
                            Text("\(backend.rawValue) · \(backend.defaultModelName)")
                        }
                    }
                }
            } label: {
                // Uniform with the rest of the strip -- same red as the
                // icons, nothing shouting.
                Text("\(model.backend.rawValue) · \(model.backend.defaultModelName)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.macRed)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 18)

            formatButton("textformat.size", help: "Heading") { applyMarkdown(prefix: "## ", suffix: "") }
            formatButton("list.bullet", help: "Bullet list") { applyMarkdown(prefix: "- ", suffix: "") }
            formatButton("list.number", help: "Numbered list") { applyMarkdown(prefix: "1. ", suffix: "") }

            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    /// Memo 22 (audio): "When it opens, there needs to be more styling
    /// ... reference the SAVY app ... the right background ... the right
    /// font colors and styling. That makes that more enjoyable to press."
    private var savyPlusMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            savyMenuRow("doc", "File…") {
                showPlusMenu = false
                pickFieldAttachment(field: actionField, kind: .file)
            }
            savyMenuRow("photo", "Image…") {
                showPlusMenu = false
                pickFieldAttachment(field: actionField, kind: .image)
            }
            Rectangle().fill(Theme.macHair).frame(height: 1).padding(.vertical, 4)
            Text("SKILLS")
                .font(.system(size: 9, weight: .heavy))
                .kerning(1.5)
                .foregroundStyle(Theme.savyTertiaryText)
                .padding(.horizontal, 10)
            ForEach(model.workbenchCommunicationSkillTools, id: \.title) { tool in
                savyMenuRow("wrench.and.screwdriver", tool.title) {
                    showPlusMenu = false
                    model.addFieldAttachment(
                        ComposerFieldAttachment(kind: .skill, label: tool.skillName ?? tool.title, url: nil),
                        to: actionField
                    )
                }
            }
        }
        .padding(10)
        .frame(width: 240)
        .background(Theme.savyCard)
    }

    private func savyMenuRow(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.macRed)
                    .frame(width: 18)
                Text(title)
                    .font(Theme.savyRobotoMedium(13))
                    .foregroundStyle(Theme.savyTabActive)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.macRed)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Applies markdown to the live selection in whichever box has the
    /// keyboard -- TextEditor is NSTextView-backed, so the first
    /// responder route edits the real selection, not a fake append.
    private func applyMarkdown(prefix: String, suffix: String) {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        let replacement = prefix + selected + suffix
        if textView.shouldChangeText(in: range, replacementString: replacement) {
            textView.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
        }
    }

    private func pickFieldAttachment(field: String, kind: ComposerFieldAttachment.Kind) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if kind == .image {
            panel.allowedContentTypes = [.image]
        }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            model.addFieldAttachment(
                ComposerFieldAttachment(kind: kind, label: url.lastPathComponent, url: url),
                to: field
            )
        }
    }

    /// Click a chip to remove it -- no extra icons.
    private func fieldAttachmentChips(_ items: [ComposerFieldAttachment], field: String) -> some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                Button {
                    model.removeFieldAttachment(item, from: field)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: item.kind == .skill ? "wrench.and.screwdriver" : (item.kind == .image ? "photo" : "doc"))
                            .font(.system(size: 9))
                        Text(item.label)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.savyDeepNavy)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.macWarmCream, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(item.url?.path ?? item.label)
            }
        }
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
            ledgerGroup("WEB CREDITS") {
                Text("\(model.delegationAgentDailySpend) of \(model.delegationAgentDailyCreditLimit)")
            }
            ledgerGroup("MODEL TOKENS") {
                Text(modelTokenLedgerSummary)
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

    private var modelTokenLedgerSummary: String {
        let recorded = model.runs.compactMap(\.tokenCount).reduce(0, +)
        let untracked = model.runs.filter { $0.tokenCount == nil }.count
        return "\(recorded.formatted()) recorded · \(untracked) untracked"
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
