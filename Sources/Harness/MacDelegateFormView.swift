#if os(macOS)
import SwiftUI
import OntologyKit

/// Question-on-top, answer-below form layout. The answer panel owns the screen;
/// prior turns stay collapsed so the latest response is always visible.
struct MacDelegateFormView: View {
    @ObservedObject var model: MacWorkbenchModel
    @State private var showEarlierTurns = false
    @State private var showAttachments = false
    @FocusState private var questionFocused: Bool

    private var latestAssistantText: String {
        if let turn = model.chatThread.last(where: { $0.role == .assistant }) {
            return turn.text
        }
        if let detail = model.selectedDetail {
            return HarnessTranscriptCopy.assistantAnswer(from: detail)
        }
        return ""
    }

    private var earlierTurns: [ConversationTurn] {
        guard model.chatThread.count > 2 else { return [] }
        return Array(model.chatThread.dropLast(2))
    }

    var body: some View {
        GeometryReader { proxy in
            let questionHeight = min(max(proxy.size.height * 0.26, 132), 240)

            VStack(spacing: 0) {
                questionPanel(height: questionHeight)
                Divider().overlay(Theme.macHair)
                answerPanel
                statusRow
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.macBg)
        .sheet(isPresented: $showAttachments) {
            MacComposerAttachmentSheet(model: model)
        }
    }

    private func questionPanel(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.macInk)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .focused($questionFocused)

                if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("What do you want Harness to answer?")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.macFaint)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: max(height - 52, 80))
            .background(Theme.macEntry.opacity(0.38), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.macHair, lineWidth: 1))

            HStack(spacing: 10) {
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
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(height: height)
    }

    private var answerPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Color.clear.frame(height: 1).id("answer-top")

                    HStack(spacing: 8) {
                        Text("ANSWER")
                            .font(.caption.weight(.bold))
                            .tracking(1.4)
                            .foregroundStyle(Theme.macInk.opacity(0.5))
                        Spacer()
                        if !latestAssistantText.isEmpty {
                            copyButton(label: "Copy answer", text: latestAssistantText)
                        }
                    }

                    if !earlierTurns.isEmpty {
                        DisclosureGroup(
                            isExpanded: $showEarlierTurns,
                            content: {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(earlierTurns) { turn in
                                        compactTurnRow(turn)
                                    }
                                }
                                .padding(.top, 6)
                            },
                            label: {
                                Text("Earlier in this session (\(earlierTurns.count) messages)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.macInk.opacity(0.62))
                            }
                        )
                        .padding(12)
                        .background(Theme.macEntry.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
                    }

                    if model.isRunning {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(model.status)
                                .foregroundStyle(Theme.macInk.opacity(0.55))
                        }
                        .padding(.vertical, 8)
                    } else if latestAssistantText.isEmpty {
                        Text("Your answer will appear here — full width, no scrolling to hunt for it.")
                            .font(.body)
                            .foregroundStyle(Theme.macInk.opacity(0.42))
                            .padding(.vertical, 24)
                    } else {
                        HarnessMarkdownText(
                            text: latestAssistantText,
                            textColor: Theme.macInk,
                            bodyFont: .system(size: 15),
                            h1Font: .system(.title2, design: .serif).weight(.semibold),
                            h2Font: .headline
                        )
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("latest-answer")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: latestAssistantText) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("answer-top", anchor: .top)
                }
            }
            .onChange(of: model.isRunning) { _, running in
                if running {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("answer-top", anchor: .top)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            if let detail = model.selectedDetail {
                statusPill("\(detail.authorityHits.count) authority", "point.3.connected.trianglepath.dotted")
                statusPill("\(detail.memoryHits.count) memory", "archivebox")
                statusPill(detail.run.success ? "trace saved" : "failed saved", detail.run.success ? "checkmark.seal" : "exclamationmark.triangle")
            }
            Spacer()
            if let statusText = HarnessTranscriptCopy.statusCopyText(status: model.status) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(Theme.macRed.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .overlay(Rectangle().fill(Theme.macHair).frame(height: 1), alignment: .top)
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

    private func compactTurnRow(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.role == .user ? "You" : "Harness")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.macInk.opacity(0.45))
            Text(turn.text)
                .font(.caption)
                .foregroundStyle(Theme.macInk.opacity(0.78))
                .lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusPill(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(Theme.macInk.opacity(0.65))
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

/// Lightweight sheet for link/GitHub attachment entry (reuses model draft helpers).
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