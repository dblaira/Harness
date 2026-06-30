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
    @State private var backend: Backend = .codex
    @State private var apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    @State private var mode: HarnessLaunchMode = .ask
    @State private var selectedQuickAction: HarnessQuickAction.ID?
    @State private var showingAttachmentMenu = false

    private let runner = AgentRunner()
    private var system: String { ClaudeClient.systemPrompt(from: ontology) }

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
                    thinking: thinking
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
                    thinking: thinking,
                    mode: mode,
                    onAttach: { showingAttachmentMenu = true },
                    onSpeak: beginVoice,
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
        messages.append(ChatMessage(text: text, fromMe: true))
        draft = ""
        thinking = true
        let chosen = backend
        let key = apiKey.isEmpty ? nil : apiKey
        Task {
            do {
                let reply = try await runner.run(backend: chosen, system: system, user: text, apiKey: key)
                await MainActor.run {
                    messages.append(ChatMessage(text: reply, fromMe: false))
                    thinking = false
                }
            } catch {
                await MainActor.run {
                    messages.append(ChatMessage(text: "Error: \(error.localizedDescription)", fromMe: false))
                    thinking = false
                }
            }
        }
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

    let thinking: Bool
    let mode: HarnessLaunchMode
    let onAttach: () -> Void
    let onSpeak: () -> Void
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

            HStack(spacing: 8) {
                CircleIconButton(systemName: "plus", accessibilityLabel: "Add", size: 46, action: onAttach)

                BackendMenuPill(backend: $backend)
                    .disabled(thinking)

                Spacer(minLength: 6)

                CircleIconButton(systemName: "mic", accessibilityLabel: "Voice", size: 46, action: onSpeak)

                Button(action: onSpeak) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 18, weight: .bold))
                        Text("Speak")
                            .font(.system(size: 19, weight: .bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.iosBackground)
                    .frame(width: 116, height: 50)
                    .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Theme.iosPanel, in: RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(Theme.iosComposerStroke, lineWidth: 1.2))
    }
}

private struct BackendMenuPill: View {
    @Binding var backend: Backend

    var body: some View {
        Menu {
            ForEach(Backend.allCases) { candidate in
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
