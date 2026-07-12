#if os(macOS)
import SwiftUI
import OntologyKit

/// Words only in the editor and in thread content. Plus to attach, arrow to send.
struct MacDelegateFormView: View {
    @ObservedObject var model: MacWorkbenchModel
    /// The bouncer's pending queue (same instance as `model.toolApprovals`),
    /// observed here so approval cards appear the moment the loop suspends.
    @ObservedObject var approvals: ToolApprovalStore
    @StateObject private var voiceDictation = VoiceDictationController()
    @State private var showAttachments = false
    @State private var editorHeight: CGFloat = 108
    @FocusState private var questionFocused: Bool

    init(model: MacWorkbenchModel) {
        self.model = model
        self.approvals = model.toolApprovals
    }

    private let columnMaxWidth: CGFloat = 780

    var body: some View {
        GeometryReader { proxy in
            let viewportHeight = proxy.size.height

            VStack(spacing: 0) {
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(model.chatThread) { turn in
                                fullTurnBlock(turn)
                                    .id(turn.id)
                            }

                            ForEach(approvals.pendingRequests) { request in
                                MacToolApprovalCard(
                                    request: request,
                                    onApprove: { always in
                                        model.approveToolRequest(request, always: always)
                                    },
                                    onDeny: {
                                        model.denyToolRequest(request)
                                    }
                                )
                                .id("approval-\(request.id)")
                            }

                            if model.isRunning {
                                Group {
                                    if let monitor = model.activeToolLoop {
                                        MacToolLoopStatusRow(
                                            monitor: monitor,
                                            fallbackStatus: model.status,
                                            onCancel: model.cancelRun
                                        )
                                    } else {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(Theme.savyCrimson)
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .id("running-status")
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.top, 28)
                        .padding(.bottom, 16)
                        .frame(maxWidth: columnMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onAppear {
                        scrollToLatestTurn(scrollProxy)
                    }
                    .onChange(of: model.draft) { _, _ in
                        updateEditorHeight(viewportHeight: viewportHeight)
                    }
                    .tint(Theme.savyCrimson)
                    .onChange(of: model.chatThread.count) { _, _ in
                        scrollToLatestTurn(scrollProxy)
                    }
                    .onChange(of: model.isRunning) { _, _ in
                        if model.isRunning {
                            DispatchQueue.main.async {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    scrollProxy.scrollTo("running-status", anchor: .bottom)
                                }
                            }
                        }
                    }
                    .onChange(of: approvals.pendingRequests.count) { old, new in
                        guard new > old, let newest = approvals.pendingRequests.last else { return }
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.2)) {
                                scrollProxy.scrollTo("approval-\(newest.id)", anchor: .bottom)
                            }
                        }
                    }
                }

                composerBlock
                    .frame(maxWidth: columnMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.macBg)
        .overlay {
            if model.showApprovalToast {
                // Confirmation only — never intercept taps, or its ~1.4s
                // lifetime would swallow clicks on the next approval card.
                SavyLockedInToast()
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.showApprovalToast)
        .sheet(isPresented: $showAttachments) {
            MacComposerAttachmentSheet(model: model)
        }
    }

    private var composerBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            composerDelegateSection
            composerIntentSections
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
    }

    private var composerDelegateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MacSuiteFormRows.sectionLabel("Delegate")

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.composerAttachments.isEmpty {
                        composerAttachmentChips
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                        composerDivider
                    }

