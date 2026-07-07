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
        VStack(alignment: .leading, spacing: 6) {
            Text("Delegate")
                .font(Theme.savyRobotoMedium(11))
                .foregroundStyle(Color.black.opacity(0.48))
                .padding(.leading, 8)

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
                            .foregroundStyle(Theme.macEntryInk)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(height: editorHeight)
                            .focused($questionFocused)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 8) {
                        attachmentMenu
                        sendControl
                    }
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                }
            }
            .background(Theme.macEntry, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.black.opacity(0.07), lineWidth: 1)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 14, y: 7)
    }

    private var composerDivider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 12)
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
                    tint: model.canSendComposer ? Theme.macRed : Theme.macFaint
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
                    .foregroundStyle(Theme.macInk)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.macEntry, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.black.opacity(0.07), lineWidth: 1)
                    )
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
            composerActionIcon("plus", tint: Theme.macRed)
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
                        .foregroundStyle(Theme.macRed)
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