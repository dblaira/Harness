#if os(macOS)
import SwiftUI
import OntologyKit

/// Words only in the editor and in thread content. Plus to attach, arrow to send.
struct MacDelegateFormView: View {
    @ObservedObject var model: MacWorkbenchModel
    @State private var showAttachments = false
    @State private var editorHeight: CGFloat = 156
    @FocusState private var questionFocused: Bool

    private let columnMaxWidth: CGFloat = 780

    var body: some View {
        GeometryReader { proxy in
            let viewportHeight = proxy.size.height

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(model.chatThread) { turn in
                            fullTurnBlock(turn)
                                .id(turn.id)
                        }

                        composerBlock
                            .id("composer")

                        if model.isRunning {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Theme.savyCrimson)
                                .frame(maxWidth: .infinity)
                                .id("running-status")
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: columnMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: viewportHeight, alignment: .center)
                }
                .onAppear {
                    keepComposerCentered(scrollProxy, viewportHeight: viewportHeight)
                }
                .onChange(of: model.draft) { _, _ in
                    updateEditorHeight(viewportHeight: viewportHeight)
                    keepComposerCentered(scrollProxy, viewportHeight: viewportHeight)
                }
                .tint(Theme.savyCrimson)
                .onChange(of: model.chatThread.count) { _, _ in
                    if let last = model.chatThread.last, last.role == .assistant {
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.2)) {
                                scrollProxy.scrollTo(last.id, anchor: .center)
                            }
                        }
                    } else {
                        keepComposerCentered(scrollProxy, viewportHeight: viewportHeight)
                    }
                }
                .onChange(of: model.isRunning) { _, _ in
                    keepComposerCentered(scrollProxy, viewportHeight: viewportHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.macBg)
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
                if !model.composerAttachments.isEmpty {
                    composerAttachmentChips
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    composerDivider
                }

                HStack(alignment: .bottom, spacing: 10) {
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
                            .padding(.vertical, 8)
                            .frame(height: editorHeight)
                            .focused($questionFocused)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )

                    VStack(spacing: 8) {
                        attachmentMenu
                        sendControl
                    }
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                }
                .padding(10)
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

    private var composerIntentSections: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                MacSuiteFormRows.composerIntentCard("Pattern") {
                    MacSuiteFormRows.menuRow(
                        title: "Pattern",
                        icon: "list.number",
                        selection: composerBinding(\.pattern),
                        options: MacSuiteFormCopy.patternChoices
                    )
                }

                MacSuiteFormRows.composerIntentCard("Choose") {
                    MacSuiteFormRows.menuRow(
                        title: "Priority",
                        icon: "exclamationmark.3",
                        selection: composerBinding(\.priority),
                        options: MacSuiteFormCopy.priorityChoices
                    )
                    MacSuiteFormRows.divider()
                    MacSuiteFormRows.menuRow(
                        title: "Effort",
                        icon: "timer",
                        selection: composerBinding(\.effort),
                        options: MacSuiteFormCopy.effortChoices
                    )
                    MacSuiteFormRows.divider()
                    MacSuiteFormRows.menuRow(
                        title: "Energy",
                        icon: "bolt",
                        selection: composerBinding(\.energy),
                        options: MacSuiteFormCopy.energyChoices
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                MacSuiteFormRows.composerIntentCard("Schedule") {
                    MacSuiteFormRows.scheduleRow(
                        title: "Due",
                        icon: "calendar",
                        detail: Self.formatDueDate(model.composerIntent.dueDate),
                        isOn: composerBinding(\.dueEnabled),
                        date: composerBinding(\.dueDate),
                        components: .date
                    )
                    MacSuiteFormRows.divider()
                    MacSuiteFormRows.scheduleRow(
                        title: "Nudge",
                        icon: "bell",
                        detail: Self.formatNudgeTime(model.composerIntent.nudgeTime),
                        isOn: composerBinding(\.nudgeEnabled),
                        date: composerBinding(\.nudgeTime),
                        components: .hourAndMinute
                    )
                }

                MacSuiteFormRows.composerIntentCard("Organize") {
                    MacSuiteFormRows.menuRow(
                        title: "Lift",
                        icon: "sparkles",
                        selection: composerBinding(\.lift),
                        options: MacSuiteFormCopy.liftChoices
                    )
                    MacSuiteFormRows.divider()
                    composerFlagRow
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func composerBinding<Value>(_ keyPath: WritableKeyPath<ComposerIntent, Value>) -> Binding<Value> {
        Binding(
            get: { model.composerIntent[keyPath: keyPath] },
            set: { value in model.mutateComposerIntent { $0[keyPath: keyPath] = value } }
        )
    }

    private var composerFlagRow: some View {
        HStack(spacing: 6) {
            MacSuiteFormRows.intentIcon("flag")
            Text("Flag")
                .font(Theme.savyRobotoMedium(9))
                .foregroundStyle(Color.black)
            Spacer(minLength: 0)
            MacSuiteFormRows.switchToggle(isOn: composerBinding(\.isFlagged))
        }
        .frame(minHeight: 16)
        .padding(.vertical, 1)
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
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send")
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
                HarnessMarkdownText(
                    text: turn.text,
                    textColor: Color.black,
                    bodyFont: Theme.recallBody(17),
                    h1Font: Theme.recallSerif(20),
                    h2Font: Theme.recallBody(18, weight: .semibold)
                )
                .textSelection(.enabled)
            } else {
                userTurnBlock(turn.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func updateEditorHeight(viewportHeight: CGFloat) {
        let lineCount = max(4, model.draft.components(separatedBy: "\n").count + 1)
        let estimated = CGFloat(lineCount) * 26 + 48
        let cap = max(viewportHeight * 0.55, 220)
        editorHeight = min(max(estimated, 156), cap)
    }

    private func keepComposerCentered(_ proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("composer", anchor: .center)
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