                    ZStack(alignment: .topLeading) {
                        if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("What do I want?")
                                .font(Theme.recallBody(17))
                                .foregroundStyle(Theme.macFaint)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $model.draft)
                            .font(Theme.recallBody(17))
                            .foregroundStyle(Theme.savyCrimson)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 40)
                            .frame(height: editorHeight)
                            .focused($questionFocused)
                    }
                    .frame(maxWidth: .infinity, minHeight: editorHeight, alignment: .topLeading)

                    HStack(spacing: 8) {
                        attachmentMenu
                        VoiceDictationButton(
                            controller: voiceDictation,
                            field: .intent,
                            currentText: { model.draft },
                            onAppend: { model.draft = $0 }
                        )
                        Spacer(minLength: 0)
                        sendControl
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.black.opacity(0.12), lineWidth: 1)
                )
                .padding(10)

                // conn-004 "Delegation is three sentences": Intent (above)
                // is the message itself; these two carry through
                // ComposerIntent.composedPrompt verbatim, same as Intent.
                composerSentenceField(
                    text: $model.preferredApproach,
                    placeholder: "When I am...I like to",
                    voiceField: .preferredApproach
                )
                composerSentenceField(
                    text: $model.doneCondition,
                    placeholder: "Done looks like...",
                    voiceField: .doneCondition
                )
            }
            .padding(.vertical, 1)
            .padding(.horizontal, 6)
            .background(Theme.savyCard, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func composerSentenceField(text: Binding<String>, placeholder: String, voiceField: ComposerVoiceField) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: text, axis: .vertical)
                .font(Theme.recallBody(14))
                .foregroundStyle(Theme.savyCrimson)
                .textFieldStyle(.plain)
                .lineLimit(1...3)

            VoiceDictationButton(
                controller: voiceDictation,
                field: voiceField,
                currentText: { text.wrappedValue },
                onAppend: { text.wrappedValue = $0 }
            )
        }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.black.opacity(0.12), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
    }

    private var composerIntentSections: some View {
        HStack(alignment: .top, spacing: 6) {
            MacSuiteFormRows.composerIntentCard("Pattern") {
                MacSuiteFormRows.menuRow(
                    title: "Pattern",
                    icon: "list.number",
                    value: model.composerIntent.pattern,
                    options: MacSuiteFormCopy.patternChoices
                ) { option in
                    model.mutateComposerIntent { $0.pattern = option }
                }
            }
            .frame(maxWidth: .infinity)

            MacSuiteFormRows.composerIntentCard("Choose") {
                MacSuiteFormRows.menuRow(
                    title: "Priority",
                    icon: "exclamationmark.3",
                    value: model.composerIntent.priority,
                    options: MacSuiteFormCopy.priorityChoices
                ) { option in
                    model.mutateComposerIntent { $0.priority = option }
                }
                MacSuiteFormRows.divider()
                MacSuiteFormRows.menuRow(
                    title: "Effort",
                    icon: "timer",
                    value: model.composerIntent.effort,
                    options: MacSuiteFormCopy.effortChoices
                ) { option in
                    model.mutateComposerIntent { $0.effort = option }
                }
                MacSuiteFormRows.divider()
                MacSuiteFormRows.menuRow(
                    title: "Energy",
                    icon: "bolt",
                    value: model.composerIntent.energy,
                    options: MacSuiteFormCopy.energyChoices
                ) { option in
                    model.mutateComposerIntent { $0.energy = option }
                }
            }
            .frame(maxWidth: .infinity)

            MacSuiteFormRows.composerIntentCard("Schedule") {
                MacSuiteFormRows.scheduleRow(
                    title: "Due",
                    icon: "calendar",
                    detail: Self.formatDueDate(model.composerIntent.dueDate),
                    isOn: Binding(
                        get: { model.composerIntent.dueEnabled },
                        set: { enabled in model.mutateComposerIntent { $0.dueEnabled = enabled } }
                    ),
                    date: Binding(
                        get: { model.composerIntent.dueDate },
                        set: { date in model.mutateComposerIntent { $0.dueDate = date } }
                    ),
                    components: .date
                )
                MacSuiteFormRows.divider()
                MacSuiteFormRows.scheduleRow(
                    title: "Start / defer",
                    icon: "calendar.badge.clock",
                    detail: Self.formatDueDate(model.composerIntent.startDeferDate),
                    isOn: Binding(
                        get: { model.composerIntent.startDeferEnabled },
                        set: { enabled in model.mutateComposerIntent { $0.startDeferEnabled = enabled } }
                    ),
                    date: Binding(
                        get: { model.composerIntent.startDeferDate },
                        set: { date in model.mutateComposerIntent { $0.startDeferDate = date } }
                    ),
                    components: .date
                )
                MacSuiteFormRows.divider()
                MacSuiteFormRows.menuRow(
                    title: "Repeat",
                    icon: "repeat",
                    value: model.composerIntent.repeatRule,
                    options: MacSuiteFormCopy.repeatChoices
                ) { option in
                    model.mutateComposerIntent { $0.repeatRule = option }
                }
                MacSuiteFormRows.divider()
                MacSuiteFormRows.scheduleRow(
                    title: "Nudge",
                    icon: "bell",
                    detail: Self.formatNudgeTime(model.composerIntent.nudgeTime),
                    isOn: Binding(
                        get: { model.composerIntent.nudgeEnabled },
                        set: { enabled in model.mutateComposerIntent { $0.nudgeEnabled = enabled } }
                    ),
                    date: Binding(
                        get: { model.composerIntent.nudgeTime },
                        set: { date in model.mutateComposerIntent { $0.nudgeTime = date } }
                    ),
                    components: .hourAndMinute
                )
                MacSuiteFormRows.divider()
                MacSuiteFormRows.scheduleRow(
                    title: "End",
                    icon: "clock.badge.checkmark",
                    detail: Self.formatNudgeTime(model.composerIntent.endTime),
                    isOn: Binding(
                        get: { model.composerIntent.endEnabled },
                        set: { enabled in model.mutateComposerIntent { $0.endEnabled = enabled } }
                    ),
                    date: Binding(
                        get: { model.composerIntent.endTime },
                        set: { date in model.mutateComposerIntent { $0.endTime = date } }
                    ),
                    components: .hourAndMinute
                )
            }
            .frame(maxWidth: .infinity)

            MacSuiteFormRows.composerIntentCard("Organize") {
                MacSuiteFormRows.menuRow(
                    title: "Lift",
                    icon: "sparkles",
                    value: model.composerIntent.lift,
                    options: MacSuiteFormCopy.liftChoices
                ) { option in
                    model.mutateComposerIntent { $0.lift = option }
                }
                MacSuiteFormRows.divider()
                composerFlagRow
                MacSuiteFormRows.divider()
                composerTagsRow
                if !model.composerIntent.tags.isEmpty {
                    composerTagChips
                }
                MacSuiteFormRows.divider()
                composerRecentTagsMenu
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composerFlagRow: some View {
        HStack(spacing: 6) {
            MacSuiteFormRows.intentIcon("flag")
            Text("Flag")
                .font(Theme.savyRobotoMedium(9))
                .foregroundStyle(Color.black)
            Spacer(minLength: 4)
            MacSuiteFormRows.switchToggle(
                isOn: Binding(
                    get: { model.composerIntent.isFlagged },
                    set: { flagged in model.mutateComposerIntent { $0.isFlagged = flagged } }
                )
            )
        }
        .frame(minHeight: 18)
    }

    private var composerTagsRow: some View {
        HStack(spacing: 6) {
            MacSuiteFormRows.intentIcon("tag")
            VStack(alignment: .leading, spacing: 0) {
                Text("Tags")
                    .font(Theme.savyRobotoMedium(9))
                    .foregroundStyle(Color.black)
                Text(composerTagsDetail)
                    .font(Theme.savyRobotoMedium(8))
                    .foregroundStyle(
                        model.composerIntent.tags.isEmpty ? Theme.savyTertiaryText : Color.black.opacity(0.62)
                    )
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Text("Add")
                .font(Theme.savyRobotoMedium(9))
                .foregroundStyle(Theme.savyCrimson.opacity(model.composerIntent.tags.isEmpty ? 0.55 : 1))
        }
        .frame(minHeight: 19)
    }

    private var composerRecentTagsMenu: some View {
        let availableTags = MacSuiteFormCopy.recentTagChoices.filter {
            !model.composerIntent.tags.contains($0)
        }
        return SavyFormPicker(
            title: "Add a recent tag",
            icon: "clock.arrow.circlepath",
            value: "",
            options: availableTags.isEmpty ? MacSuiteFormCopy.recentTagChoices : availableTags,
            emphasizedTitle: true
        ) { option in
            model.mutateComposerIntent { intent in
                guard !intent.tags.contains(option) else { return }
                intent.tags.append(option)
            }
        }
        .disabled(availableTags.isEmpty)
        .opacity(availableTags.isEmpty ? 0.55 : 1)
    }

    private var composerTagsDetail: String {
        model.composerIntent.tags.isEmpty ? "Add a tag" : model.composerIntent.tags.joined(separator: ", ")
    }

    private var composerTagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.composerIntent.tags, id: \.self) { tag in
                    SavyTagChip(tag: tag) {
                        model.mutateComposerIntent { intent in
                            intent.tags.removeAll { $0 == tag }
                        }
                    }
                }
            }
            .padding(.leading, 22)
            .padding(.vertical, 2)
        }
    }

    private var composerDivider: some View {
        MacSuiteFormRows.divider()
    }

    private static let dueDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let nudgeTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static func formatDueDate(_ date: Date) -> String {
        dueDateFormatter.string(from: date)
    }

    private static func formatNudgeTime(_ date: Date) -> String {
        nudgeTimeFormatter.string(from: date)
    }

    @ViewBuilder
    private var sendControl: some View {
        if model.isRunning {
            Button { model.cancelRun() } label: {
                composerActionIcon("xmark", tint: Theme.macMuted)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        } else {
            Button(action: model.send) {
                composerActionIcon(
                    "arrow.up",
                    tint: model.canSendComposer ? Theme.savyCrimson : Theme.savyTertiaryText
                )
            }
            .buttonStyle(.plain)
            .disabled(!model.canSendComposer)
            .keyboardShortcut(.return, modifiers: [])
            .help("Send (Return; Shift-Return adds a new line)")
        }
    }

    private func composerActionIcon(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(Color.white, in: Circle())
            .overlay(Circle().stroke(Color.black.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }

    @ViewBuilder
    private func userTurnBlock(_ text: String) -> some View {
        let parsed = DelegationContext.parsePrompt(text)
        VStack(alignment: .leading, spacing: 8) {
            if !parsed.contextLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(parsed.contextLines, id: \.self) { line in
                        Text(line)
                            .font(Theme.savyRobotoMedium(9))
                            .foregroundStyle(Theme.savyCrimson)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.white, in: Capsule())
                            .overlay(Capsule().stroke(Theme.savyCrimson.opacity(0.35), lineWidth: 1))
                    }
                }
            }

            if !parsed.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(parsed.message)
                    .font(Theme.recallBody(17))
                    .foregroundStyle(Theme.savyCrimson)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.savyCard, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private func fullTurnBlock(_ turn: ConversationTurn) -> some View {
        Group {
            if turn.role == .assistant {
                assistantTurnBlock(turn.text)
            } else {
                userTurnBlock(turn.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func assistantTurnBlock(_ text: String) -> some View {
        let parsed = TranscriptAssistantTurn.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            if parsed.isBackendFailure {
                backendFailureCard(parsed.displayBody)
            } else {
                HarnessMarkdownText(
                    text: parsed.displayBody,
                    textColor: Color.black,
                    bodyFont: Theme.recallBody(17),
                    h1Font: Theme.recallSerif(20),
                    h2Font: Theme.recallBody(18, weight: .semibold)
                )
                .textSelection(.enabled)
            }

            if parsed.showsMetadataFooter {
                transcriptMetadataFooter(rule: parsed.rule, patternStep: parsed.patternStep)
            }
        }
    }

    private func backendFailureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.savyCrimson)
                    .padding(.top, 2)

                Text(message)
                    .font(Theme.recallBody(16, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if TranscriptAssistantTurn.suggestsReauthorization(message) {
                Button {
                    switch model.backend {
                    case .codex: model.authorizeCodexAccount()
                    case .grok: model.authorizeGrokAccount()
                    default: break
                    }
                } label: {
                    Label("Re-authorize \(model.backend.rawValue)", systemImage: "key.viewfinder")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.savyCrimson)
                .help("Open Terminal to refresh backend authorization")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.savyCrimson)
                .frame(width: 4)
                .padding(.vertical, 8)
                .padding(.leading, 4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.savyCrimson.opacity(0.28), lineWidth: 1)
        )
    }

    private func transcriptMetadataFooter(rule: String?, patternStep: String?) -> some View {
        HStack(spacing: 8) {
            if let rule {
                metadataChip(label: "RULE", value: rule)
            }
            if let patternStep {
                metadataChip(label: "STEP", value: patternStep)
            }
        }
    }

    private func metadataChip(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .heavy))
                .tracking(1.1)
            Text(value)
                .font(Theme.savyRobotoMedium(9))
        }
        .foregroundStyle(Theme.savyTertiaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.savyPaperAccent, in: Capsule())
    }

    private func updateEditorHeight(viewportHeight: CGFloat) {
        let lineCount = max(3, model.draft.components(separatedBy: "\n").count + 1)
        let estimated = CGFloat(lineCount) * 24 + 52
        let cap = max(viewportHeight * 0.28, 140)
        editorHeight = min(max(estimated, 108), cap)
    }

    private func scrollToLatestTurn(_ proxy: ScrollViewProxy) {
        guard let last = model.chatThread.last else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var attachmentMenu: some View {
        Menu {
            Button { model.chooseComposerPhotos() } label: {
                Label("Photo", systemImage: "photo")
            }
            Button { model.chooseComposerFiles() } label: {
                Label("File", systemImage: "doc")
            }
            Button { showAttachments = true } label: {
                Label("Link", systemImage: "link")
            }
            Divider()
            Button { model.newSession() } label: {
                Label("New", systemImage: "plus.bubble")
            }
        } label: {
            composerActionIcon("plus", tint: Theme.savyCrimson)
        }
        .menuStyle(.borderlessButton)
        .help("Add")
    }

    private var composerAttachmentChips: some View {
        HStack(spacing: 8) {
            ForEach(model.composerAttachments) { attachment in
                HStack(spacing: 4) {
                    Image(systemName: attachment.chipIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.savyCrimson)
                    Button { model.removeComposerAttachment(attachment) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Theme.macInk.opacity(0.72))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.7), in: Capsule())
                .overlay(Capsule().stroke(Color.black.opacity(0.06), lineWidth: 1))
            }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - Answer window

/// The answer is the product. These values are shared with tests so a later
/// layout change cannot quietly squeeze it back into a receipt-sized strip.
enum HarnessAnswerWindowLayout {
    static let minimumWidth: CGFloat = 920
    static let idealWidth: CGFloat = 1_080
    static let minimumHeight: CGFloat = 680
    static let idealHeight: CGFloat = 780
    static let minimumReadingHeight: CGFloat = 420
    static let contentMaxWidth: CGFloat = 980
    static let answerBodyPointSize: CGFloat = 18

    static var minimumReadingFraction: CGFloat {
        minimumReadingHeight / minimumHeight
    }

    static func fittedSize(in availableSize: CGSize, inset: CGFloat = 20) -> CGSize {
        CGSize(
            width: min(idealWidth, max(0, availableSize.width - (inset * 2))),
            height: min(idealHeight, max(0, availableSize.height - (inset * 2)))
        )
    }
}

/// Presented for every Send from either Chat or Delegation. It opens before
/// routing begins, keeps observable progress visible, carries approval cards
/// so the modal never blocks a decision, and gives the final answer the full
/// reading surface instead of the leftover space beneath the composer.
struct MacAnswerWindowView: View {
    @ObservedObject var model: MacWorkbenchModel
    @ObservedObject private var approvals: ToolApprovalStore

    init(model: MacWorkbenchModel) {
        self.model = model
        self.approvals = model.toolApprovals
    }

    private var latestAnswer: String? {
        model.answerWindowAnswer
    }

    private var isWorking: Bool {
        model.isRunning && latestAnswer == nil
    }

    private var canClose: Bool {
        !model.isRunning && approvals.pendingRequests.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            answerWindowHeader

            if isWorking {
                if let monitor = model.activeToolLoop {
                    HarnessAnswerProgressView(
                        monitor: monitor,
                        fallbackStatus: model.status
                    )
                } else {
                    startingProgress
                }
            } else {
                answerReadyBar
            }

            Divider().overlay(Color.black.opacity(0.08))

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 22) {
                    requestCard

                    ForEach(approvals.pendingRequests) { request in
                        MacToolApprovalCard(
                            request: request,
                            onApprove: { always in
                                model.approveToolRequest(request, always: always)
                            },
                            onDeny: {
                                model.denyToolRequest(request)
                            }
                        )
                    }

                    if let latestAnswer {
                        answerContent(latestAnswer)
                    } else {
                        waitingForAnswer
                    }
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 28)
                .frame(maxWidth: HarnessAnswerWindowLayout.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            .layoutPriority(1)
            .accessibilityIdentifier("harness-answer-content")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.macBg)
        .accessibilityIdentifier("harness-answer-window")
    }

    private var answerWindowHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isWorking ? "WORKING NOW" : "ANSWER")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(Theme.macRed)
                Text(isWorking ? "Harness started when you pressed Send." : "Your answer is ready.")
                    .font(Theme.recallSerif(24))
                    .foregroundStyle(Color.white)
            }

            Spacer(minLength: 16)

            if model.isRunning {
                Button("Cancel") {
                    model.cancelRun()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.macRed, in: Capsule())
                .help("Cancel this response")
            }

            Button {
                model.isAnswerWindowPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canClose)
            .opacity(canClose ? 1 : 0.45)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(canClose ? "Close answer window" : "Cancel the response before closing")
            .help(canClose ? "Close answer window" : "Cancel the response before closing")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Theme.savyDeepNavy)
    }

    private var startingProgress: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.savyCrimson)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Request received. Starting now.")
                    .font(Theme.recallBody(16, weight: .semibold))
                    .foregroundStyle(Color.black)
                Text("The next retrieval or model step will appear here as it begins.")
                    .font(Theme.recallBody(13))
                    .foregroundStyle(Color.black.opacity(0.58))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.savyPaperAccent)
        .accessibilityIdentifier("harness-answer-progress")
    }

    private var answerReadyBar: some View {
        HStack(spacing: 10) {
            Image(systemName: model.status == "Cancelled" ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(model.status == "Cancelled" ? Theme.savyCrimson : Theme.savyGreen)
            Text(model.status == "Cancelled" ? "Request cancelled" : "Answer ready to read")
                .font(Theme.recallBody(15, weight: .semibold))
                .foregroundStyle(Color.black)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Theme.savyPaperAccent)
        .accessibilityIdentifier("harness-answer-ready")
    }

    private var requestCard: some View {
        let parsed = DelegationContext.parsePrompt(model.answerWindowPrompt)
        let visiblePrompt = parsed.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? model.answerWindowPrompt
            : parsed.message

        return VStack(alignment: .leading, spacing: 7) {
            Text("YOUR REQUEST")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.8)
                .foregroundStyle(Theme.savyCrimson)
            Text(visiblePrompt)
                .font(Theme.recallBody(16))
                .foregroundStyle(Color.black.opacity(0.72))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.savyCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var waitingForAnswer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ANSWER")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.8)
                .foregroundStyle(Theme.savyCrimson)
            Text("Harness is working on the answer now.")
                .font(Theme.recallSerif(28))
                .foregroundStyle(Color.black)
            Text("Live progress stays above. The complete answer will use this reading surface as soon as it is ready.")
                .font(Theme.recallBody(16))
                .foregroundStyle(Color.black.opacity(0.58))
        }
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .accessibilityIdentifier("harness-answer-waiting")
    }

    @ViewBuilder
    private func answerContent(_ text: String) -> some View {
        let parsed = TranscriptAssistantTurn.parse(text)
        VStack(alignment: .leading, spacing: 14) {
            Text("ANSWER")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.8)
                .foregroundStyle(Theme.savyCrimson)

            if parsed.isBackendFailure {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Harness could not finish the response", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.recallBody(18, weight: .semibold))
                        .foregroundStyle(Theme.savyCrimson)
                    Text(parsed.displayBody)
                        .font(Theme.recallBody(HarnessAnswerWindowLayout.answerBodyPointSize))
                        .foregroundStyle(Color.black)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if TranscriptAssistantTurn.suggestsReauthorization(parsed.displayBody) {
                        Button {
                            authorizeCurrentBackend()
                        } label: {
                            Label("Re-authorize \(model.backend.rawValue)", systemImage: "key.viewfinder")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.savyCrimson)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.savyCrimson.opacity(0.30), lineWidth: 2)
                )
            } else {
                HarnessMarkdownText(
                    text: parsed.displayBody,
                    textColor: Color.black,
                    bodyFont: Theme.recallBody(HarnessAnswerWindowLayout.answerBodyPointSize),
                    h1Font: Theme.recallSerif(28),
                    h2Font: Theme.recallBody(22, weight: .semibold)
                )
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("harness-answer-result")
    }

    private func authorizeCurrentBackend() {
        switch model.backend {
        case .codex: model.authorizeCodexAccount()
        case .grok: model.authorizeGrokAccount()
        default: break
        }
    }
}

