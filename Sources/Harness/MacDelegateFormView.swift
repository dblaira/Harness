#if os(macOS)
import SwiftUI
import OntologyKit

/// Notorious Recall styling: navy page, cream question form, white answer cards.
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
                    VStack(alignment: .leading, spacing: 28) {
                        recallHero

                        ForEach(model.chatThread) { turn in
                            fullTurnBlock(turn)
                                .id(turn.id)
                        }

                        composerBlock
                            .id("composer")

                        if model.isRunning {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small).tint(Theme.macRed)
                                Text(model.status)
                                    .font(Theme.recallBody(16))
                                    .foregroundStyle(Theme.macMuted)
                            }
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

    private var recallHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Harness")
                .font(Theme.recallSerif(34))
                .foregroundStyle(Theme.macTan)
            Rectangle()
                .fill(Theme.macRed)
                .frame(height: 2)
                .padding(.top, 10)
        }
        .padding(.bottom, 4)
    }

    private var composerBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("YOUR QUESTION")

            if !model.composerAttachments.isEmpty {
                composerAttachmentChips
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.draft)
                    .font(Theme.recallBody(17))
                    .foregroundStyle(Theme.macEntryInk)
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .focused($questionFocused)

                if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Say it here — cream field on navy, like Notorious Recall.")
                        .font(Theme.recallBody(17))
                        .foregroundStyle(Theme.macFaint)
                        .padding(.horizontal, 19)
                        .padding(.vertical, 22)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: editorHeight)
            .background(Theme.macEntry, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.macHair, lineWidth: 1))

            HStack(spacing: 12) {
                attachmentMenu
                Spacer()
                if model.isRunning {
                    Button("Cancel") { model.cancelRun() }
                        .buttonStyle(.plain)
                        .font(Theme.recallBody(15, weight: .semibold))
                        .foregroundStyle(Theme.macRed)
                }
                Button(action: model.send) {
                    Label(model.isRunning ? "Running…" : "Get Answer", systemImage: "arrow.up.circle.fill")
                        .font(Theme.recallBody(15, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.macRed)
                .disabled(!model.canSendComposer)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func fullTurnBlock(_ turn: ConversationTurn) -> some View {
        let isUser = turn.role == .user
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionLabel(isUser ? "YOU" : "ANSWER")
                Spacer()
                copyButton(label: "Copy", text: turn.text)
            }

            if turn.role == .assistant {
                HarnessMarkdownText(
                    text: turn.text,
                    textColor: Theme.macCardInk,
                    bodyFont: Theme.recallBody(17),
                    h1Font: Theme.recallSerif(22),
                    h2Font: Theme.recallBody(18, weight: .bold)
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(turn.text)
                    .font(Theme.recallBody(17))
                    .foregroundStyle(Theme.macEntryInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isUser ? Theme.macEntry : Theme.macCardBright,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.macHair, lineWidth: 1))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.recallLabel())
            .tracking(2.2)
            .foregroundStyle(Theme.macTan)
    }

    private func updateEditorHeight(viewportHeight: CGFloat) {
        let lineCount = max(4, model.draft.components(separatedBy: "\n").count + 1)
        let estimated = CGFloat(lineCount) * 26 + 52
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
                Label("Link or GitHub", systemImage: "link")
            }
            Divider()
            Button { model.newSession() } label: {
                Label("New Session", systemImage: "plus.bubble")
            }
        } label: {
            Label("Attach", systemImage: "paperclip")
                .font(Theme.recallBody(14, weight: .semibold))
                .foregroundStyle(Theme.macTan)
        }
        .menuStyle(.borderlessButton)
    }

    private var composerAttachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.composerAttachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.chipIcon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(attachment.chipLabel)
                            .font(Theme.recallBody(13, weight: .medium))
                            .lineLimit(1)
                        Button { model.removeComposerAttachment(attachment) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(Theme.macEntryInk.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.macEntry, in: Capsule())
                    .overlay(Capsule().stroke(Theme.macHair, lineWidth: 1))
                }
            }
        }
    }

    private func copyButton(label: String, text: String) -> some View {
        Button {
            HarnessClipboard.copy(text)
        } label: {
            Label(label, systemImage: "doc.on.doc")
                .font(Theme.recallBody(13, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.macRed)
    }
}

private struct MacComposerAttachmentSheet: View {
    @ObservedObject var model: MacWorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var linkInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Link or GitHub Repo")
                .font(Theme.recallSerif(22))
                .foregroundStyle(Theme.macBarInk)
            TextField("URL or owner/repo", text: $linkInput, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.recallBody(16))
                .foregroundStyle(Theme.macEntryInk)
                .lineLimit(1...3)
                .padding(12)
                .background(Theme.macEntry, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    model.addComposerLink(linkInput)
                    linkInput = ""
                    dismiss()
                }
                .tint(Theme.macRed)
                .disabled(linkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.macBarBg)
    }
}
#endif