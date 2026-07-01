import SwiftUI
import OntologyKit

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let fromMe: Bool
}

struct ChatView: View {
    let ontology: Ontology

    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var thinking = false
    @State private var backend: Backend = ChatView.defaultBackend
    @State private var apiKey = ChatView.initialAPIKey()
    @State private var hasConfiguredAPIKey = !ChatView.initialAPIKey().isEmpty
    @State private var mode: HarnessLaunchMode = .ask
    @State private var selectedQuickAction: HarnessQuickAction.ID?
    @State private var showingAttachmentMenu = false
    @State private var ledger = ChatView.makeLedger()
    @State private var latestRunDetail: HarnessRunDetail?
    @State private var ledgerStatus = "Ledger ready"

    var body: some View {
        ZStack {
            Theme.iosBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                HarnessTopBar(mode: $mode)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)

                HarnessConversationStage(
                    messages: messages,
                    backend: backend,
                    thinking: thinking,
                    latestRunDetail: latestRunDetail,
                    ledgerStatus: ledgerStatus
                )

                HarnessQuickActionCarousel(
                    actions: HarnessQuickAction.defaults,
                    selectedID: selectedQuickAction,
                    onSelect: selectQuickAction
                )
                .padding(.bottom, 14)

                HarnessComposer(
                    draft: $draft,
                    backend: $backend,
                    apiKey: $apiKey,
                    hasConfiguredAPIKey: hasConfiguredAPIKey,
                    thinking: thinking,
                    mode: mode,
                    onAttach: { showingAttachmentMenu = true },
                    onSpeak: beginVoice,
                    onSaveAPIKey: { _ = saveClaudeKey() },
                    onSubmit: send
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog("Add", isPresented: $showingAttachmentMenu, titleVisibility: .visible) {
            Button("Photos") {}
            Button("Files") {}
            Button("Saved items") {}
            Button("Cancel", role: .cancel) {}
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private func selectQuickAction(_ action: HarnessQuickAction) {
        selectedQuickAction = action.id
        mode = action.mode
    }

    private func beginVoice() {
        selectedQuickAction = "speak"
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking else { return }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if backend == .claude && trimmedKey.isEmpty {
            ledgerStatus = "Claude API key required"
            return
        }

        if backend == .claude && !hasConfiguredAPIKey && !saveClaudeKey() {
            return
        }

        messages.append(ChatMessage(text: text, fromMe: true))
        draft = ""
        thinking = true
        let chosen = backend
        let key = trimmedKey.isEmpty ? nil : trimmedKey
        let service = HarnessRunService(ledger: ledger)
        Task {
            do {
                let detail = try await service.createRun(
                    prompt: text,
                    ontology: ontology,
                    backend: AgentRunnerBackendAdapter(backend: chosen, apiKey: key)
                )
                let reply = detail.messages.last { $0.role == .assistant }?.text ?? detail.run.finalAnswer
                await MainActor.run {
                    messages.append(ChatMessage(text: reply, fromMe: false))
                    latestRunDetail = detail
                    ledgerStatus = detail.run.success ? "Trace saved" : "Backend failed; trace saved"
                    thinking = false
                }
            } catch {
                await MainActor.run {
                    if chosen == .claude && ChatView.isClaudeAuthenticationError(error) {
                        try? APIKeyStore.deleteClaudeKey()
                        hasConfiguredAPIKey = false
                        apiKey = ""
                    }
                    messages.append(ChatMessage(text: "Error: \(error.localizedDescription)", fromMe: false))
                    ledgerStatus = error.localizedDescription
                    thinking = false
                }
            }
        }
    }

    @discardableResult
    private func saveClaudeKey() -> Bool {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            ledgerStatus = "Claude API key required"
            return false
        }

        do {
            try APIKeyStore.saveClaudeKey(trimmedKey)
            apiKey = trimmedKey
            hasConfiguredAPIKey = true
            ledgerStatus = "Claude key saved locally"
            return true
        } catch {
            ledgerStatus = error.localizedDescription
            return false
        }
    }

    private static func makeLedger() -> RunLedgerStore {
        do {
            return try RunLedgerStore.applicationDefault()
        } catch {
            return try! RunLedgerStore.inMemory()
        }
    }

    private static var defaultBackend: Backend {
        #if os(iOS)
        .claude
        #else
        .codex
        #endif
    }

    private static func initialAPIKey() -> String {
        #if os(iOS)
        APIKeyStore.loadClaudeKey() ?? ""
        #else
        ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? APIKeyStore.loadClaudeKey() ?? ""
        #endif
    }

    private static func isClaudeAuthenticationError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("authentication") ||
            message.contains("x-api-key") ||
            message.contains("api key") ||
            message.contains("401")
    }
}

private enum HarnessLaunchMode: String, CaseIterable, Identifiable {
    case ask = "Ask"
    case imagine = "Imagine"