private struct HarnessAnswerProgressView: View {
    @ObservedObject var monitor: ToolLoopMonitor
    let fallbackStatus: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.savyCrimson)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(phaseCommentary)
                        .font(Theme.recallBody(16, weight: .semibold))
                        .foregroundStyle(Color.black)
                    if let detailLine {
                        Text(detailLine)
                            .font(Theme.recallBody(13))
                            .foregroundStyle(Color.black.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                progressChip("Request received", value: nil)
                if !monitor.progress.acceptedEvidence.isEmpty {
                    progressChip("Accepted", value: monitor.progress.acceptedEvidence.count)
                }
                if !monitor.progress.supportingEvidence.isEmpty {
                    progressChip("Supporting", value: monitor.progress.supportingEvidence.count)
                }
                if !monitor.progress.toolEvidence.isEmpty {
                    progressChip("Tool evidence", value: monitor.progress.toolEvidence.count)
                }
                if monitor.progress.iteration > 0 {
                    progressChip("Step", value: monitor.progress.iteration)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.savyPaperAccent)
        .accessibilityIdentifier("harness-answer-progress")
    }

    private var phaseCommentary: String {
        switch monitor.progress.phase {
        case .idle:
            return "Request received. Starting now."
        case .checkingGraph:
            return "Checking your accepted graph first."
        case .retrievingAuthority:
            return "Finding accepted knowledge that directly supports the answer."
        case .retrievingMemory:
            return "Looking for supporting memory without treating it as accepted authority."
        case .callingModel:
            return "Building the answer from the evidence now."
        case .runningTool:
            return "Using \(monitor.progress.currentTool ?? "a tool") to gather what the answer needs."
        case .finished:
            return "Putting the completed answer on screen."
        case .budgetExhausted:
            return "The tool budget ended; preserving the evidence already gathered."
        case .deadlineExceeded:
            return "The response ceiling was reached; showing the evidence already retrieved."
        case .cancelled:
            return "Cancelling the run now."
        case .failed:
            return "The run stopped with an error."
        }
    }

    private var detailLine: String? {
        if monitor.progress.phase == .runningTool,
           let tool = monitor.progress.currentTool,
           !tool.isEmpty {
            return "Current tool: \(tool)"
        }
        let trimmed = fallbackStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 180 else { return nil }
        return trimmed
    }

    private func progressChip(_ label: String, value: Int?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.savyGreen)
            Text(value.map { "\(label) \($0)" } ?? label)
                .font(Theme.savyRobotoMedium(10))
                .foregroundStyle(Color.black.opacity(0.62))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(Color.black.opacity(0.07), lineWidth: 1))
    }
}

