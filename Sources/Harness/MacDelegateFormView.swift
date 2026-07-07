#if os(macOS)
import SwiftUI
import OntologyKit

/// One centered column: full session text top-to-bottom, composer stays in the
/// middle of the viewport while you type or dictate.
struct MacDelegateFormView: View {
    @ObservedObject var model: MacWorkbenchModel
    @State private var showAttachments = false
    @State private var editorHeight: CGFloat = 140
    @FocusState private var questionFocused: Bool

    private let columnMaxWidth: CGFloat = 780

    var body: some View {
        GeometryReader { proxy in
            let viewportHeight = proxy.size.height

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(model.chatThread) { turn in
                            fullTurnBlock(turn)
                                .id(turn.id)
                        }

                        composerBlock
                            .id("composer")

                        if model.isRunning {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text(model.status)
                                    .foregroundStyle(Theme.macInk.opacity(0.55))
                            }
                            .id("running-status")
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 36)
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

    private var composerBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("YOUR QUESTION")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.macInk.opacity(0.5))
                Spacer()
                if !model.composerAttachments.isEmpty {
                    Text("\(model.composerAttachments.count) attached")
                        .font(.caption)
                        .foregroundStyle(Theme.macInk.opacity(0.55))
                }
            }

            if !model.composerAttachments.isEmpty {
                composerAttachmentChips
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.draft)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.macInk)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .focused($questionFocused)

                if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Say it here — everything stays in this column, centered on your screen.")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.macFaint)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 20)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: editorHeight)
            .background(Theme.macEntry.opacity(0.38), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.macHair, lineWidth: 1))

            HStack(spacing: 12) {
                attachmentMenu
                Spacer()
                if model.isRunning {
                    Button("Cancel") { model.cancelRun() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.macRed)
                }
                Button(action: model.send) {
                    Label(model.isRunning ? "Running…" : "Get Answer", systemImage: "arrow.up.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.macInk)
                .disabled(!model.canSendComposer)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func fullTurnBlock(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(turn.role == .user ? "YOU" : "ANSWER")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.macInk.opacity(0.5))
                Spacer()
                copyButton(label: "Copy", text: turn.text)
            }

            if turn.role == .assistant {
                HarnessMarkdownText(
                    text: turn.text,
                    textColor: Theme.macInk,
                    bodyFont: .system(size: 16),
                    h1Font: .system(.title2, design: .serif).weight(.semibold),
                    h2Font: .headline
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(turn.text)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.macInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.macEntry.opacity(turn.role == .user ? 0.32 : 0.18),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.macHair, lineWidth: 1))
    }

    private func updateEditorHeight(viewportHeight: CGFloat) {
        let lineCount = max(4, model.draft.components(separatedBy: "\n").count + 1)
        let estimated = CGFloat(lineCount) * 24 + 48
        let cap = max(viewportHeight * 0.55, 200)
        editorHeight = min(max(estimated, 140), cap)
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
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
    }

    private var composerAttachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.composerAttachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.chipIcon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(attachment.chipLabel)
                            .font(.caption)
                            .lineLimit(1)
                        Button { model.removeComposerAttachment(attachment) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(Theme.macInk.opacity(0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.macEntry.opacity(0.42), in: Capsule())
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
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.macInk.opacity(0.72))
    }
}

private struct MacComposerAttachmentSheet: View {
    @ObservedObject var model: MacWorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var linkInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Link or GitHub Repo")
                .font(.headline)
            TextField("URL or owner/repo", text: $linkInput, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .padding(12)
                .background(Theme.macEntry.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    model.addComposerLink(linkInput)
                    linkInput = ""
                    dismiss()
                }
                .disabled(linkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
#endif