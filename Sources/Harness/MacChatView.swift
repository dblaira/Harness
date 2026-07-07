#if os(macOS)
import SwiftUI
import OntologyKit

struct MacChatView: View {
    let ontology: Ontology
    @StateObject private var model = MacWorkbenchModel()
    @State private var inspectorTab: WorkbenchInspectorTab = .authority
    @State private var isSidebarVisible = false
    @State private var isInspectorVisible = false
    @SceneStorage("MacChatView.sidebarRailWidth") private var sidebarWidth = HarnessWorkbenchLayoutState.defaultSidebarWidth
    @SceneStorage("MacChatView.inspectorRailWidth") private var inspectorWidth = HarnessWorkbenchLayoutState.defaultInspectorWidth
    @SceneStorage("MacChatView.centerView") private var centerViewRaw = WorkbenchCenterView.chat.rawValue
    @AppStorage("MacChatView.opportunityBoardViewMode") private var opportunityBoardViewModeRaw = OpportunityBoardViewMode.all.rawValue
    @State private var sidebarDragStartWidth: Double?
    @State private var inspectorDragStartWidth: Double?
    @State private var isInspectorDetailPresented = false
    @State private var selectedOpportunityIDs = Set<String>()
    @State private var delegationEntryKind: MacSuiteEntryKind = .action
    @State private var isDelegationEntryFormPresented = false
    @State private var showingLinkSheet = false
    @State private var showingGitHubSheet = false
    @State private var linkInput = ""
    @State private var githubRepoInput = ""

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
        .sheet(isPresented: $showingLinkSheet) {
            composerLinkSheet(
                title: "Add Link",
                placeholder: "https://youtube.com/watch?v=… or any URL",
                text: $linkInput
            ) {
                model.addComposerLink(linkInput)
                linkInput = ""
                showingLinkSheet = false
            }
        }
        .sheet(isPresented: $showingGitHubSheet) {
            composerLinkSheet(
                title: "Add GitHub Repo",
                placeholder: "owner/repo or https://github.com/owner/repo",
                text: $githubRepoInput
            ) {
                model.addComposerLink(githubRepoInput)
                githubRepoInput = ""
                showingGitHubSheet = false
            }
        }
        .onChange(of: ontology.connections.count) { _, _ in model.updateOntology(ontology) }
        .onChange(of: model.searchText) { _, _ in Task { await model.searchSessions() } }
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
                .font(Theme.recallBody(14))
                .foregroundStyle(Theme.macEntryInk)
                .padding(10)
                .background(Theme.macEntry, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))

            Text("SESSIONS")
                .font(Theme.recallLabel(12))
                .tracking(2.0)
                .foregroundStyle(Theme.macTan)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if model.sessionSearchHits.isEmpty {
                            Text("No matching sessions")
                                .font(Theme.recallBody(12))
                                .foregroundStyle(Theme.macMuted)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(model.sessionSearchHits) { hit in
                                Button {
                                    model.selectSessionSearchHit(hit)
                                } label: {
                                    sessionSearchHitRow(hit)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else if model.chatSessions.isEmpty {
                        Text("No sessions yet")
                            .font(Theme.recallBody(12))
                            .foregroundStyle(Theme.macMuted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(model.chatSessions) { session in
                            Button {
                                model.selectSession(session)
                            } label: {
                                chatSessionRow(session)
                            }
                            .buttonStyle(.plain)
                        }
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
                    .font(Theme.recallLabel(11))
                    .tracking(1.8)
                    .foregroundStyle(Theme.macTan.opacity(0.85))
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

    private func chatSessionRow(_ session: ChatSession) -> some View {
        let selected = model.currentSessionId == session.id
        return VStack(alignment: .leading, spacing: 3) {
            Text(session.title)
                .font(Theme.recallBody(14, weight: .semibold))
                .lineLimit(1)
            Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(Theme.recallBody(12))
                .lineLimit(1)
                .foregroundStyle(selected ? Theme.macEntryInk.opacity(0.55) : Theme.macMuted)
        }
        .foregroundStyle(selected ? Theme.macEntryInk : Theme.macInk)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.macEntry : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private func sessionSearchHitRow(_ hit: SessionSearchHit) -> some View {
        let selected = model.currentSessionId == hit.sessionId
        return VStack(alignment: .leading, spacing: 3) {
            Text(hit.title)
                .font(Theme.recallBody(14, weight: .semibold))
                .lineLimit(1)
            Text(hit.snippet)
                .font(Theme.recallBody(12))
                .lineLimit(2)
                .foregroundStyle(selected ? Theme.macEntryInk.opacity(0.55) : Theme.macMuted)
        }
        .foregroundStyle(selected ? Theme.macEntryInk : Theme.macInk)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.macEntry : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            topBar
            centerViewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if centerView != .board && centerView != .chat {
                delegateLabel
                composer
            }
        }
        .frame(minWidth: CGFloat(HarnessWorkbenchLayoutState.transcriptMinimumWidth), maxWidth: .infinity)
        .background(Theme.macBg)
    }

    @ViewBuilder
    private var centerViewContent: some View {
        switch centerView {
        case .chat:
            MacDelegateFormView(model: model)
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
                .opacity(model.chatThread.isEmpty && model.selectedDetail == nil ? 0.18 : 0.08)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.chatThread.isEmpty {
                        if let detail = model.selectedDetail {
                            runSummary(detail)
                        }
                        ForEach(model.chatThread) { turn in
                            chatTurnBubble(turn)
                        }
                    } else if let detail = model.selectedDetail {
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
                            Button("Cancel") {
                                model.cancelRun()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.macRed)
                            .help("Cancel the running query")
                        }
                        .padding(.top, 4)
                    } else if let statusText = HarnessTranscriptCopy.statusCopyText(status: model.status) {
                        HStack(spacing: 10) {
                            Text(model.status)
                                .foregroundStyle(Theme.macInk.opacity(0.55))
                            copyTranscriptButton(
                                label: "Copy status",
                                help: "Copy the status or error message",
                                text: statusText
                            )
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
        GeometryReader { proxy in
            if proxy.size.width < 1_040 {
                delegationQueueListSurface(showAgent: false)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    delegationQueueListSurface(showAgent: proxy.size.width >= 1_220)
                        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)

                    ScrollView {
                        macSuiteActionForm(activeDelegationRow)
                    }
                    .frame(width: min(max(proxy.size.width * 0.34, 430), 560))
                    .frame(maxHeight: .infinity)
                }
                .padding(14)
            }
        }
        .background(Theme.savyPaper)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isDelegationEntryFormPresented) {
            delegationEntryFormSheet
        }
    }

    private var delegationEntryFormSheet: some View {
        macSuiteActionForm(activeDelegationRow)
            .padding(10)
        .background(Theme.savyPaper)
        .tint(Theme.savyCrimson)
        .frame(minWidth: 660, idealWidth: 720, maxWidth: 780, minHeight: 520, idealHeight: 560, alignment: .top)
    }

    private func macSuiteActionForm(_ row: OpportunityBoardRow?) -> some View {
        let detail = row.map(MacDelegationDetail.init) ?? .empty

        return VStack(spacing: 0) {
            HStack {
                Button {
                    isDelegationEntryFormPresented = false
                } label: {
                    suiteCircleIcon("xmark.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")

                Spacer()
                Text("Action")
                    .font(Theme.savyDisplaySerif(19, weight: .bold))
                    .foregroundStyle(Color.black)
                Spacer()
                Button {
                    isDelegationEntryFormPresented = false
                } label: {
                    MacFloppyDiskIcon(size: 13)
                        .frame(width: 22, height: 22)
                        .background(Color.white, in: Circle())
                        .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save")
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 5)

            suiteKindPicker
                .padding(.horizontal, 10)
                .padding(.bottom, 5)

            suiteFormSections(detail)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
    }

    @ViewBuilder
    private func suiteFormSections(_ detail: MacDelegationDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            suiteDelegateSection(detail)

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    suitePatternSection(detail)
                    suiteChooseSection(detail)
                    suiteScheduleSection(detail)
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(alignment: .leading, spacing: 3) {
                    suiteOrganizeSection(detail)
                    suiteDetailsSection(detail)
                    suitePlacePeopleSection(detail)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func suiteDelegateSection(_ detail: MacDelegationDetail) -> some View {
        suiteSection("Delegate") {
            suiteTextRow(detail.title, placeholder: "What do I want?")
            suiteDivider
            suiteTextRow(detail.description, placeholder: "When I am...I like to")
            suiteDivider
            suiteTextRow(detail.clearSignOfSuccess, placeholder: "Done looks like...")
            suiteDivider
            suiteStepsRow(detail.nextAgentQuestions)
        }
    }

    private func suitePatternSection(_ detail: MacDelegationDetail) -> some View {
        suiteSection("Pattern") {
            suiteMenuRow(
                "Pattern",
                icon: "list.number",
                value: detail.patternValue,
                options: MacSuiteFormCopy.patternChoices
            )
        }
    }

    private func suiteChooseSection(_ detail: MacDelegationDetail) -> some View {
        suiteSection("Choose") {
            suiteMenuRow(
                "Priority",
                icon: "exclamationmark.3",
                value: detail.priorityValue,
                options: MacSuiteFormCopy.priorityChoices
            )
            suiteDivider
            suiteMenuRow(
                "Effort",
                icon: "timer",
                value: detail.effortValue,
                options: MacSuiteFormCopy.effortChoices
            )
            suiteDivider
            suiteMenuRow(
                "Energy",
                icon: "bolt",
                value: detail.energyValue,
                options: MacSuiteFormCopy.energyChoices
            )
        }
    }

    private func suiteScheduleSection(_ detail: MacDelegationDetail) -> some View {
        suiteSection("Schedule") {
            suiteToggleRow("Due", icon: "calendar", value: detail.dueValue)
            suiteDivider
            suiteToggleRow("Start / defer", icon: "calendar.badge.clock", value: detail.startDeferValue)
            suiteDivider
            suiteMenuRow("Repeat", icon: "repeat", value: "Never", options: MacSuiteFormCopy.repeatChoices)
            suiteDivider
            suiteToggleRow("Nudge", icon: "bell", value: detail.nudgeValue)
            suiteDivider
            suiteToggleRow("End", icon: "clock.badge.checkmark", value: detail.endValue)
        }
    }

    private func suiteOrganizeSection(_ detail: MacDelegationDetail) -> some View {
        suiteSection("Organize") {
            suiteMenuRow("Lift", icon: "sparkles", value: detail.liftValue, options: MacSuiteFormCopy.liftChoices)
            suiteDivider
            suiteFlagRow
            suiteDivider
            suiteTagsRow(detail.tagsValue)
            suiteDivider
            suiteRecentTagRow
        }
    }

    private func suiteDetailsSection(_ detail: MacDelegationDetail) -> some View {
        suiteSection("Details") {
            suiteTextRow(detail.notesValue, placeholder: "Notes")
            suiteDivider
            suiteTextRow(detail.resource, placeholder: "Link")
            suiteDivider
            suiteImageRow
        }
    }

    private func suitePlacePeopleSection(_ detail: MacDelegationDetail) -> some View {
        suiteSection("Place / People") {
            suiteTextIconRow("Location", icon: "mappin.and.ellipse", value: detail.locationValue)
            suiteDivider
            suiteTextIconRow("Waiting on / delegate to", icon: "person", value: detail.agent)
        }
    }

    private var suiteKindPicker: some View {
        HStack(spacing: 0) {
            ForEach(MacSuiteEntryKind.allCases) { kind in
                Button {
                    delegationEntryKind = kind
                } label: {
                    Text(kind.label)
                        .font(Theme.savyRobotoMedium(9))
                        .foregroundStyle(delegationEntryKind == kind ? Color.black : Color.black.opacity(0.82))
                        .frame(maxWidth: .infinity)
                        .frame(height: 16)
                        .background(
                            delegationEntryKind == kind ? Color.white : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.savyCard.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.04), lineWidth: 1))
    }

    private func suiteCircleIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black)
            .frame(width: 22, height: 22)
            .background(Color.white, in: Circle())
            .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 1))
    }

    private func suiteSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.savyRobotoMedium(8))
                .foregroundStyle(Color.black.opacity(0.48))
                .padding(.leading, 6)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.vertical, 1)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.savyCard, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var suiteDivider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 22)
    }

    private func suiteTextRow(_ value: String, placeholder: String) -> some View {
        Text(value == "-" ? placeholder : value)
            .font(Theme.savyRobotoMedium(9))
            .foregroundStyle(value == "-" ? Theme.savyTertiaryText : Color.black)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
            .padding(.vertical, 0)
    }

    private func suiteTextIconRow(_ placeholder: String, icon: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(value == "-" ? Color.black.opacity(0.38) : Theme.savyCrimson)
                .frame(width: 17)

            Text(value == "-" ? placeholder : value)
                .font(Theme.savyRobotoMedium(9))
                .foregroundStyle(value == "-" ? Theme.savyTertiaryText : Color.black)
                .lineLimit(2)

            Spacer(minLength: 8)
        }
        .frame(minHeight: 18)
        .padding(.vertical, 0)
    }

    private func suiteMenuRow(_ title: String, icon: String, value: String, options: [String]) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) {}
            }
        } label: {
            suiteMenuLabel(title, icon: icon, value: value)
        }
        .buttonStyle(.plain)
    }

    private func suiteMenuLabel(_ title: String, icon: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.savyCrimson)
                .frame(width: 17)

            Text(title)
                .font(Theme.savyRobotoMedium(9))
                .foregroundStyle(Color.black)

            Spacer(minLength: 8)

            Text(value)
                .font(Theme.savyRobotoMedium(9))
                .foregroundStyle(Theme.savyCrimson)
                .lineLimit(1)

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(Theme.savyCrimson)
        }
        .frame(minHeight: 18)
        .padding(.vertical, 0)
        .contentShape(Rectangle())
    }

    private func suiteToggleRow(_ title: String, icon: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.savyCrimson)
                .frame(width: 17)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Theme.savyRobotoMedium(9))
                    .foregroundStyle(Color.black)
                Text(value)
                    .font(Theme.savyRobotoMedium(8))
                    .foregroundStyle(Theme.savyTertiaryText)
            }

            Spacer(minLength: 8)

            MacSuiteFormRows.switchToggle(isOn: .constant(false))
        }
        .frame(minHeight: 19)
        .padding(.vertical, 0)
    }

    private func suiteStepsRow(_ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.savyCrimson)
                .frame(width: 17)

            VStack(alignment: .leading, spacing: 1) {
                Text("Steps")
                    .font(Theme.savyRobotoMedium(9))
                    .foregroundStyle(Color.black)

                Text(value == "-" ? "Add Step" : value)
                    .font(Theme.savyRobotoMedium(value == "-" ? 9 : 8))
                    .foregroundStyle(value == "-" ? Theme.savyCrimson : Color.black.opacity(0.7))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 1)
    }

    private var suiteFlagRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "flag")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.savyCrimson)
                .frame(width: 17)
            Text("Flag")
                .font(Theme.savyRobotoMedium(9))
                .foregroundStyle(Color.black)
            Spacer(minLength: 8)
            MacSuiteFormRows.switchToggle(isOn: .constant(false))
        }
        .frame(minHeight: 18)
        .padding(.vertical, 0)
    }

    private func suiteTagsRow(_ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tag")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.savyCrimson)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 0) {
                Text("Tags")
                    .font(Theme.savyRobotoMedium(9))
                    .foregroundStyle(Color.black)
                Text(value == "-" ? "Add a tag" : value)
                    .font(Theme.savyRobotoMedium(8))
                    .foregroundStyle(value == "-" ? Theme.savyTertiaryText : Color.black.opacity(0.62))
            }
            Spacer(minLength: 8)
            Text("Add")
                .font(Theme.savyRobotoMedium(9))
                .foregroundStyle(Theme.savyCrimson.opacity(value == "-" ? 0.55 : 1))
        }
        .frame(minHeight: 19)
        .padding(.vertical, 0)
    }

    private var suiteRecentTagRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.savyCrimson)
                .frame(width: 17)
            Text("Add a recent tag")
                .font(Theme.savyRobotoMedium(9))
                .foregroundStyle(Theme.savyCrimson)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(Theme.savyCrimson.opacity(0.45))
        }
        .frame(minHeight: 18)
        .padding(.vertical, 0)
    }

    private var suiteImageRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.savyCrimson)
                .frame(width: 17)
            Text("Image")
                .font(Theme.savyRobotoMedium(9))
                .foregroundStyle(Color.black)
            Spacer(minLength: 8)
            Text("Add")
                .font(Theme.savyRobotoMedium(9))
                .foregroundStyle(Theme.savyCrimson)
        }
        .frame(minHeight: 18)
        .padding(.vertical, 0)
    }

    private func delegationQueueListSurface(showAgent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker("Queue View", selection: opportunityBoardViewModeBinding) {
                    ForEach(OpportunityBoardViewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 132)
                .tint(Theme.savyCrimson)

                Text("\(model.opportunityBoardRows.count) item\(model.opportunityBoardRows.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.savyTertiaryText)

                if let issue = model.opportunityBoardLoadIssue {
                    Text(issue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.savyCrimson)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    isDelegationEntryFormPresented = true
                } label: {
                    Text("Action")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(Theme.savyCrimson)

                Button {
                    model.runDelegationAgent()
                } label: {
                    Label("Run agent", systemImage: "bolt")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.savyCrimson)
                .disabled(model.isRunning)

                Button {
                    model.refreshOpportunityBoard()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(Theme.savyCrimson)
            }

            if visibleOpportunityRows.isEmpty {
                Text("No delegations queued")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 0) {
                    delegationQueueCompactHeader(showAgent: showAgent)

                    if opportunityBoardViewMode == .byApp {
                        ForEach(opportunityBoardProjection.groupsByApp()) { group in
                            Text(group.app.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(1.2)
                                .foregroundStyle(Theme.savyTertiaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 7)
                                .padding(.bottom, 3)
                            ForEach(group.rows) { row in
                                delegationQueueCompactRow(row, showAgent: showAgent)
                            }
                        }
                    } else {
                        ForEach(visibleOpportunityRows) { row in
                            delegationQueueCompactRow(row, showAgent: showAgent)
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 6)
    }

    private func delegationQueueCompactHeader(showAgent: Bool) -> some View {
        HStack(spacing: 8) {
            Text("")
                .frame(width: 18)
            Text("Delegation")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("App")
                .frame(width: 86, alignment: .leading)
            Text("Pattern")
                .frame(width: 92, alignment: .leading)
            Text("Lift")
                .frame(width: 66, alignment: .leading)
            Text("Priority")
                .frame(width: 46, alignment: .trailing)
            Text("Due")
                .frame(width: 36, alignment: .trailing)
            if showAgent {
                Text("Agent")
                    .frame(width: 112, alignment: .leading)
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Theme.savyTertiaryText)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Theme.savyCard.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private func delegationQueueCompactRow(_ row: OpportunityBoardRow, showAgent: Bool) -> some View {
        let selected = selectedOpportunityIDs.contains(row.id)
        let detail = MacDelegationDetail(row: row)

        return Button {
            selectedOpportunityIDs = [row.id]
            isDelegationEntryFormPresented = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? Theme.savyCrimson : Theme.savyTertiaryText)
                    .frame(width: 18)

                Text(detail.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                compactQueueCell(detail.app, width: 86, alignment: .leading)
                compactQueueCell(detail.patternValue, width: 92, alignment: .leading)
                compactQueueCell(detail.liftValue, width: 66, alignment: .leading)
                compactQueueCell(formatPriority(row.card.priority), width: 46, alignment: .trailing)
                compactQueueCell(row.card.windowDays.map { "\($0)d" } ?? "-", width: 36, alignment: .trailing)
                if showAgent {
                    compactQueueCell(detail.agent, width: 112, alignment: .leading)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 18)
            .contentShape(Rectangle())
            .background(selected ? Theme.savyCard.opacity(0.82) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .overlay(Rectangle().fill(Color.black.opacity(0.07)).frame(height: 1), alignment: .bottom)
    }

    private func compactQueueCell(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.savySecondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width, alignment: alignment)
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

            Menu {
                Toggle("Watchlist on", isOn: Binding(
                    get: { model.delegationAgentWatchlistEnabled },
                    set: { model.setDelegationAgentWatchlistEnabled($0) }
                ))

                Stepper(
                    "Run credits: \(model.delegationAgentPerRunCreditLimit)",
                    value: Binding(
                        get: { model.delegationAgentPerRunCreditLimit },
                        set: { model.setDelegationAgentPerRunCreditLimit($0) }
                    ),
                    in: 1...100
                )

                Stepper(
                    "Day credits: \(model.delegationAgentDailyCreditLimit)",
                    value: Binding(
                        get: { model.delegationAgentDailyCreditLimit },
                        set: { model.setDelegationAgentDailyCreditLimit($0) }
                    ),
                    in: 1...500
                )
            } label: {
                Image(systemName: "xmark.octagon")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.delegationAgentWatchlistEnabled ? Theme.macInk.opacity(0.68) : Theme.macRed)
                    .frame(width: 28, height: 24)
                    .background(Theme.macEntry.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .help("Kill Switch")

            Button {
                model.runDelegationAgent()
            } label: {
                Label("Run agent", systemImage: "play.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.macInk.opacity(0.76))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Theme.macEntry.opacity(0.32), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(model.isRunning)
            .help("Run agent")

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

    private func opportunityBoardDetail(_ row: OpportunityBoardRow) -> some View {
        let detail = MacDelegationDetail(row: row)
        let columns = [
            GridItem(.flexible(minimum: 210), spacing: 10, alignment: .topLeading),
            GridItem(.flexible(minimum: 210), spacing: 10, alignment: .topLeading)
        ]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(detail.title)
                        .font(.system(size: 15).weight(.semibold))
                        .foregroundStyle(Theme.macInk)
                        .lineLimit(1)
                    Text(row.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.macInk.opacity(0.48))
                        .lineLimit(1)
                }

                Spacer()

                statusBadge(detail.app)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                delegationDetailField("Description", detail.description, lineLimit: 3)
                delegationDetailField("Pattern", detail.pattern)
                delegationDetailField("Lift", detail.lift)
                delegationDetailField("Next agent questions", detail.nextAgentQuestions, lineLimit: 5)
                delegationDetailField("Kill Switch", detail.killSwitch, lineLimit: 3)
                delegationDetailField("Clear Sign of Success", detail.clearSignOfSuccess, lineLimit: 3)
                delegationDetailField("Resource", detail.resource, lineLimit: 2)
                delegationDetailField("Rules", detail.rules)
                delegationDetailField("Agent", detail.agent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.24))
        .overlay(Rectangle().fill(Theme.macHair).frame(height: 1), alignment: .top)
    }

    private func delegationDetailField(_ label: String, _ value: String, lineLimit: Int = 2) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(Theme.macInk.opacity(0.48))
                .lineLimit(1)

            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Theme.macInk.opacity(value == "-" ? 0.38 : 0.78))
                .textSelection(.enabled)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var selectedDetailRow: OpportunityBoardRow? {
        guard selectedOpportunityRows.count == 1 else { return nil }
        return selectedOpportunityRows.first
    }

    private var activeDelegationRow: OpportunityBoardRow? {
        selectedDetailRow ?? visibleOpportunityRows.first
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

    @ViewBuilder
    private var topBar: some View {
        if centerView == .chat {
            chatTopBar
        } else {
            workbenchTopBar
        }
    }

    private var chatTopBar: some View {
        HStack(spacing: 10) {
            chatToolbarIcon(
                isSidebarVisible ? "sidebar.left" : "sidebar.left",
                help: isSidebarVisible ? "Hide sidebar" : "Show sidebar"
            ) {
                isSidebarVisible.toggle()
            }

            Spacer()

            Picker("View", selection: centerViewBinding) {
                ForEach(WorkbenchCenterView.allCases) { view in
                    Text(view.label).tag(view)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 182)
            .help("Switch between Chat, Cockpit, and the Delegation Queue")

            Spacer()

            Menu {
                ForEach(Backend.allCases) { backend in
                    Button {
                        model.backend = backend
                    } label: {
                        if model.backend == backend {
                            Label(backend.rawValue, systemImage: "checkmark")
                        } else {
                            Text(backend.rawValue)
                        }
                    }
                }
            } label: {
                Image(systemName: "cpu")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.macInk.opacity(0.55))
            }
            .menuStyle(.borderlessButton)
            .help(model.backend.rawValue)

            backendStatusDot

            if model.backend == .codex {
                chatToolbarIcon("key.viewfinder", help: "Authorize") {
                    model.authorizeCodexAccount()
                }
            } else if model.backend == .grok, !model.hasSavedAPIKey {
                chatToolbarIcon("key.viewfinder", help: "Authorize Grok") {
                    model.authorizeGrokAccount()
                }
            } else if model.backend != .hermes {
                chatToolbarIcon(
                    model.hasSavedAPIKey ? "key.fill" : "key",
                    help: "API key"
                ) {
                    model.saveAPIKey()
                }
            }

            chatToolbarIcon(
                isInspectorVisible ? "sidebar.right" : "sidebar.right",
                help: isInspectorVisible ? "Hide inspector" : "Show inspector"
            ) {
                isInspectorVisible.toggle()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.macBg)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
        }
    }

    private var workbenchTopBar: some View {
        HStack(spacing: 8) {
            toolbarIconButton(
                isSidebarVisible ? "rectangle.leftthird.inset.filled" : "rectangle",
                help: isSidebarVisible ? "Hide left sidebar" : "Show left sidebar"
            ) {
                isSidebarVisible.toggle()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(centerViewTitle)
                    .font(Theme.recallSerif(20))
                    .foregroundStyle(Theme.macBarInk)
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
            .frame(width: 182)

            Picker("Backend", selection: $model.backend) {
                ForEach(Backend.allCases) { backend in
                    Text(backend.rawValue).tag(backend)
                }
            }
            .labelsHidden()
            .frame(width: 116)
            .tint(Theme.macRed)

            backendStatusBand
                .frame(minWidth: 68, maxWidth: 180, alignment: .leading)
                .layoutPriority(2)

            if model.backend == .codex {
                subscriptionAccountBadge(
                    label: "ChatGPT account",
                    help: "Codex uses your ChatGPT authorization, not an OpenAI API key"
                )

                toolbarIconButton("key.viewfinder", help: "Authorize Codex with ChatGPT") {
                    model.authorizeCodexAccount()
                }
            } else if model.backend == .grok, !model.hasSavedAPIKey {
                subscriptionAccountBadge(
                    label: "Grok account",
                    help: "Grok uses your xAI subscription authorization, not an API key"
                )

                toolbarIconButton("key.viewfinder", help: "Authorize Grok with xAI") {
                    model.authorizeGrokAccount()
                }
            } else if model.backend != .hermes {
                SecureField(macAPIKeyLabel(for: model.backend), text: $model.apiKey)
                    .textFieldStyle(.plain)
                    .font(Theme.recallBody(13))
                    .foregroundStyle(Theme.macEntryInk)
                    .padding(7)
                    .frame(width: 150)
                    .background(Theme.macEntry, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
                    .onSubmit { model.saveAPIKey() }

                if model.hasSavedAPIKey {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                        .help("\(macAPIKeyLabel(for: model.backend)) saved in Keychain")
                    toolbarIconButton("xmark.circle", help: "Remove saved \(macAPIKeyLabel(for: model.backend))") {
                        model.deleteAPIKey()
                    }
                } else {
                    toolbarIconButton("square.and.arrow.down", help: "Save \(macAPIKeyLabel(for: model.backend)) in Keychain") {
                        model.saveAPIKey()
                    }
                }
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
        .background(Theme.macBarBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.macRed).frame(height: 2)
        }
    }

    private var backendStatusDot: some View {
        let readiness = model.backendReadiness[model.backend] ?? .checking
        return Group {
            switch readiness {
            case .live:
                Circle().fill(Theme.statusLive).frame(width: 8, height: 8)
            case .pending:
                Circle().fill(Theme.statusPending).frame(width: 8, height: 8)
            case .failed:
                Circle().fill(Theme.macRed).frame(width: 8, height: 8)
            case .checking:
                Circle().fill(Theme.macInk.opacity(0.25)).frame(width: 8, height: 8)
            }
        }
        .help(readiness.actionNeeded ?? readiness.statusWord)
    }

    private func chatToolbarIcon(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.macInk.opacity(0.5))
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var centerViewTitle: String {
        switch centerView {
        case .chat:
            return "Delegate"
        case .cockpit:
            return "Harness Cockpit"
        case .board:
            return "Delegation Queue"
        }
    }

    /// SAVY content-status treatment: small dot + status word, heavy small
    /// caps with tracking. Words come from Docs/design-vocabulary.md:
    /// "live", "pending", "failed (message)", "Checking gateway…".
    @ViewBuilder
    private var backendStatusBand: some View {
        let readiness = model.backendReadiness[model.backend] ?? .checking
        HStack(spacing: 5) {
            switch readiness {
            case .live:
                Circle().fill(Theme.statusLive).frame(width: 7, height: 7)
            case .pending:
                Circle().fill(Theme.statusPending).frame(width: 7, height: 7)
            case .failed, .checking:
                EmptyView()
            }
            Text(readiness.statusWord.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.5)
                .foregroundStyle(statusWordColor(for: readiness))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .help(readiness.actionNeeded ?? readiness.statusWord)
        .accessibilityLabel("\(model.backend.rawValue) status: \(readiness.statusWord)")
    }

    private func subscriptionAccountBadge(label: String, help: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Theme.macBarInk.opacity(0.82))
        .padding(.horizontal, 10)
        .frame(width: 150, height: 30)
        .background(Theme.macEntry.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
        .help(help)
    }

    private func statusWordColor(for readiness: BackendReadiness) -> Color {
        switch readiness {
        case .live:
            return Theme.statusLive
        case .pending:
            return Theme.statusPending
        case .failed:
            return Theme.macRed
        case .checking:
            return Theme.macFaint
        }
    }

    private func macAPIKeyLabel(for backend: Backend) -> String {
        switch backend {
        case .codex: return "ChatGPT authorization"
        case .grok: return "xAI API key"
        case .claude: return "Claude API key"
        case .hermes: return ""
        }
    }

    private func toolbarIconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13).weight(.semibold))
                .foregroundStyle(Theme.macBarInk.opacity(0.78))
                .frame(width: 28, height: 24)
                .background(Theme.macEntry.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
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
            if !HarnessTranscriptCopy.assistantAnswer(from: detail).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                copyTranscriptButton(
                    label: "Copy answer",
                    help: "Copy the entire Harness answer to the clipboard",
                    text: HarnessTranscriptCopy.assistantAnswer(from: detail)
                )
            }
            if detail.messages.count > 1 {
                copyTranscriptButton(
                    label: "Copy all",
                    help: "Copy the full prompt and answer transcript",
                    text: HarnessTranscriptCopy.fullTranscript(from: detail)
                )
            }
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

    private func copyTranscriptButton(label: String, help: String, text: String) -> some View {
        Button {
            HarnessClipboard.copy(text)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                Text(label)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.macInk.opacity(0.72))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.macEntry.opacity(0.35), in: Capsule())
            .overlay(Capsule().stroke(Theme.macHair, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func chatTurnBubble(_ turn: ConversationTurn) -> some View {
        let role = turn.role
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(role == .user ? "YOU" : "ANSWER")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.macInk.opacity(0.48))
                Spacer()
                copyTranscriptButton(
                    label: "Copy",
                    help: role == .assistant
                        ? "Copy the entire answer, including all chapters"
                        : "Copy the entire message",
                    text: turn.text
                )
            }
            if role == .assistant {
                HarnessMarkdownText(
                    text: turn.text,
                    textColor: Theme.macInk,
                    bodyFont: .body,
                    h1Font: .system(.title2, design: .serif).weight(.semibold),
                    h2Font: .headline
                )
                .textSelection(.enabled)
            } else {
                Text(turn.text)
                    .font(.body)
                    .foregroundStyle(Theme.macInk)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(role == .user ? 0.45 : 0.25), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.macHair, lineWidth: 1))
    }

    private func messageBubble(_ message: HarnessMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(message.role == .user ? "YOU" : "ANSWER")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.macInk.opacity(0.48))
                Spacer()
                copyTranscriptButton(
                    label: "Copy",
                    help: message.role == .assistant
                        ? "Copy the entire answer, including all chapters"
                        : "Copy the entire message",
                    text: message.text
                )
            }
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
        VStack(alignment: .leading, spacing: 10) {
            if !model.composerAttachments.isEmpty {
                composerAttachmentChips
            }

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
                    .foregroundStyle(model.canSendComposer ? Theme.macInk : Theme.macInk.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!model.canSendComposer)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(Rectangle().fill(Theme.macHair).frame(height: 1), alignment: .top)
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
                        Button {
                            model.removeComposerAttachment(attachment)
                        } label: {
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

    private func composerLinkSheet(
        title: String,
        placeholder: String,
        text: Binding<String>,
        onAdd: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.macInk)
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .padding(12)
                .background(Theme.macEntry.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.macHair, lineWidth: 1))
            HStack {
                Spacer()
                Button("Cancel") {
                    text.wrappedValue = ""
                    if showingLinkSheet { showingLinkSheet = false }
                    if showingGitHubSheet { showingGitHubSheet = false }
                }
                .keyboardShortcut(.cancelAction)
                Button("Add") { onAdd() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.macBg)
    }

    private var capabilityInsertMenu: some View {
        Menu {
            Button {
                model.newSession()
            } label: {
                Label("New Session", systemImage: "plus.bubble")
            }

            Divider()

            Button {
                model.chooseComposerPhotos()
            } label: {
                Label("Photo", systemImage: "photo")
            }

            Button {
                model.chooseComposerFiles()
            } label: {
                Label("File", systemImage: "doc.badge.plus")
            }

            Button {
                linkInput = ""
                showingLinkSheet = true
            } label: {
                Label("Link", systemImage: "link")
            }

            Button {
                githubRepoInput = ""
                showingGitHubSheet = true
            } label: {
                Label("GitHub Repo", systemImage: "chevron.left.forwardslash.chevron.right")
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
        .help("Attach photo, file, link, or skill")
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

private struct MacFloppyDiskIcon: View {
    let size: CGFloat

    var body: some View {
        MacFloppyDiskShape()
            .stroke(Color.black, style: StrokeStyle(lineWidth: max(2, size * 0.1), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

private struct MacFloppyDiskShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2
        let oy = rect.midY - s / 2

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x / 24 * s, y: oy + y / 24 * s)
        }

        var path = Path()
        path.move(to: pt(3, 2))
        path.addLine(to: pt(16, 2))
        path.addLine(to: pt(22, 8))
        path.addLine(to: pt(22, 21))
        path.addQuadCurve(to: pt(21, 22), control: pt(22, 22))
        path.addLine(to: pt(3, 22))
        path.addQuadCurve(to: pt(2, 21), control: pt(2, 22))
        path.addLine(to: pt(2, 3))
        path.addQuadCurve(to: pt(3, 2), control: pt(2, 2))
        path.closeSubpath()

        path.move(to: pt(8, 2))
        path.addLine(to: pt(8, 9))
        path.addLine(to: pt(15, 9))
        path.addLine(to: pt(15, 2))

        path.move(to: pt(6, 22))
        path.addLine(to: pt(6, 15))
        path.addQuadCurve(to: pt(7, 14), control: pt(6, 14))
        path.addLine(to: pt(17, 14))
        path.addQuadCurve(to: pt(18, 15), control: pt(18, 14))
        path.addLine(to: pt(18, 22))

        return path
    }
}

private struct MacDelegationDetail {
    let title: String
    let app: String
    let description: String
    let pattern: String
    let patternValue: String
    let lift: String
    let liftValue: String
    let nextAgentQuestions: String
    let killSwitch: String
    let clearSignOfSuccess: String
    let resource: String
    let rules: String
    let agent: String
    let priorityValue: String
    let effortValue: String
    let energyValue: String
    let dueValue: String
    let startDeferValue: String
    let nudgeValue: String
    let endValue: String
    let tagsValue: String
    let notesValue: String
    let locationValue: String

    static let empty = MacDelegationDetail()

    private init() {
        title = "-"
        app = "-"
        description = "-"
        pattern = "-"
        patternValue = "None"
        lift = "-"
        liftValue = "None"
        nextAgentQuestions = "-"
        killSwitch = "-"
        clearSignOfSuccess = "-"
        resource = "-"
        rules = "-"
        agent = "-"
        priorityValue = "None"
        effortValue = "-"
        energyValue = "-"
        dueValue = "-"
        startDeferValue = "-"
        nudgeValue = "-"
        endValue = "-"
        tagsValue = "-"
        notesValue = "-"
        locationValue = "-"
    }

    init(row: OpportunityBoardRow) {
        let card = row.card
        title = card.envelope.title?.nilIfBlank ?? row.id
        app = card.app?.rawValue ?? card.rawApp?.nilIfBlank ?? "-"
        description = card.envelope.description?.nilIfBlank ?? "-"
        pattern = Self.section("Pattern", in: card.body)
        patternValue = Self.choiceValue(pattern, choices: MacSuiteFormCopy.patternChoices, fallback: "None")
        lift = Self.section("Lift", in: card.body)
        liftValue = Self.choiceValue(lift, choices: MacSuiteFormCopy.liftChoices, fallback: "None")
        nextAgentQuestions = Self.section("Next agent questions", in: card.body)
        killSwitch = Self.section("Kill Switch", in: card.body)
        clearSignOfSuccess = Self.section("Clear Sign of Success", in: card.body)
        resource = row.canonicalResource.nilIfBlank ?? "-"
        rules = card.rulesHit.isEmpty ? "-" : card.rulesHit.joined(separator: ", ")
        agent = card.scoutID?.nilIfBlank ?? "-"
        priorityValue = Self.choiceValue(Self.section("Priority", in: card.body), choices: MacSuiteFormCopy.priorityChoices, fallback: "None")
        effortValue = card.rawEffort?.nilIfBlank ?? Self.section("Effort", in: card.body).nilIfDash ?? "-"
        energyValue = Self.section("Energy", in: card.body).nilIfDash ?? "-"
        dueValue = card.windowDays.map { "\($0)d" } ?? "-"
        startDeferValue = Self.section("Start / defer", in: card.body).nilIfDash ?? "-"
        nudgeValue = Self.section("Nudge", in: card.body).nilIfDash ?? "-"
        endValue = Self.section("End", in: card.body).nilIfDash ?? "-"
        tagsValue = card.envelope.tags.isEmpty ? "-" : card.envelope.tags.joined(separator: ", ")
        notesValue = Self.section("Notes", in: card.body).nilIfDash ?? "-"
        locationValue = Self.section("Location", in: card.body).nilIfDash ?? "-"
    }

    private static func section(_ name: String, in body: String) -> String {
        let wanted = "\(name):".lowercased()
        let lines = body.components(separatedBy: .newlines)
        var capture = false
        var captured: [String] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if capture {
                if isSectionHeader(line) {
                    break
                }
                if line.isEmpty {
                    continue
                }
                captured.append(cleanSectionLine(line))
            } else if line.lowercased() == wanted {
                capture = true
            }
        }

        let value = captured.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "-" : value
    }

    private static func isSectionHeader(_ line: String) -> Bool {
        guard line.hasSuffix(":") else { return false }
        guard !line.hasPrefix("-") else { return false }
        return line.count <= 64
    }

    private static func cleanSectionLine(_ line: String) -> String {
        let bulletPrefixes = ["- ", "* "]
        for prefix in bulletPrefixes where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return line
    }

    private static func choiceValue(_ raw: String, choices: [String], fallback: String) -> String {
        guard raw != "-" else { return fallback }
        let normalizedRaw = normalize(raw)
        return choices.first { normalize($0) == normalizedRaw } ?? fallback
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nilIfDash: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "-" ? nil : trimmed
    }
}

private enum MacSuiteEntryKind: String, CaseIterable, Identifiable {
    case reminder
    case action
    case event

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reminder: return "Reminder"
        case .action: return "Action"
        case .event: return "Event"
        }
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
                    .foregroundStyle(Theme.macRed.opacity(0.45))
                    .offset(x: offset.width, y: offset.height)
            }

            titleText
                .foregroundStyle(Theme.macTan)
        }
        .accessibilityLabel(text)
    }

    private var titleText: some View {
        Text(text)
            .font(Theme.recallSerif(26))
            .tracking(0.5)
    }
}
#endif