    var id: String { rawValue }
}

private struct HarnessQuickAction: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let mode: HarnessLaunchMode

    static let defaults: [HarnessQuickAction] = [
        HarnessQuickAction(id: "analyze-docs", title: "Analyze Docs", icon: "doc.text", mode: .ask),
        HarnessQuickAction(id: "customize-harness", title: "Customize Harness", icon: "slider.horizontal.3", mode: .ask),
        HarnessQuickAction(id: "create-videos", title: "Create Videos", icon: "video", mode: .imagine),
        HarnessQuickAction(id: "edit-images", title: "Edit Images", icon: "photo", mode: .imagine)
    ]
}

private struct HarnessTopBar: View {
    @Binding var mode: HarnessLaunchMode

    var body: some View {
        HStack(spacing: 14) {
            CircleIconButton(systemName: "line.3.horizontal", accessibilityLabel: "Menu") {}

            Spacer(minLength: 0)

            HStack(spacing: 3) {
                ForEach(HarnessLaunchMode.allCases) { launchMode in
                    Button {
                        mode = launchMode
                    } label: {
                        Text(launchMode.rawValue)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(mode == launchMode ? Theme.iosBackground : Theme.iosSand.opacity(0.74))
                            .frame(minWidth: 78)
                            .padding(.vertical, 9)
                            .background(
                                Capsule()
                                    .fill(mode == launchMode ? Theme.iosSand : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Theme.iosControl, in: Capsule())
            .overlay(Capsule().stroke(Theme.iosHair, lineWidth: 1))

            Spacer(minLength: 0)

            CircleIconButton(systemName: "shield.lefthalf.filled", accessibilityLabel: "Privacy") {}
        }
    }
}

private struct HarnessConversationStage: View {
    let messages: [ChatMessage]
    let backend: Backend
    let thinking: Bool
    let latestRunDetail: HarnessRunDetail?
    let ledgerStatus: String

    var body: some View {
        ZStack {
            HarnessWatermark()
                .frame(width: 168, height: 194)
                .opacity(messages.isEmpty ? 0.45 : 0.14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        HarnessMessageBubble(message: message, backend: backend)
                    }

                    if thinking {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("\(backend.rawValue) thinking")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.iosMuted)
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 6)
                    }

                    if let latestRunDetail {
                        HarnessRunStatusStrip(detail: latestRunDetail, status: ledgerStatus)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 28)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HarnessRunStatusStrip: View {
    let detail: HarnessRunDetail
    let status: String

    var body: some View {
        HStack(spacing: 8) {
            Label("\(detail.authorityHits.count)", systemImage: "point.3.connected.trianglepath.dotted")
            Label("\(detail.memoryHits.count)", systemImage: "archivebox")
            Label(status, systemImage: detail.run.success ? "checkmark.seal" : "exclamationmark.triangle")
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.iosMuted)
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }
}

private struct HarnessWatermark: View {
    var body: some View {
        Image("HarnessWatermark")
            .resizable()
            .scaledToFit()
        .accessibilityHidden(true)
    }
}

private struct HarnessMessageBubble: View {
    let message: ChatMessage
    let backend: Backend

    var body: some View {
        HStack {
            if message.fromMe { Spacer(minLength: 42) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.fromMe ? "You" : backend.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.iosMuted)
                Text(message.text)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.iosText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(message.fromMe ? Theme.iosBubble : Theme.iosPanel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.iosHair, lineWidth: 1))
            if !message.fromMe { Spacer(minLength: 42) }
        }
    }
}

private struct HarnessQuickActionCarousel: View {
    let actions: [HarnessQuickAction]
    let selectedID: HarnessQuickAction.ID?
    let onSelect: (HarnessQuickAction) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(actions) { action in
                    Button {
                        onSelect(action)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: action.icon)
                                .font(.system(size: 26, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Theme.iosMuted)
                                .frame(width: 30, height: 30)

                            Text(action.title)
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(Theme.iosText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        .padding(.horizontal, 22)
                        .frame(height: 74)
                        .frame(minWidth: 190)
                        .background(selectedID == action.id ? Theme.iosControlActive : Theme.iosControl, in: RoundedRectangle(cornerRadius: 26))
                        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Theme.iosHair, lineWidth: selectedID == action.id ? 1.5 : 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

private struct HarnessComposer: View {
    @Binding var draft: String
    @Binding var backend: Backend
    @Binding var apiKey: String

    let hasConfiguredAPIKey: Bool
    let thinking: Bool
    let mode: HarnessLaunchMode
    let onAttach: () -> Void
    let onSpeak: () -> Void
    let onSaveAPIKey: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField(mode == .ask ? "Ask Anything" : "Imagine Anything", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.iosText)
                .lineLimit(1...4)
                .submitLabel(.send)
                .onSubmit(onSubmit)
                .disabled(thinking)
                #if os(iOS)
                .textInputAutocapitalization(.sentences)
                #endif

            if needsClaudeKey {
                HStack(spacing: 8) {
                    SecureField("Claude API key", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.iosText)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(Theme.iosControlActive, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.iosHair, lineWidth: 1))
                        .apiKeyEntryBehavior()

                    Button(action: onSaveAPIKey) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(saveDisabled ? Theme.iosMuted : Theme.iosBackground)
                            .frame(width: 40, height: 40)
                            .background(saveDisabled ? Theme.iosControlActive : Theme.iosText, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(saveDisabled)
                    .accessibilityLabel("Save Claude API key")
                }
            }

            HStack(spacing: 8) {
                CircleIconButton(systemName: "plus", accessibilityLabel: "Add", size: 46, action: onAttach)

                BackendMenuPill(backend: $backend)
                    .disabled(thinking)

                Spacer(minLength: 6)

                CircleIconButton(systemName: "mic", accessibilityLabel: "Voice", size: 46, action: onSpeak)

                Button(action: onSubmit) {
                    Image(systemName: thinking ? "hourglass" : "arrow.up")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(sendDisabled ? Theme.iosMuted : Theme.iosBackground)
                        .frame(width: 50, height: 50)
                        .background(sendDisabled ? Theme.iosControlActive : Theme.iosText, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(sendDisabled)
                .accessibilityLabel("Send")
            }
        }
        .padding(14)
        .background(Theme.iosPanel, in: RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(Theme.iosComposerStroke, lineWidth: 1.2))
    }

    private var sendDisabled: Bool {
        thinking ||
            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            (needsClaudeKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var saveDisabled: Bool {
        thinking || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var needsClaudeKey: Bool {
        backend == .claude && !hasConfiguredAPIKey
    }
}

private struct BackendMenuPill: View {
    @Binding var backend: Backend

    var body: some View {
        Menu {
            ForEach(Backend.phoneVisibleCases) { candidate in
                Button {
                    backend = candidate
                } label: {
                    Label(candidate.rawValue, systemImage: candidate == backend ? "checkmark" : "circle")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .bold))
                Text(backend.rawValue)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(Theme.iosText)
            .frame(width: 96, height: 50)
            .background(Theme.iosControlActive, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

private extension Backend {
    static var phoneVisibleCases: [Backend] {
        #if os(iOS)
        [.claude]
        #else
        Backend.allCases
        #endif
    }
}

private extension View {
    @ViewBuilder
    func apiKeyEntryBehavior() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }
}

private struct CircleIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var size: CGFloat = 50
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.iosText)
                .frame(width: size, height: size)
                .background(Theme.iosControlActive, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private extension Theme {
    static let iosBackground = Color(hex: 0x081421)
    static let iosPanel = Color(hex: 0x1E2023)
    static let iosControl = Color(hex: 0x191B1E)
    static let iosControlActive = Color(hex: 0x303236)
    static let iosBubble = Color(hex: 0x182637)
    static let iosText = Color(hex: 0xF6F0E5)
    static let iosSand = Color(hex: 0xC9B79A)
    static let iosMuted = Color(hex: 0x9C9A96)
    static let iosHair = Color.white.opacity(0.08)
    static let iosComposerStroke = Color.white.opacity(0.12)
}

#Preview {
    ChatView(ontology: OntologyLoader.load())
}
