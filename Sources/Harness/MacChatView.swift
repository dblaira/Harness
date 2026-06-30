#if os(macOS)
import SwiftUI
import OntologyKit

struct MacChatView: View {
    let ontology: Ontology
    @StateObject private var model = MacWorkbenchModel()
    @State private var inspectorTab: WorkbenchInspectorTab = .authority

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.macHair)
            transcript
            Divider().overlay(Theme.macHair)
            inspector
        }
        .background(Theme.macBg.ignoresSafeArea())
        .onAppear { model.updateOntology(ontology) }
        .onChange(of: ontology.connections.count) { _, _ in model.updateOntology(ontology) }
        .onChange(of: model.searchText) { _, _ in Task { await model.searchRuns() } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            PerLetterGradientTitle("HARNESS")
                .padding(.bottom, 4)

            Button(action: model.newSession) {
                sidebarLabel("New session", "plus")
            }
            .buttonStyle(.plain)

            sidebarLabel("Skills & Tools", "wrench.and.screwdriver")
            skillsList

            TextField("Search sessions...", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.macInk)
                .padding(8)
                .background(Theme.macEntry.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))

            Text("SESSIONS")
                .font(.system(size: 9).weight(.bold))
                .tracking(1.8)
                .foregroundStyle(Theme.macInk.opacity(0.55))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.runs) { run in
                        Button {
                            Task { await model.selectRun(run) }
                        } label: {
                            sessionRow(run)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                Text("Read-only vault")
            }
            .font(.caption)
            .foregroundStyle(Theme.macInk.opacity(0.55))
        }
        .padding(14)
        .frame(width: 250, alignment: .leading)
        .background(Theme.macBg)
    }

    private var skillsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            skillRow("ontology-steward", "checkmark.seal")
            skillRow("vault-search", "doc.text.magnifyingglass")
            skillRow("graph-trace", "point.3.connected.trianglepath.dotted")
            skillRow("repo-context", "folder")
        }
        .padding(.leading, 2)
    }

    private func skillRow(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 14)
                .foregroundStyle(Theme.macInk.opacity(0.45))
            Text(title)
                .lineLimit(1)
            Spacer()
            Circle()
                .fill(Theme.macRed.opacity(0.75))
                .frame(width: 6, height: 6)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.macInk.opacity(0.72))
    }

    private func sidebarLabel(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13).weight(.semibold))
            Spacer()
        }
        .foregroundStyle(Theme.macRed)
    }

    private func sessionRow(_ run: HarnessRun) -> some View {
        let selected = model.selectedDetail?.run.id == run.id
        return VStack(alignment: .leading, spacing: 3) {
            Text(run.prompt)
                .font(.system(size: 12).weight(.medium))
                .lineLimit(1)
            Text("\(run.backend) - \(run.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(Theme.macInk.opacity(0.45))
        }
        .foregroundStyle(selected ? Theme.macInk : Theme.macRed.opacity(0.9))
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.macEntry.opacity(0.45) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let detail = model.selectedDetail {
                        runSummary(detail)
                        ForEach(detail.messages) { message in
                            messageBubble(message)
                        }
                    }

                    if model.isRunning {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(model.status)
                                .foregroundStyle(Theme.macInk.opacity(0.55))
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            delegateLabel
            composer
        }
        .frame(minWidth: 520, maxWidth: .infinity)
        .background(Theme.macBg)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedDetail?.run.prompt ?? "The Adam Pattern")
                    .font(.system(size: 14).weight(.semibold))
                    .foregroundStyle(Theme.macInk)
                    .lineLimit(1)
            }

            Spacer()

            Picker("Backend", selection: $model.backend) {
                ForEach(Backend.allCases) { backend in
                    Text(backend.rawValue).tag(backend)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .tint(Theme.macRed)

            if model.backend == .claude {
                SecureField("API key", text: $model.apiKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.macInk)
                    .padding(7)
                    .frame(width: 190)
                    .background(Theme.macEntry.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(Rectangle().fill(Theme.macHair).frame(height: 1), alignment: .bottom)
    }

    private var delegateLabel: some View {
        Text("Delegate")
            .font(.system(.title2, design: .serif).weight(.semibold))
            .foregroundStyle(Theme.macInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func runSummary(_ detail: HarnessRunDetail) -> some View {
        HStack(spacing: 10) {
            statusPill("\(detail.authorityHits.count) authority", "point.3.connected.trianglepath.dotted")
            statusPill("\(detail.memoryHits.count) memory", "archivebox")
            statusPill(detail.run.success ? "trace saved" : "failed saved", detail.run.success ? "checkmark.seal" : "exclamationmark.triangle")
            Spacer()
            Text(detail.run.promptPacketHash)
                .font(.caption2.monospaced())
                .foregroundStyle(Theme.macInk.opacity(0.42))
        }
    }

    private func statusPill(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(Theme.macInk.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.macEntry.opacity(0.35), in: Capsule())
        .overlay(Capsule().stroke(Theme.macHair, lineWidth: 1))
    }

    private func messageBubble(_ message: HarnessMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? "YOU" : "ANSWER")
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(Theme.macInk.opacity(0.48))
            Text(message.text)
                .font(.body)
                .foregroundStyle(Theme.macInk)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(message.role == .user ? 0.45 : 0.25), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.macHair, lineWidth: 1))
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.macInk)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .overlay(alignment: .leading) {
                    if model.draft.isEmpty {
                        Text("Type a message...")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.macFaint)
                            .allowsHitTesting(false)
                    }
                }
                .padding(12)
                .background(Theme.macEntry.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.macHair, lineWidth: 1))
                .onSubmit(model.send)

            Button(action: model.send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.macInk.opacity(0.35) : Theme.macInk)
            }
            .buttonStyle(.plain)
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRunning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(Rectangle().fill(Theme.macHair).frame(height: 1), alignment: .top)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Inspector", selection: $inspectorTab) {
                ForEach(WorkbenchInspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch inspectorTab {
                    case .authority:
                        authorityPanel
                    case .memory:
                        memoryPanel
                    case .trace:
                        tracePanel
                    case .candidates:
                        candidatePanel
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(model.status)
                .font(.caption)
                .foregroundStyle(Theme.macInk.opacity(0.45))
                .lineLimit(2)
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
        .background(Theme.macBg)
    }

    private var authorityPanel: some View {
        Group {
            if let detail = model.selectedDetail, !detail.authorityHits.isEmpty {
                ForEach(detail.authorityHits) { hit in
                    inspectorBlock(title: hit.subject, subtitle: hit.source, body: "\(hit.predicate)\n\(hit.object)\n\n\(hit.queryTrace)")
                }
            } else {
                emptyInspectorText("No accepted graph authority selected yet.")
            }
        }
    }

    private var memoryPanel: some View {
        Group {
            if let detail = model.selectedDetail, !detail.memoryHits.isEmpty {
                ForEach(detail.memoryHits) { hit in
                    inspectorBlock(title: hit.source, subtitle: "supporting - score \(hit.score.formatted(.number.precision(.fractionLength(2))))", body: hit.excerpt)
                }
            } else {
                emptyInspectorText("Supporting memory appears here after graph authority is checked.")
            }
        }
    }

    private var tracePanel: some View {
        Group {
            if let detail = model.selectedDetail {
                ForEach(detail.traceEvents) { event in
                    inspectorBlock(title: event.stage.rawValue, subtitle: event.createdAt.formatted(date: .omitted, time: .standard), body: event.message)
                }
                ForEach(detail.evalResults) { result in
                    inspectorBlock(title: result.checkName, subtitle: result.passed ? "passed" : "needs review", body: result.detail)
                }
            } else {
                emptyInspectorText("Run trace and eval checks appear here.")
            }
        }
    }

    private var candidatePanel: some View {
        Group {
            if let detail = model.selectedDetail, !detail.memoryCandidates.isEmpty {
                ForEach(detail.memoryCandidates) { candidate in
                    inspectorBlock(title: candidate.status.rawValue, subtitle: "candidate memory", body: candidate.proposedClaim)
                }
            } else {
                emptyInspectorText("No candidate memory for this run.")
            }
        }
    }

    private func emptyInspectorText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Theme.macInk.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    private func inspectorBlock(title: String, subtitle: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12).weight(.semibold))
                .foregroundStyle(Theme.macInk)
                .lineLimit(2)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(Theme.macInk.opacity(0.46))
                .lineLimit(1)
            Text(body)
                .font(.caption)
                .foregroundStyle(Theme.macInk.opacity(0.72))
                .textSelection(.enabled)
                .lineLimit(8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
    }
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
