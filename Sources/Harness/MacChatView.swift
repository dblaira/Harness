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
            OutlinedHarnessTitle("HARNESS")
                .padding(.bottom, 4)

            Button(action: model.newSession) {
                sidebarLabel("New session", "plus")
            }
            .buttonStyle(.plain)

            sidebarLabel("Skills & Tools", "wrench.and.screwdriver")
            skillsList
            selectedToolCard

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
            ForEach(model.toolGroups) { group in
                Text(group.title.uppercased())
                    .font(.system(size: 8).weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.macInk.opacity(0.42))
                    .padding(.top, group.id == model.toolGroups.first?.id ? 0 : 6)

                ForEach(group.tools) { tool in
                    skillRow(tool)
                }
            }
        }
        .padding(.leading, 2)
    }

    private func skillRow(_ tool: WorkbenchTool) -> some View {
        Button {
            model.selectTool(tool)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tool.icon)
                    .frame(width: 14)
                    .foregroundStyle(Theme.macInk.opacity(0.45))
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.title)
                        .lineLimit(1)
                    Text(tool.detail)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.macInk.opacity(0.42))
                        .lineLimit(1)
                }
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(tool.state.tint)
                    .frame(width: 6, height: 6)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(model.selectedTool?.id == tool.id ? Theme.macEntry.opacity(0.32) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(Theme.macInk.opacity(0.72))
    }

    private var selectedToolCard: some View {
        Group {
            if let tool = model.selectedTool {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Image(systemName: tool.icon)
                            .frame(width: 14)
                        Text(tool.title)
                            .font(.system(size: 12).weight(.semibold))
                        Spacer()
                        Text(tool.state.rawValue)
                            .font(.system(size: 8).weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Theme.macEntry.opacity(0.36), in: Capsule())
                    }
                    Text(tool.summary)
                    Text(tool.permission)
                    Text(tool.provenance)
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.macInk.opacity(0.68))
                .padding(10)
                .background(Theme.macEntry.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
            }
        }
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
            ZStack {
                MacHarnessWatermark()
                    .frame(width: 260, height: 300)
                    .opacity(model.selectedDetail == nil ? 0.18 : 0.08)

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
            if message.role == .assistant {
                HarnessMarkdownText(
                    text: message.text,
                    textColor: Theme.macInk,
                    bodyFont: .body,
                    h1Font: .system(.title2, design: .serif).weight(.semibold),
                    h2Font: .headline
                )
                .textSelection(.enabled)
            } else {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(Theme.macInk)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(message.role == .user ? 0.45 : 0.25), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.macHair, lineWidth: 1))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.macInk)
                .font(.system(size: 13))
                .lineLimit(1...12)
                .fixedSize(horizontal: false, vertical: true)
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
                    case .connectors:
                        connectorPanel
                    case .skills:
                        capabilityPanel
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
                    inspectorBlock(
                        title: hit.subject,
                        subtitle: "\(hit.authorityLevel.rawValue) - \(hit.source) - score \(hit.score.formatted(.number.precision(.fractionLength(2))))",
                        body: "\(hit.predicate)\n\(hit.object)\n\n\(hit.queryTrace)",
                        status: "accepted"
                    )
                }
            } else {
                emptyInspectorText("No accepted graph authority selected yet.")
            }
        }
    }

    private var memoryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            memorySourcesPanel

            if let detail = model.selectedDetail, !detail.memoryHits.isEmpty {
                ForEach(detail.memoryHits) { hit in
                    inspectorBlock(
                        title: hit.source,
                        subtitle: "\(hit.authorityLevel.rawValue), not graph authority - score \(hit.score.formatted(.number.precision(.fractionLength(2))))",
                        body: "\(hit.reasonSelected)\n\n\(hit.excerpt)",
                        status: "supporting"
                    )
                }
            } else {
                emptyInspectorText("Supporting memory appears here after graph authority is checked.")
            }
        }
    }

    private var memorySourcesPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Local Sources")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.macInk.opacity(0.58))
                Spacer()
                Button {
                    model.syncAppleNotes()
                } label: {
                    Label("Sync Notes", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            ForEach(model.connectors.filter { $0.role == .supportingMemory }) { source in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: memorySourceIcon(source.kind))
                        .frame(width: 14)
                        .foregroundStyle(Theme.macInk.opacity(source.state == .available ? 0.62 : 0.32))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.macInk.opacity(source.state == .available ? 0.72 : 0.42))
                            .lineLimit(1)
                        Text(source.root.path)
                            .font(.caption2)
                            .foregroundStyle(Theme.macInk.opacity(0.38))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    statusBadge(source.state.rawValue)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
    }

    private func memorySourceIcon(_ kind: HarnessConnectorKind) -> String {
        switch kind {
        case .github:
            return "folder"
        case .obsidian:
            return "doc.text.magnifyingglass"
        case .appleNotes:
            return "note.text"
        case .acceptedGraph:
            return "checkmark.seal"
        case .skillDirectory:
            return "wrench.and.screwdriver"
        case .pluginDirectory:
            return "shippingbox"
        case .agentBridge:
            return "point.3.connected.trianglepath.dotted"
        case .mcpServer:
            return "network"
        case .custom:
            return "externaldrive"
        }
    }

    private var connectorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.connectors) { connector in
                inspectorBlock(
                    title: connector.title,
                    subtitle: "\(connector.sourceSystem) - \(connector.role.rawValue) - \(connector.state.rawValue)",
                    body: "\(connector.summary)\n\nPermission: \(connector.permission)\n\nProvenance: \(connector.provenance)\n\nPath: \(connector.root.path)",
                    status: connector.kind.rawValue
                )
            }
        }
    }

    private var capabilityPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(model.capabilities.count) discovered")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.macInk.opacity(0.58))
                Spacer()
                Button {
                    model.refreshConnectors()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.macInk.opacity(0.68))
                        .frame(width: 28, height: 24)
                        .background(Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Refresh skills and plugins")
            }

            ForEach(capabilityGroups, id: \.key) { group in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(group.key)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.macInk.opacity(0.56))
                            .lineLimit(1)
                        Spacer()
                        statusBadge("\(group.items.count)")
                    }

                    ForEach(group.items.prefix(12)) { capability in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: capabilityIcon(capability.kind))
                                .frame(width: 14)
                                .foregroundStyle(Theme.macInk.opacity(0.48))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(capability.name)
                                    .font(.system(size: 12).weight(.semibold))
                                    .foregroundStyle(Theme.macInk.opacity(0.78))
                                    .lineLimit(1)
                                Text(capability.description)
                                    .font(.caption)
                                    .foregroundStyle(Theme.macInk.opacity(0.48))
                                    .lineLimit(2)
                            }
                        }
                    }

                    if group.items.count > 12 {
                        Text("+ \(group.items.count - 12) more")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.macInk.opacity(0.42))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.macEntry.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
            }
        }
    }

    private var capabilityGroups: [(key: String, items: [HarnessCapability])] {
        let grouped = Dictionary(grouping: model.capabilities) { capability in
            "\(capability.sourceSystem) / \(capability.category)"
        }
        return grouped
            .map { (key: $0.key, items: $0.value.sorted { $0.name < $1.name }) }
            .sorted { lhs, rhs in
                if lhs.items.count == rhs.items.count { return lhs.key < rhs.key }
                return lhs.items.count > rhs.items.count
            }
    }

    private func capabilityIcon(_ kind: HarnessCapabilityKind) -> String {
        switch kind {
        case .skill:
            return "wrench.and.screwdriver"
        case .plugin:
            return "shippingbox"
        case .connector:
            return "point.3.connected.trianglepath.dotted"
        case .tool:
            return "terminal"
        }
    }

    private var tracePanel: some View {
        Group {
            if let detail = model.selectedDetail {
                ForEach(detail.traceEvents) { event in
                    inspectorBlock(
                        title: event.stage.rawValue,
                        subtitle: event.createdAt.formatted(date: .omitted, time: .standard),
                        body: event.message,
                        status: "trace"
                    )
                }
                ForEach(detail.evalResults) { result in
                    inspectorBlock(
                        title: result.checkName,
                        subtitle: result.passed ? "passed" : "needs review",
                        body: result.detail,
                        status: result.passed ? "passed" : "review"
                    )
                }
            } else {
                emptyInspectorText("Run trace and eval checks appear here.")
            }
        }
    }

    private var candidatePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(model.reviewQueueCandidates.count) remaining")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.macInk.opacity(0.58))
                Spacer()
                Button {
                    model.scanForNewPatterns()
                } label: {
                    Label("Scan for new patterns", systemImage: "waveform.path.ecg")
                        .font(.caption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if model.reviewQueueCandidates.isEmpty {
                emptyInspectorText("No pending claims.")
            } else {
                ForEach(model.reviewQueueCandidates) { candidate in
                    reviewQueueCard(candidate)
                }
            }
        }
    }

    private func reviewQueueCard(_ candidate: MemoryCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(candidate.plainEnglish)
                .font(.system(size: 12).weight(.semibold))
                .foregroundStyle(Theme.macInk)
                .lineLimit(3)

            Text(candidate.evidenceNote)
                .font(.caption)
                .foregroundStyle(Theme.macInk.opacity(0.62))
                .lineLimit(3)

            if let validationResult = candidate.validationResult,
               validationResult.hasPrefix("Blocked:") {
                Text(validationResult)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.macRed)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                reviewQueueButton("Yes", candidate: candidate, decision: .yes)
                reviewQueueButton("Sometimes", candidate: candidate, decision: .sometimes)
                reviewQueueButton("No", candidate: candidate, decision: .no)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
    }

    private func reviewQueueButton(_ title: String, candidate: MemoryCandidate, decision: ReviewQueueDecision) -> some View {
        Button {
            model.decideReviewQueueCandidate(candidate, decision: decision)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.macInk.opacity(0.78))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func emptyInspectorText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Theme.macInk.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    private func candidateBlock(_ candidate: MemoryCandidate, validations: [ValidationResult]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            inspectorBlock(
                title: candidate.status.rawValue,
                subtitle: "candidate memory - \(candidate.createdAt.formatted(date: .abbreviated, time: .shortened))",
                body: candidateBody(candidate, validations: validations),
                status: candidate.status.rawValue
            )

            HStack(spacing: 8) {
                candidateButton("Suggested", state: .suggested, candidate: candidate)
                candidateButton("Review", state: .candidate, candidate: candidate)
                candidateButton("Reject", state: .rejected, candidate: candidate)
            }

            Button {
                model.prepareCandidateForGraphReview(candidate)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.gearshape")
                    Text(candidate.status == .validated ? "Ready for Graph Review" : "Prepare Graph")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(candidate.status == .validated ? Theme.macBg : Theme.macInk.opacity(0.78))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(candidate.status == .validated ? Theme.macInk : Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(candidate.status == .rejected)
        }
    }

    private func candidateButton(_ title: String, state: CandidateState, candidate: MemoryCandidate) -> some View {
        Button {
            model.markCandidate(candidate, as: state)
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(candidate.status == state ? Theme.macBg : Theme.macInk.opacity(0.76))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(candidate.status == state ? Theme.macInk : Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func candidateBody(_ candidate: MemoryCandidate, validations: [ValidationResult]) -> String {
        var sections = [
            "Evidence:\n\(candidate.evidenceText)",
            "Proposed claim:\n\(candidate.proposedClaim)"
        ]
        if let graph = candidate.proposedGraph, !graph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Proposed graph:\n\(graph)")
        } else {
            sections.append("Proposed graph:\nnone")
        }
        if !validations.isEmpty {
            let validationText = validations
                .map { "\($0.kind): \($0.passed ? "passed" : "not passed") - \($0.detail)" }
                .joined(separator: "\n")
            sections.append("Validation:\n\(validationText)")
        } else if let validationResult = candidate.validationResult {
            sections.append("Review:\n\(validationResult)")
        }
        return sections.joined(separator: "\n\n")
    }

    private func inspectorBlock(title: String, subtitle: String, body: String, status: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 12).weight(.semibold))
                    .foregroundStyle(Theme.macInk)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let status {
                    statusBadge(status)
                }
            }
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

    private func statusBadge(_ status: String) -> some View {
        Text(status)
            .font(.system(size: 9).weight(.bold))
            .foregroundStyle(Theme.macInk.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.macEntry.opacity(0.34), in: Capsule())
            .overlay(Capsule().stroke(Theme.macHair, lineWidth: 1))
    }
}

private extension WorkbenchToolState {
    var tint: Color {
        switch self {
        case .available:
            return Theme.macRed.opacity(0.85)
        case .readOnly:
            return Theme.macInk.opacity(0.62)
        case .planned:
            return Theme.macFaint
        }
    }
}

private struct MacHarnessWatermark: View {
    var body: some View {
        Image("HarnessWatermark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Theme.macInk)
            .accessibilityHidden(true)
    }
}

private struct OutlinedHarnessTitle: View {
    private let text: String
    private let outlineOffsets: [CGSize] = [
        CGSize(width: -0.35, height: -0.35),
        CGSize(width: 0, height: -0.4),
        CGSize(width: 0.35, height: -0.35),
        CGSize(width: -0.4, height: 0),
        CGSize(width: 0.4, height: 0),
        CGSize(width: -0.35, height: 0.35),
        CGSize(width: 0, height: 0.4),
        CGSize(width: 0.35, height: 0.35)
    ]

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        ZStack {
            ForEach(Array(outlineOffsets.enumerated()), id: \.offset) { _, offset in
                titleText
                    .foregroundStyle(Theme.macInk.opacity(0.34))
                    .offset(x: offset.width, y: offset.height)
            }

            titleText
                .foregroundStyle(Theme.macBg)
        }
        .accessibilityLabel(text)
    }

    private var titleText: some View {
        Text(text)
            .font(.custom("PlayfairDisplay-Regular", size: 24).weight(.black))
            .tracking(0)
    }
}
#endif
