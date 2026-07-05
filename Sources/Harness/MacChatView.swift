#if os(macOS)
import SwiftUI
import OntologyKit

struct MacChatView: View {
    let ontology: Ontology
    @StateObject private var model = MacWorkbenchModel()
    @State private var inspectorTab: WorkbenchInspectorTab = .authority
    @SceneStorage("MacChatView.isSidebarVisible") private var isSidebarVisible = true
    @SceneStorage("MacChatView.isInspectorVisible") private var isInspectorVisible = true
    @SceneStorage("MacChatView.sidebarRailWidth") private var sidebarWidth = HarnessWorkbenchLayoutState.defaultSidebarWidth
    @SceneStorage("MacChatView.inspectorRailWidth") private var inspectorWidth = HarnessWorkbenchLayoutState.defaultInspectorWidth
    @SceneStorage("MacChatView.centerView") private var centerViewRaw = WorkbenchCenterView.chat.rawValue
    @AppStorage("MacChatView.opportunityBoardViewMode") private var opportunityBoardViewModeRaw = OpportunityBoardViewMode.all.rawValue
    @State private var sidebarDragStartWidth: Double?
    @State private var inspectorDragStartWidth: Double?
    @State private var isInspectorDetailPresented = false
    @State private var selectedOpportunityIDs = Set<String>()

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                sidebar
                panelResizeHandle(.sidebar)
                Divider().overlay(Theme.macHair)
            }
            transcript
            if isInspectorVisible {
                Divider().overlay(Theme.macHair)
                panelResizeHandle(.inspector)
                inspector
            }
        }
        .frame(minWidth: CGFloat(currentLayout.minimumWindowWidth), minHeight: 680)
        .background(Theme.macBg.ignoresSafeArea())
        .onAppear {
            normalizePanelWidths()
            model.updateOntology(ontology)
        }
        .sheet(isPresented: $isInspectorDetailPresented) {
            expandedInspectorSheet
        }
        .onChange(of: ontology.connections.count) { _, _ in model.updateOntology(ontology) }
        .onChange(of: model.searchText) { _, _ in Task { await model.searchRuns() } }
        .onChange(of: model.opportunityBoardRows.map(\.id)) { _, ids in
            selectedOpportunityIDs.formIntersection(Set(ids))
        }
    }

    private var currentLayout: HarnessWorkbenchLayoutState {
        HarnessWorkbenchLayoutState(
            isSidebarVisible: isSidebarVisible,
            isInspectorVisible: isInspectorVisible,
            sidebarWidth: sidebarWidth,
            inspectorWidth: inspectorWidth
        )
    }

    private func normalizePanelWidths() {
        sidebarWidth = HarnessWorkbenchLayoutState.clampedSidebarWidth(sidebarWidth)
        inspectorWidth = HarnessWorkbenchLayoutState.clampedInspectorWidth(inspectorWidth)
    }

    private var centerView: WorkbenchCenterView {
        WorkbenchCenterView(rawValue: centerViewRaw) ?? .chat
    }

    private var centerViewBinding: Binding<WorkbenchCenterView> {
        Binding(
            get: { centerView },
            set: { centerViewRaw = $0.rawValue }
        )
    }

    private var opportunityBoardViewMode: OpportunityBoardViewMode {
        OpportunityBoardViewMode(rawValue: opportunityBoardViewModeRaw) ?? .all
    }

    private var opportunityBoardViewModeBinding: Binding<OpportunityBoardViewMode> {
        Binding(
            get: { opportunityBoardViewMode },
            set: { opportunityBoardViewModeRaw = $0.rawValue }
        )
    }

    private var opportunityBoardProjection: OpportunityBoardProjection {
        OpportunityBoardProjection(rows: model.opportunityBoardRows)
    }

    private var visibleOpportunityRows: [OpportunityBoardRow] {
        opportunityBoardProjection.rows(for: opportunityBoardViewMode)
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
        .frame(width: CGFloat(currentLayout.sidebarWidth), alignment: .leading)
        .background(Theme.macBg)
    }

    private func panelResizeHandle(_ target: WorkbenchPanelResizeTarget) -> some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.macHair.opacity(0.9))
                .frame(width: 2, height: 34)
        }
        .frame(width: CGFloat(HarnessWorkbenchLayoutState.resizeHandleWidth))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    switch target {
                    case .sidebar:
                        let start = sidebarDragStartWidth ?? sidebarWidth
                        sidebarDragStartWidth = start
                        sidebarWidth = HarnessWorkbenchLayoutState.clampedSidebarWidth(
                            start + Double(value.translation.width)
                        )
                    case .inspector:
                        let start = inspectorDragStartWidth ?? inspectorWidth
                        inspectorDragStartWidth = start
                        inspectorWidth = HarnessWorkbenchLayoutState.clampedInspectorWidth(
                            start - Double(value.translation.width)
                        )
                    }
                }
                .onEnded { _ in
                    sidebarDragStartWidth = nil
                    inspectorDragStartWidth = nil
                }
        )
        .help("Drag to resize")
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
            centerViewContent
            delegateLabel
            composer
        }
        .frame(minWidth: CGFloat(HarnessWorkbenchLayoutState.transcriptMinimumWidth), maxWidth: .infinity)
        .background(Theme.macBg)
    }

    @ViewBuilder
    private var centerViewContent: some View {
        switch centerView {
        case .chat:
            chatTranscriptView
        case .cockpit:
            MacCockpitView { prompt in
                model.draft = prompt
                centerViewRaw = WorkbenchCenterView.chat.rawValue
            }
        case .board:
            delegationQueueView
        }
    }

    private var chatTranscriptView: some View {
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
    }

    private var delegationQueueView: some View {
        VStack(spacing: 0) {
            opportunityBoardToolbar

            if visibleOpportunityRows.isEmpty {
                opportunityBoardEmptyState
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        opportunityBoardHeader
                        if opportunityBoardViewMode == .byApp {
                            ForEach(opportunityBoardProjection.groupsByApp()) { group in
                                delegationAppHeader(group.app, count: group.rows.count)
                                ForEach(group.rows) { row in
                                    opportunityBoardRow(row)
                                }
                            }
                        } else {
                            ForEach(visibleOpportunityRows) { row in
                                opportunityBoardRow(row)
                            }
                        }
                    }
                    .padding(18)
                }
            }

            opportunityBoardActionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var opportunityBoardToolbar: some View {
        HStack(spacing: 10) {
            Picker("Queue View", selection: opportunityBoardViewModeBinding) {
                ForEach(OpportunityBoardViewMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 174)

            statusBadge("\(model.opportunityBoardRows.count) item\(model.opportunityBoardRows.count == 1 ? "" : "s")")

            if let issue = model.opportunityBoardLoadIssue {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(Theme.macRed)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                model.refreshOpportunityBoard()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.macInk.opacity(0.68))
                    .frame(width: 28, height: 24)
                    .background(Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .overlay(Rectangle().fill(Theme.macHair).frame(height: 1), alignment: .bottom)
    }

    private var opportunityBoardEmptyState: some View {
        ZStack {
            MacHarnessWatermark()
                .frame(width: 260, height: 300)
                .opacity(0.12)

            VStack(spacing: 8) {
                Text("No delegations queued")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(Theme.macInk)
                Text(MacWorkbenchModel.defaultOpportunityBoardDirectory().path)
                    .font(.caption)
                    .foregroundStyle(Theme.macInk.opacity(0.48))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var opportunityBoardHeader: some View {
        HStack(spacing: 0) {
            opportunityHeaderCell("", width: 28)
            opportunityHeaderCell("Delegation", width: 280)
            opportunityHeaderCell("App", width: 126)
            opportunityHeaderCell("Fit", width: 58, alignment: .trailing)
            opportunityHeaderCell("Priority", width: 76, alignment: .trailing)
            opportunityHeaderCell("Due", width: 72, alignment: .trailing)
            opportunityHeaderCell("Energy", width: 84, alignment: .trailing)
            opportunityHeaderCell("Seen", width: 56, alignment: .trailing)
            opportunityHeaderCell("Sources", width: 66, alignment: .trailing)
            opportunityHeaderCell("Rules", width: 138)
            opportunityHeaderCell("Agent", width: 118)
            opportunityHeaderCell("$ Order", width: 78)
            opportunityHeaderCell("Effort", width: 68)
        }
        .padding(.vertical, 7)
        .background(Theme.macEntry.opacity(0.18))
    }

    private func opportunityBoardRow(_ row: OpportunityBoardRow) -> some View {
        let selected = selectedOpportunityIDs.contains(row.id)
        let card = row.card

        return Button {
            toggleOpportunitySelection(row)
        } label: {
            HStack(spacing: 0) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12).weight(.semibold))
                    .foregroundStyle(selected ? Theme.macInk : Theme.macInk.opacity(0.38))
                    .frame(width: 28, alignment: .center)

                opportunityCell(opportunityTitle(row), width: 280, weight: .semibold)
                opportunityCell(card.app?.rawValue ?? card.rawApp ?? "-", width: 126)
                opportunityCell(formatFit(card.fit), width: 58, alignment: .trailing)
                opportunityCell(formatPriority(card.priority), width: 76, alignment: .trailing)
                opportunityCell(card.windowDays.map { "\($0)d" } ?? "-", width: 72, alignment: .trailing)
                opportunityCell("\(card.attention)", width: 84, alignment: .trailing)
                opportunityCell("\(card.timesSeen)", width: 56, alignment: .trailing)
                opportunityCell("\(card.sources)", width: 66, alignment: .trailing)
                opportunityCell(card.rulesHit.joined(separator: ", "), width: 138)
                opportunityCell(card.scoutID ?? "-", width: 118)
                opportunityCell(card.dollarOrder ?? "-", width: 78)
                opportunityCell(card.effort?.rawValue ?? card.rawEffort ?? "-", width: 68)
            }
            .padding(.vertical, 8)
            .background(selected ? Theme.macEntry.opacity(0.38) : Theme.macEntry.opacity(0.12))
            .overlay(Rectangle().fill(Theme.macHair).frame(height: 1), alignment: .bottom)
        }
        .buttonStyle(.plain)
        .help(row.canonicalResource)
    }

    private func delegationAppHeader(_ app: OpportunityApp, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(app.rawValue)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.macInk.opacity(0.7))
            statusBadge("\(count)")
        }
        .frame(width: 1_222, alignment: .leading)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var opportunityBoardActionBar: some View {
        HStack(spacing: 8) {
            Text("\(selectedOpportunityCount) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.macInk.opacity(0.56))

            Button {
                selectedOpportunityIDs.removeAll()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selectedOpportunityCount == 0 ? Theme.macInk.opacity(0.28) : Theme.macInk.opacity(0.68))
                    .frame(width: 28, height: 24)
                    .background(Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(selectedOpportunityCount == 0)
            .help("Clear selection")

            Spacer()

            opportunityActionButton("Pass", systemImage: "hand.raised", disabled: selectedOpportunityCount == 0) {
                model.recordOpportunityBoardAction(.pass, rows: selectedOpportunityRows)
                selectedOpportunityIDs.removeAll()
            }

            opportunityActionButton("Hold", systemImage: "pause.circle", disabled: selectedOpportunityCount == 0) {
                model.recordOpportunityBoardAction(.hold, rows: selectedOpportunityRows)
            }

            opportunityActionButton("Bookmark", systemImage: "bookmark", disabled: selectedOpportunityCount == 0) {
                model.recordOpportunityBoardAction(.bookmark, rows: selectedOpportunityRows)
            }

            opportunityActionButton("Pursue", systemImage: "arrow.up.right.circle", disabled: selectedOpportunityCount != 1) {
                pursueSelectedOpportunity()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .overlay(Rectangle().fill(Theme.macHair).frame(height: 1), alignment: .top)
    }

    private func opportunityActionButton(
        _ title: String,
        systemImage: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(disabled ? Theme.macInk.opacity(0.28) : Theme.macInk.opacity(0.78))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func opportunityHeaderCell(_ text: String, width: CGFloat, alignment: Alignment = .leading) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Theme.macInk.opacity(0.54))
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 5)
    }

    private func opportunityCell(
        _ text: String,
        width: CGFloat,
        alignment: Alignment = .leading,
        weight: Font.Weight = .regular
    ) -> some View {
        Text(text)
            .font(.system(size: 12).weight(weight))
            .foregroundStyle(Theme.macInk.opacity(0.78))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 5)
    }

    private var selectedOpportunityCount: Int {
        selectedOpportunityRows.count
    }

    private var selectedOpportunityRows: [OpportunityBoardRow] {
        let selected = selectedOpportunityIDs
        return model.opportunityBoardRows.filter { selected.contains($0.id) }
    }

    private func toggleOpportunitySelection(_ row: OpportunityBoardRow) {
        if selectedOpportunityIDs.contains(row.id) {
            selectedOpportunityIDs.remove(row.id)
        } else {
            selectedOpportunityIDs.insert(row.id)
        }
    }

    private func pursueSelectedOpportunity() {
        guard selectedOpportunityRows.count == 1, let row = selectedOpportunityRows.first else { return }
        let card = row.card
        model.recordOpportunityBoardAction(.pursue, rows: [row])
        model.draft = """
        Pursue delegation \(row.id): \(opportunityTitle(row))
        Resource: \(row.canonicalResource)
        Rules: \(card.rulesHit.joined(separator: ", "))
        Agent: \(card.scoutID ?? "unknown")
        """
        centerViewRaw = WorkbenchCenterView.chat.rawValue
    }

    private func opportunityTitle(_ row: OpportunityBoardRow) -> String {
        row.card.envelope.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? row.card.envelope.title!
            : row.id
    }

    private func formatFit(_ fit: Double?) -> String {
        guard let fit else { return "-" }
        return fit.formatted(.number.precision(.fractionLength(2)))
    }

    private func formatPriority(_ priority: Double) -> String {
        priority.formatted(.number.precision(.fractionLength(1)))
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            toolbarIconButton(
                isSidebarVisible ? "rectangle.leftthird.inset.filled" : "rectangle",
                help: isSidebarVisible ? "Hide left sidebar" : "Show left sidebar"
            ) {
                isSidebarVisible.toggle()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(centerViewTitle)
                    .font(.system(size: 14).weight(.semibold))
                    .foregroundStyle(Theme.macInk)
                    .lineLimit(1)
            }

            Spacer()

            Picker("View", selection: centerViewBinding) {
                ForEach(WorkbenchCenterView.allCases) { view in
                    Text(view.label).tag(view)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 214)

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

            toolbarIconButton(
                isInspectorVisible ? "rectangle.rightthird.inset.filled" : "rectangle",
                help: isInspectorVisible ? "Hide right inspector" : "Show right inspector"
            ) {
                isInspectorVisible.toggle()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(Rectangle().fill(Theme.macHair).frame(height: 1), alignment: .bottom)
    }

    private var centerViewTitle: String {
        switch centerView {
        case .chat:
            return model.selectedDetail?.run.prompt ?? "The Adam Pattern"
        case .cockpit:
            return "Harness Cockpit"
        case .board:
            return "Delegation Queue"
        }
    }

    private func toolbarIconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12).weight(.semibold))
                .foregroundStyle(Theme.macInk.opacity(0.68))
                .frame(width: 28, height: 24)
                .background(Theme.macEntry.opacity(0.26), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
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
            capabilityInsertMenu

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

    private var capabilityInsertMenu: some View {
        Menu {
            Button {
                model.newSession()
            } label: {
                Label("New Session", systemImage: "plus.bubble")
            }

            Divider()

            Menu {
                ForEach(menuCapabilities(kind: .skill).prefix(40)) { capability in
                    Button {
                        model.insertCapabilityReference(capability)
                    } label: {
                        Text(capability.name)
                    }
                }
                if menuCapabilities(kind: .skill).count > 40 {
                    Text("+ \(menuCapabilities(kind: .skill).count - 40) more")
                }
            } label: {
                Label("Skills", systemImage: "wrench.and.screwdriver")
            }

            Menu {
                ForEach(menuCapabilities(kind: .plugin).prefix(40)) { capability in
                    Button {
                        model.insertCapabilityReference(capability)
                    } label: {
                        Text(capability.name)
                    }
                }
                if menuCapabilities(kind: .plugin).count > 40 {
                    Text("+ \(menuCapabilities(kind: .plugin).count - 40) more")
                }
            } label: {
                Label("Plugins", systemImage: "shippingbox")
            }

            Menu {
                Button {
                    model.importNotebookLMSourceFromDownloads()
                } label: {
                    Label("Import from Downloads...", systemImage: "square.and.arrow.down")
                }

                Button {
                    model.chooseNotebookLMSource()
                } label: {
                    Label("Choose File...", systemImage: "doc.badge.plus")
                }

                Button {
                    model.openNotebookLMFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }

                Divider()

                let notebookFiles = model.notebookLMSourceFiles(limit: 20)
                if notebookFiles.isEmpty {
                    Text("No exports found")
                } else {
                    ForEach(notebookFiles) { source in
                        Button {
                            model.insertNotebookLMSourceReference(source)
                        } label: {
                            Label(source.menuTitle, systemImage: "text.book.closed")
                        }
                    }
                }
            } label: {
                Label("NotebookLM", systemImage: "text.book.closed")
            }

            Divider()

            Button {
                model.refreshConnectors()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13).weight(.semibold))
                .foregroundStyle(Theme.macInk.opacity(0.72))
                .frame(width: 30, height: 30)
                .background(Theme.macEntry.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Add skill, plugin, or source")
    }

    private func menuCapabilities(kind: HarnessCapabilityKind) -> [HarnessCapability] {
        model.capabilities
            .filter { $0.kind == kind }
            .sorted { lhs, rhs in
                if lhs.sourceSystem == rhs.sourceSystem {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.sourceSystem.localizedCaseInsensitiveCompare(rhs.sourceSystem) == .orderedAscending
            }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Analysis")
                    .font(.system(size: 11).weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(Theme.macInk.opacity(0.58))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    isInspectorDetailPresented = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11).weight(.semibold))
                        .foregroundStyle(Theme.macInk.opacity(0.66))
                        .frame(width: 24, height: 22)
                        .background(Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.macHair, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Open full analysis")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(WorkbenchInspectorTab.compactRailOrder) { tab in
                        compactInspectorCard(tab)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(model.status)
                .font(.caption)
                .foregroundStyle(Theme.macInk.opacity(0.45))
                .lineLimit(3)
        }
        .padding(10)
        .frame(width: CGFloat(currentLayout.inspectorWidth), alignment: .leading)
        .background(Theme.macBg)
    }

    private func openInspectorDetail(_ tab: WorkbenchInspectorTab) {
        inspectorTab = tab
        isInspectorDetailPresented = true
    }

    private func compactInspectorCard(_ tab: WorkbenchInspectorTab) -> some View {
        Button {
            openInspectorDetail(tab)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: inspectorIcon(tab))
                        .font(.system(size: 11).weight(.semibold))
                        .frame(width: 14)
                        .foregroundStyle(Theme.macInk.opacity(0.62))
                    Text(tab.rawValue)
                        .font(.system(size: 12).weight(.semibold))
                        .foregroundStyle(Theme.macInk.opacity(0.78))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(compactInspectorMetric(tab))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.macInk.opacity(0.58))
                        .lineLimit(1)
                }

                Text(compactInspectorSummary(tab))
                    .font(.caption2)
                    .foregroundStyle(Theme.macInk.opacity(0.48))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.macEntry.opacity(inspectorTab == tab ? 0.3 : 0.18), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Open \(tab.rawValue)")
    }

    private var expandedInspectorSheet: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(inspectorTab.rawValue)
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .foregroundStyle(Theme.macInk)
                    Text("Full analysis")
                        .font(.caption)
                        .foregroundStyle(Theme.macInk.opacity(0.52))
                }

                Spacer()

                Button {
                    isInspectorDetailPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12).weight(.semibold))
                        .foregroundStyle(Theme.macInk.opacity(0.66))
                        .frame(width: 28, height: 26)
                        .background(Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .overlay(Rectangle().fill(Theme.macHair).frame(height: 1), alignment: .bottom)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(WorkbenchInspectorTab.allCases) { tab in
                        Button {
                            inspectorTab = tab
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: inspectorIcon(tab))
                                    .frame(width: 15)
                                Text(tab.rawValue)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .font(.system(size: 12).weight(.semibold))
                            .foregroundStyle(inspectorTab == tab ? Theme.macInk : Theme.macInk.opacity(0.56))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(inspectorTab == tab ? Theme.macEntry.opacity(0.36) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(width: 180, alignment: .topLeading)
                .background(Theme.macEntry.opacity(0.08))

                Divider().overlay(Theme.macHair)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        inspectorPanel(for: inspectorTab)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 980, idealWidth: 1_120, minHeight: 720, idealHeight: 820)
        .background(Theme.macBg)
    }

    @ViewBuilder
    private func inspectorPanel(for tab: WorkbenchInspectorTab) -> some View {
        switch tab {
        case .authority:
            authorityPanel
        case .route:
            routePanel
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

    private func compactInspectorMetric(_ tab: WorkbenchInspectorTab) -> String {
        switch tab {
        case .authority:
            return "\(model.selectedDetail?.authorityHits.count ?? 0)"
        case .route:
            return model.routePlan.steps.isEmpty ? "idle" : "\(model.routePlan.steps.count)"
        case .memory:
            return "\(model.selectedDetail?.memoryHits.count ?? 0)"
        case .connectors:
            let available = model.connectors.filter { $0.state == .available }.count
            return "\(available)/\(model.connectors.count)"
        case .skills:
            return "\(model.capabilities.count)"
        case .trace:
            return "\(model.selectedDetail?.traceEvents.count ?? 0)"
        case .candidates:
            return "\(model.reviewQueueCandidates.count)"
        }
    }

    private func compactInspectorSummary(_ tab: WorkbenchInspectorTab) -> String {
        switch tab {
        case .authority:
            return model.selectedDetail?.authorityHits.first?.subject ?? "Accepted graph context"
        case .route:
            return model.routePlan.summary
        case .memory:
            return model.selectedDetail?.memoryHits.first?.source ?? "Local notes and repo memory"
        case .connectors:
            return "Sources, skills, plugins, and MCP"
        case .skills:
            return "Discovered agent abilities"
        case .trace:
            return model.selectedDetail?.traceEvents.first?.message ?? "Run ledger and eval checks"
        case .candidates:
            return model.reviewQueueCandidates.first?.plainEnglish ?? "Claims waiting for review"
        }
    }

    private func inspectorIcon(_ tab: WorkbenchInspectorTab) -> String {
        switch tab {
        case .authority:
            return "checkmark.seal"
        case .route:
            return "arrow.triangle.branch"
        case .memory:
            return "archivebox"
        case .connectors:
            return "point.3.connected.trianglepath.dotted"
        case .skills:
            return "wrench.and.screwdriver"
        case .trace:
            return "waveform.path.ecg"
        case .candidates:
            return "tray.and.arrow.down"
        }
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

    private var routePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(model.routePlan.summary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.macInk.opacity(0.58))
                    .lineLimit(2)
                Spacer()
                Button {
                    model.runReadOnlyRoute()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.routePlan.steps.isEmpty ? Theme.macInk.opacity(0.28) : Theme.macInk.opacity(0.68))
                        .frame(width: 28, height: 24)
                        .background(Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(model.routePlan.steps.isEmpty)
                .help("Run read-only route steps")
                statusBadge(model.routePlan.requiresApproval ? "Needs Approval" : "Read-only")
            }

            if model.routePlan.steps.isEmpty {
                emptyInspectorText("Type a prompt to preview the guarded route before execution.")
            } else {
                ForEach(model.routePlan.steps) { step in
                    routeStepBlock(step)
                }
            }

            if let result = model.routeExecutionResult {
                inspectorBlock(
                    title: "Route Result",
                    subtitle: "\(result.executedSteps.count) executed - \(result.blockedSteps.count) blocked",
                    body: result.summary,
                    status: "executed"
                )

                ForEach(result.actionResults) { actionResult in
                    inspectorBlock(
                        title: HarnessExecutionRouteStep.displayName(actionResult.targetName.replacingOccurrences(of: "-", with: " ")),
                        subtitle: actionResultSubtitle(actionResult),
                        body: actionResultBody(actionResult),
                        status: "action"
                    )
                }

                ForEach(result.memoryHits.prefix(5)) { hit in
                    inspectorBlock(
                        title: memoryHitTitle(hit),
                        subtitle: memoryHitSubtitle(hit),
                        body: memoryHitBody(hit),
                        status: hit.sourceCard == nil ? "evidence" : "source card"
                    )
                }
            }
        }
    }

    private func routeStepBlock(_ step: HarnessExecutionRouteStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(step.displayTitle)
                    .font(.system(size: 12).weight(.semibold))
                    .foregroundStyle(Theme.macInk)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if step.guardrail == .approvalRequired {
                    Button {
                        model.approveAndRunRouteStep(step)
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.macInk.opacity(0.68))
                            .frame(width: 24, height: 22)
                            .background(Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Approve and run this step")
                }
                statusBadge(step.guardrail.displayLabel)
            }
            Text("\(step.displaySubtitle) - \(step.action.displayLabel)")
                .font(.caption2)
                .foregroundStyle(Theme.macInk.opacity(0.46))
                .lineLimit(1)
            Text("\(step.reason)\n\nState: \(step.state.rawValue)")
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

    private func actionResultSubtitle(_ result: HarnessRouteActionResult) -> String {
        if let adapterName = result.adapterName {
            return "\(result.action.displayLabel) - \(adapterName)"
        }
        return result.action.displayLabel
    }

    private func actionResultBody(_ result: HarnessRouteActionResult) -> String {
        var parts = [result.summary]
        if let artifactURL = result.artifactURL {
            parts.append("Markdown: \(artifactURL.path)")
        }
        if let pdfURL = result.pdfURL {
            parts.append("PDF: \(pdfURL.path)")
        }
        return parts.joined(separator: "\n\n")
    }

    private func memoryHitTitle(_ hit: MemoryHit) -> String {
        guard let card = hit.sourceCard else { return hit.source }
        if let title = card.title, !title.isEmpty {
            return title
        }
        return card.type
    }

    private func memoryHitSubtitle(_ hit: MemoryHit) -> String {
        let score = hit.score.formatted(.number.precision(.fractionLength(2)))
        guard let card = hit.sourceCard else {
            return "\(hit.authorityLevel.rawValue), not graph authority - score \(score)"
        }
        return "\(card.authorityLevel.rawValue), \(card.connectorTitle) - \(card.type) - score \(score)"
    }

    private func memoryHitBody(_ hit: MemoryHit) -> String {
        guard let card = hit.sourceCard else {
            return "\(hit.reasonSelected)\n\n\(hit.excerpt)"
        }

        var parts: [String] = []
        if let description = card.description {
            parts.append(description)
        }
        if let resource = card.resource {
            parts.append("Resource: \(resource)")
        }
        if let timestamp = card.timestamp {
            parts.append("Timestamp: \(timestamp)")
        }
        if !card.tags.isEmpty {
            parts.append("Tags: \(card.tags.joined(separator: ", "))")
        }
        if let declaredTrustLevel = card.declaredTrustLevel {
            parts.append("Self-declared trust: \(declaredTrustLevel)")
        }
        if let trustNote = card.trustNote {
            parts.append(trustNote)
        }
        parts.append("Source: \(card.source)")
        parts.append("Reason: \(hit.reasonSelected)")
        parts.append("Excerpt: \(hit.excerpt)")
        return parts.joined(separator: "\n\n")
    }

    private var memoryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            memorySourcesPanel

            if let detail = model.selectedDetail, !detail.memoryHits.isEmpty {
                ForEach(detail.memoryHits) { hit in
                    inspectorBlock(
                        title: memoryHitTitle(hit),
                        subtitle: memoryHitSubtitle(hit),
                        body: memoryHitBody(hit),
                        status: hit.sourceCard == nil ? "supporting" : "source card"
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
        case .notebookLM:
            return "text.book.closed"
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
            firecrawlConnectorSettings

            ForEach(model.connectors) { connector in
                inspectorBlock(
                    title: connector.title,
                    subtitle: "\(connector.sourceSystem) - \(connector.role.rawValue) - \(connector.state.rawValue)",
                    body: "\(connector.summary)\n\nPermission: \(connector.permission)\n\nProvenance: \(connector.provenance)\n\nLocation: \(connectorLocation(connector))",
                    status: connector.kind.rawValue
                )
            }
        }
    }

    private var firecrawlConnectorSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "network")
                    .foregroundStyle(Theme.macInk.opacity(0.58))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Firecrawl MCP")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.macInk.opacity(0.76))
                    Text(model.hasFirecrawlAPIKey ? "Key saved in Keychain" : "Paste your Firecrawl API key")
                        .font(.caption2)
                        .foregroundStyle(Theme.macInk.opacity(0.44))
                }
                Spacer()
                statusBadge(model.hasFirecrawlAPIKey ? "available" : "needs key")
            }

            SecureField(model.hasFirecrawlAPIKey ? "Replace saved key..." : "fc-...", text: $model.firecrawlAPIKey)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.macInk)
                .padding(8)
                .background(Theme.macEntry.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))

            HStack(spacing: 8) {
                Button {
                    model.saveFirecrawlAPIKey()
                } label: {
                    Label("Save", systemImage: "key")
                        .font(.caption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(model.firecrawlAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Save Firecrawl key to Keychain")

                Button {
                    model.deleteFirecrawlAPIKey()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.macInk.opacity(model.hasFirecrawlAPIKey ? 0.68 : 0.28))
                        .frame(width: 28, height: 24)
                        .background(Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!model.hasFirecrawlAPIKey)
                .help("Remove Firecrawl key from Keychain")
            }

            Text("Harness uses this key only for approval-gated Firecrawl research. It is not shown in connector details.")
                .font(.caption)
                .foregroundStyle(Theme.macInk.opacity(0.54))
                .lineLimit(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
    }

    private func connectorLocation(_ connector: HarnessConnector) -> String {
        connector.root.isFileURL ? connector.root.path : connector.root.absoluteString
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
                    model.captureEvidence()
                } label: {
                    Label("Capture evidence", systemImage: "waveform.path.ecg")
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

enum WorkbenchCenterView: String, CaseIterable, Identifiable, Hashable {
    case chat
    case cockpit
    case board

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat:
            return "Chat"
        case .cockpit:
            return "Cockpit"
        case .board:
            return "Delegation"
        }
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

private enum WorkbenchPanelResizeTarget {
    case sidebar
    case inspector
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
