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

    private let runner = AgentRunner()
    private var system: String { ClaudeClient.systemPrompt(from: ontology) }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.tan.ignoresSafeArea()   // guarantees no black bar at top
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Notorious header — tan band, navy serif title (extends to top)
            HStack {
                Text("Harness")
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(Theme.navy)
                Spacer()
                Picker("Model", selection: $backend) {
                    ForEach(Backend.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).tint(Theme.navy)
            }
            #if os(iOS)
            .padding(.horizontal, 20).padding(.bottom, 14).padding(.top, 60)
            #else
            .padding(.horizontal, 20).padding(.vertical, 18)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.tan)
            .overlay(Rectangle().fill(Theme.red).frame(height: 3), alignment: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Navy "UP NEXT" band
                    HStack {
                        Text("UP NEXT")
                            .font(.system(.subheadline, design: .default).weight(.bold))
                            .tracking(2).foregroundStyle(Theme.tan)
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Theme.navy)

                    if messages.isEmpty {
                        notoriousCard(
                            kicker: "REMINDER",
                            title: "Ask anything.",
                            sub: "Constrained by your \(ontology.connections.count) rules + \(ontology.axioms.count) axioms via \(backend.rawValue). The reply names the rule it used.",
                            color: Theme.paper, ink: Theme.navy
                        )

                        // Past sessions fill the rest of the page
                        Text("RECENT SESSIONS")
                            .font(.caption.weight(.bold)).tracking(1.5)
                            .foregroundStyle(Theme.navy.opacity(0.5))
                            .padding(.horizontal, 20).padding(.top, 8)

                        ForEach(Self.sampleSessions) { s in
                            notoriousCard(
                                kicker: s.pinned ? "📌 PINNED" : s.date,
                                title: s.title,
                                sub: s.preview,
                                color: s.color, ink: s.ink
                            )
                        }
                    }

                    ForEach(messages) { m in
                        notoriousCard(
                            kicker: m.fromMe ? "YOU" : backend.rawValue.uppercased(),
                            title: m.text,
                            sub: nil,
                            color: m.fromMe ? Theme.blue : Theme.red,
                            ink: .white
                        )
                    }

                    if thinking {
                        HStack { ProgressView().controlSize(.small)
                            Text("\(backend.rawValue) thinking…").foregroundStyle(.secondary) }
                            .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 16)
            }
            .background(Color.white)

            if backend == .claude {
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder).padding(.horizontal)
            }

            // Bottom bar — navy with red lightning send
            HStack(spacing: 12) {
                TextField("Type a message…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "bolt.fill").font(.title2).foregroundStyle(.white)
                        .padding(14).background(Theme.red, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || thinking)
            }
            .padding(12)
            .background(Theme.navy)
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .navigationTitle("New chat")
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    // A Notorious-style card: kicker label, serif headline, red accent bar.
    @ViewBuilder
    private func notoriousCard(kicker: String, title: String, sub: String?, color: Color, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kicker)
                .font(.caption.weight(.bold)).tracking(1.5)
                .foregroundStyle(ink.opacity(0.7))
            Text(title)
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(ink)
            Rectangle().fill(Theme.red).frame(width: 60, height: 3)
            if let sub {
                Text(sub).font(.callout).foregroundStyle(ink.opacity(0.85))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
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
                await MainActor.run {
                    messages.append(ChatMessage(text: reply, fromMe: false)); thinking = false
                }
            } catch {
                await MainActor.run {
                    messages.append(ChatMessage(text: "⚠️ \(error.localizedDescription)", fromMe: false)); thinking = false
                }
            }
        }
    }

    // Sample past sessions (Panda placeholder data) to fill the page.
    struct Session: Identifiable {
        let id = UUID()
        let title: String
        let preview: String
        let date: String
        let pinned: Bool
        let color: Color
        let ink: Color
    }
    static let sampleSessions: [Session] = [
        Session(title: "Plain answer first, always.",
                preview: "Locked the momentum + plain-language rules into a gate.",
                date: "Jun 29", pinned: true, color: Theme.paper, ink: Theme.navy),
        Session(title: "What creates the most excitement?",
                preview: "Two answers side by side — the difference is your brain.",
                date: "Jun 29", pinned: false, color: Theme.blue, ink: .white),
        Session(title: "Notorious color scheme.",
                preview: "Tan, navy, red. Built and shipped to the simulator.",
                date: "Jun 29", pinned: false, color: Theme.paper, ink: Theme.navy),
        Session(title: "Momentum is the metric.",
                preview: "Short replies keep momentum; long ones kill it.",
                date: "Jun 28", pinned: false, color: Theme.red, ink: .white),
        Session(title: "Build the system, not the task.",
                preview: "conn-019 — reusable systems that compound.",
                date: "Jun 28", pinned: false, color: Theme.paper, ink: Theme.navy),
        Session(title: "The Adam Pattern, step 1.",
                preview: "Accept reality first. Name the step before acting.",
                date: "Jun 27", pinned: false, color: Theme.yellow, ink: Theme.navy)
    ]
}