// MARK: - The bouncer's approval card

/// The law rendered as UI: "Agents propose. The bouncer checks. You decide."
/// A suspended tool call shows exactly what the agent proposes — command,
/// path, or content preview, verbatim — and waits for Adam. Approve unblocks
/// the one call; Always allow also persists the fired pattern ids; Deny feeds
/// the refusal back to the agent as an error result and the loop continues.
private struct MacToolApprovalCard: View {
    let request: ToolApprovalRequest
    let onApprove: (_ always: Bool) -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SavyDarkCard(
                badge: "Agents propose. The bouncer checks. You decide.",
                badgeIcon: "shield.lefthalf.filled",
                title: request.toolName,
                detail: request.reason
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("PROPOSED")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.8)
                    .foregroundStyle(Theme.savyTertiaryText)

                Text(request.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.black)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.savyCard, in: RoundedRectangle(cornerRadius: 8))

                if let detail = request.detail,
                   !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.black.opacity(0.72))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .padding(10)
                    .background(Theme.savyCard, in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 10) {
                    approvalButton("Deny", role: .secondary) { onDeny() }
                        .help("Refuse this call; the agent is told no and keeps going")

                    Spacer(minLength: 8)

                    if !request.patternIds.isEmpty {
                        approvalButton("Always allow", role: .secondary) { onApprove(true) }
                            .help("Approve and allowlist this pattern for future runs")
                    }

                    approvalButton("Approve", role: .primary) { onApprove(false) }
                        .help("Let this one call run")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
    }

    private enum ButtonRole {
        case primary
        case secondary
    }

    private func approvalButton(
        _ title: String,
        role: ButtonRole,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(role == .primary ? Color.white : Color.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    role == .primary ? Theme.savyCrimson : Color.white,
                    in: Capsule()
                )
                .overlay(Capsule().stroke(Color.black.opacity(role == .primary ? 0 : 0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Live tool-loop status

/// Updating status row for an active run: current phase, running tool,
/// iteration budget, and a Cancel control that aborts the loop and kills any
/// tool subprocesses.
private struct MacToolLoopStatusRow: View {
    @ObservedObject var monitor: ToolLoopMonitor
    let fallbackStatus: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.savyCrimson)

            Text(statusText)
                .font(Theme.savyRobotoMedium(10))
                .foregroundStyle(Color.black.opacity(0.62))
                .lineLimit(1)

            if monitor.progress.iteration > 0 {
                Text("\(monitor.progress.iteration)/\(monitor.progress.maxIterations)")
                    .font(Theme.savyRobotoMedium(9))
                    .foregroundStyle(Theme.savyTertiaryText)
            }

            Spacer(minLength: 8)

            Button("Cancel") { onCancel() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.savyCrimson)
                .help("Cancel the run and kill any tool subprocesses")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var statusText: String {
        switch monitor.progress.phase {
        case .idle:
            return fallbackStatus
        case .checkingGraph:
            return "Checking accepted graph…"
        case .retrievingAuthority:
            return "Finding accepted knowledge…"
        case .retrievingMemory:
            return "Searching supporting memory…"
        case .callingModel:
            return "Calling model…"
        case .runningTool:
            return "Running \(monitor.progress.currentTool ?? "tool")…"
        case .finished:
            return "Finishing…"
        case .budgetExhausted:
            return "Tool budget exhausted"
        case .deadlineExceeded:
            return "Showing retrieved evidence…"
        case .cancelled:
            return "Cancelling…"
        case .failed:
            return fallbackStatus
        }
    }
}

private struct MacComposerAttachmentSheet: View {
    @ObservedObject var model: MacWorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var linkInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("", text: $linkInput, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.recallBody(16))
                .foregroundStyle(Theme.macEntryInk)
                .lineLimit(1...3)
                .padding(12)
                .background(Theme.macEntry, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                Button {
                    model.addComposerLink(linkInput)
                    linkInput = ""
                    dismiss()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(linkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Color.white)
    }
}
#endif
