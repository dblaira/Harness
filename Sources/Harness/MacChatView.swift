#if os(macOS)
import SwiftUI
import OntologyKit

/// macOS-only chat surface. Deliberately low-contrast for a bright indoor
/// screen and shoulder-surf privacy: navy everywhere, light-brown text,
/// grey entry box, faint grey hairlines, red sidebar lettering. No white.
struct MacChatView: View {
    let ontology: Ontology
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var thinking = false
    @State private var backend: Backend = .codex
    @State private var apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    @State private var showSidebar = true

    private let runner = AgentRunner()
    private var system: String { ClaudeClient.systemPrompt(from: ontology) }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar { sidebar.transition(.move(edge: .leading)) }
            conversation
        }
        .background(Theme.macBg.ignoresSafeArea())
    }

    // MARK: Sidebar — red lettering, faint hairline divider on the right edge.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            PerLetterGradientTitle("HARNESS")
                .padding(.bottom, 12)

            sidebarItem("New session", "plus")
            sidebarItem("My Rules", "checkmark.seal")
            sidebarItem("Cause & Effect", "arrow.right.circle")
            sidebarItem("The Pattern", "list.number")

            Text("RECENT")
                .font(.system(size: 9).weight(.bold)).tracking(1.5)
                .foregroundStyle(Theme.macInk.opacity(0.4))
                .padding(.top, 14).padding(.bottom, 2)

            ForEach(MacChatView.sampleTitles, id: \.self) { t in
                Text(t)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.macRed.opacity(0.85))
                    .lineLimit(1)
                    .padding(.vertical, 2)
            }
            Spacer()
        }
        .padding(14)
        .frame(width: 188, alignment: .leading)
        .background(Theme.macBg)
        .overlay(Rectangle().fill(Theme.macHair).frame(width: 1), alignment: .trailing)
    }

    private func sidebarItem(_ label: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.macRed.opacity(0.7))
                .font(.system(size: 11)).frame(width: 14)
            Text(label).font(.system(size: 12).weight(.medium)).foregroundStyle(Theme.macRed)
            Spacer()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    // MARK: Conversation column
    private var conversation: some View {
        VStack(spacing: 0) {
            // Top bar with sidebar toggle + model picker
            HStack {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() } } label: {
                    Image(systemName: "sidebar.left")
                        .font(.title3).foregroundStyle(Theme.macInk.opacity(0.8))
                }
                .buttonStyle(.plain)

                Spacer()

                Menu {
                    ForEach(Backend.allCases) { b in
                        Button(b.rawValue) { backend = b }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                        Text(backend.rawValue).font(.system(size: 13))
                    }
                    .foregroundColor(Theme.macRed.opacity(0.85))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(Theme.macRed.opacity(0.85))
                .fixedSize()
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .overlay(Rectangle().fill(Theme.macHair).frame(height: 1), alignment: .bottom)

            // Messages
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ask anything.")
                                .font(.system(.title2, design: .serif).weight(.semibold))
                                .foregroundStyle(Theme.macInk)
                            Text("Constrained by your \(ontology.connections.count) rules + \(ontology.axioms.count) axioms via \(backend.rawValue). The reply names the rule it used.")
                                .font(.callout).foregroundStyle(Theme.macInk.opacity(0.6))
                        }
                        .padding(.top, 8)
                    }
                    ForEach(messages) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.fromMe ? "YOU" : backend.rawValue.uppercased())
                                .font(.caption2.weight(.bold)).tracking(1.2)
                                .foregroundStyle(Theme.macInk.opacity(0.45))
                            Text(m.text)
                                .font(.body).foregroundStyle(Theme.macInk)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Theme.macEntry.opacity(m.fromMe ? 0.5 : 0.25),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.macHair, lineWidth: 1))
                    }
                    if thinking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(backend.rawValue) thinking…").foregroundStyle(Theme.macInk.opacity(0.5))
                        }
                    }
                }
                .padding(18)
            }

            if backend == .claude {
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.plain).foregroundStyle(Theme.macInk)
                    .padding(10)
                    .background(Theme.macEntry, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
                    .padding(.horizontal, 18)
            }

            // Grey entry box
            HStack(spacing: 10) {
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).foregroundStyle(Theme.macInk)
                    .font(.system(size: 13))
                    .overlay(alignment: .leading) {
                        if draft.isEmpty {
                            Text("Type a message…")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.macFaint)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(12)
                    .background(Theme.macEntry.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.macHair, lineWidth: 1))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2).foregroundStyle(Theme.macInk)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || thinking)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .overlay(Rectangle().fill(Theme.macHair).frame(height: 1), alignment: .top)
        }
        .background(Theme.macBg)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(ChatMessage(text: text, fromMe: true))
        draft = ""
        thinking = true
        let chosen = backend
        let key = apiKey.isEmpty ? nil : apiKey
        Task {
            do {
                let reply = try await runner.run(backend: chosen, system: system, user: text, apiKey: key)
                await MainActor.run { messages.append(ChatMessage(text: reply, fromMe: false)); thinking = false }
            } catch {
                await MainActor.run { messages.append(ChatMessage(text: "⚠️ \(error.localizedDescription)", fromMe: false)); thinking = false }
            }
        }
    }

    static let sampleTitles = [
        "Plain answer first, always.",
        "What creates the most excitement?",
        "Notorious color scheme.",
        "Momentum is the metric.",
        "Build the system, not the task.",
        "The Adam Pattern, step 1."
    ]
}

private struct PerLetterGradientTitle: View {
    private let letters: [String]

    init(_ text: String) {
        self.letters = text.map(String.init)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(letters.enumerated()), id: \.offset) { _, letter in
                Text(letter)
                    .font(.custom("PlayfairDisplay-Regular", size: 24).weight(.black))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: 0x2A1B12), Color(hex: 0x5A3A22), Color(hex: 0x8A6A46)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .accessibilityLabel("HARNESS")
    }
}
#endif
