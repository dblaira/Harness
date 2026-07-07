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
                                .tint(Theme.macInk.opacity(0.5))
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
        VStack(alignment: .leading, spacing: 8) {
            if !model.composerAttachments.isEmpty {
                composerAttachmentChips
            }

            HStack(alignment: .bottom, spacing: 12) {
                TextEditor(text: $model.draft)
                    .font(Theme.recallBody(17))
                    .foregroundStyle(Theme.macEntryInk)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(height: editorHeight)
                    .background(Theme.macEntry, in: RoundedRectangle(cornerRadius: 10))
                    .focused($questionFocused)

                VStack(spacing: 10) {
                    attachmentMenu
                    sendControl
                }
                .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private var sendControl: some View {
        if model.isRunning {
            Button { model.cancelRun() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.macInk.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("Cancel")
        } else {
            Button(action: model.send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(model.canSendComposer ? Theme.macRed : Theme.macInk.opacity(0.25))
            }
            .buttonStyle(.plain)
            .disabled(!model.canSendComposer)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send")
        }
    }

    private func fullTurnBlock(_ turn: ConversationTurn) -> some View {
        Group {
            if turn.role == .assistant {
                HarnessMarkdownText(
                    text: turn.text,
                    textColor: Theme.macInk,
                    bodyFont: Theme.recallBody(17),
                    h1Font: Theme.recallSerif(20),
                    h2Font: Theme.recallBody(18, weight: .semibold)
                )
                .textSelection(.enabled)
            } else {
                Text(turn.text)
                    .font(Theme.recallBody(17))
                    .foregroundStyle(Theme.macInk.opacity(0.92))
                    .textSelection(.enabled)
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
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Theme.macInk.opacity(0.55))
        }
        .menuStyle(.borderlessButton)
        .help("Add")
    }

    private var composerAttachmentChips: some View {
        HStack(spacing: 8) {
            ForEach(model.composerAttachments) { attachment in
                HStack(spacing: 4) {
                    Image(systemName: attachment.chipIcon)
                        .font(.system(size: 13, weight: .semibold))
                    Button { model.removeComposerAttachment(attachment) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(Theme.macInk.opacity(0.6))
            }
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
        .background(Theme.macBg)
    }
}
#endif