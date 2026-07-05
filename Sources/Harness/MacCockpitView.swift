#if os(macOS)
import SwiftUI

struct MacCockpitView: View {
    let onPrimeAgent: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                systemTree
                wordsAndIcons
                appMap
                exampleRoute
                agentFleet
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.macBg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Harness Cockpit")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(Theme.macInk)
                statusPill("begins here", "command")
                statusPill("delegation command", "person.3.sequence")
            }

            Text("Harness owns brainstorming, orchestration, delegation, evidence, provenance, the review queue, and the fleet ledger. The mobile apps help Adam place field inspiration into the Adam Pattern when he is away from the workstation.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.macInk.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
    }

    private var systemTree: some View {
        cockpitSection(title: "System Tree", icon: "point.3.connected.trianglepath.dotted") {
            HStack(alignment: .top, spacing: 18) {
                treeColumn(
                    title: "Harness",
                    subtitle: "cockpit",
                    icon: "command",
                    nodes: [
                        "brainstorm",
                        "orchestrate delegation",
                        "assign agents",
                        "preserve evidence",
                        "hold review queue",
                        "write fleet ledger"
                    ]
                )

                treeColumn(
                    title: "Adam Pattern",
                    subtitle: "8-step architecture",
                    icon: "list.number",
                    nodes: [
                        "Context",
                        "Circle",
                        "Close the Gap",
                        "Choose Success",
                        "Code the Pattern",
                        "Create Kill Switch",
                        "Clear Sign of Success",
                        "Compound"
                    ]
                )

                treeColumn(
                    title: "Understood Suite",
                    subtitle: "away from workstation",
                    icon: "square.grid.2x2",
                    nodes: [
                        "News Calm",
                        "Notorious Recall",
                        "Understood",
                        "SAVY"
                    ]
                )
            }
        }
    }

    private var appMap: some View {
        cockpitSection(title: "Understood Suite Map", icon: "square.grid.2x2") {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        mapHeader("App", width: 142)
                        mapHeader("What Belongs There", width: 282)
                        mapHeader("Adam Pattern", width: 238)
                        mapHeader("Agent Job", width: 220)
                    }

                    ForEach(CockpitApp.defaults) { app in
                        GridRow {
                            mapCell(app.name, width: 142, weight: .semibold, tint: app.tint)
                            mapCell(app.belongsThere, width: 282)
                            mapCell(app.adamPattern, width: 238)
                            mapCell(app.agentJob, width: 220)
                        }
                    }
                }
                .background(Theme.macEntry.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
            }
        }
    }

    private var wordsAndIcons: some View {
        cockpitSection(title: "Words & Icons", icon: "text.badge.checkmark") {
            VStack(alignment: .leading, spacing: 12) {
                iconGroup("Pattern", items: CockpitIconItem.pattern)
                iconGroup("Choose", items: CockpitIconItem.choose)
                iconGroup("Schedule", items: CockpitIconItem.schedule)
                iconGroup("Organize", items: CockpitIconItem.organize)
                iconGroup("Details", items: CockpitIconItem.details)
                iconGroup("Place / People", items: CockpitIconItem.placePeople)
            }
            .padding(12)
            .background(Theme.macEntry.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
        }
    }

    private var exampleRoute: some View {
        cockpitSection(title: "3D Printing Example", icon: "arrow.triangle.branch") {
            HStack(alignment: .top, spacing: 10) {
                ForEach(CockpitRouteStep.threeDPrinting) { step in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: step.icon)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(step.tint)
                            Text(step.app)
                                .font(.system(size: 12).weight(.bold))
                                .foregroundStyle(Theme.macInk)
                        }
                        Text(step.signal)
                            .font(.system(size: 13).weight(.semibold))
                            .foregroundStyle(Theme.macInk.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(step.action)
                            .font(.caption)
                            .foregroundStyle(Theme.macInk.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(width: 206, alignment: .topLeading)
                    .background(Theme.macEntry.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
                }
            }
        }
    }

    private var agentFleet: some View {
        cockpitSection(title: "12-Agent Fleet", icon: "person.3.sequence") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    agentHeader("Agent", width: 228)
                    agentHeader("App", width: 134)
                    agentHeader("Adam Pattern", width: 190)
                    agentHeader("Mission", width: 346)
                    agentHeader("", width: 42)
                }
                .background(Theme.macEntry.opacity(0.2))

                ForEach(CockpitAgent.defaults) { agent in
                    HStack(spacing: 0) {
                        agentCell(agent.name, width: 228, weight: .semibold)
                        agentCell(agent.app, width: 134, tint: agent.tint)
                        agentCell(agent.adamPattern, width: 190)
                        agentCell(agent.mission, width: 346)
                        Button {
                            onPrimeAgent(agent.prompt)
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 13).weight(.semibold))
                                .foregroundStyle(Theme.macInk.opacity(0.7))
                                .frame(width: 42, height: 34)
                        }
                        .buttonStyle(.plain)
                        .help("Prime composer")
                    }
                    .background(Theme.macEntry.opacity(0.08))
                    .overlay(Rectangle().fill(Theme.macHair).frame(height: 1), alignment: .bottom)
                }
            }
            .background(Theme.macEntry.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
        }
    }

    private func cockpitSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.macRed.opacity(0.9))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13).weight(.bold))
                    .foregroundStyle(Theme.macInk.opacity(0.78))
                Spacer()
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func treeColumn(title: String, subtitle: String, icon: String, nodes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            treeColumnHeader(title: title, subtitle: subtitle, icon: icon)
            ForEach(nodes, id: \.self) { node in
                Text("  \(node)")
                    .font(.caption)
                    .foregroundStyle(Theme.macInk.opacity(0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(minWidth: 188, maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(Theme.macEntry.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
    }

    private func treeColumnHeader(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.macRed.opacity(0.9))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12).weight(.semibold))
                    .foregroundStyle(Theme.macInk)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.macInk.opacity(0.46))
            }
        }
    }

    private func statusPill(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.macInk.opacity(0.72))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.macEntry.opacity(0.34), in: Capsule())
        .overlay(Capsule().stroke(Theme.macHair, lineWidth: 1))
    }

    private func mapHeader(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Theme.macInk.opacity(0.54))
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(width: width, alignment: .leading)
            .overlay(Rectangle().fill(Theme.macHair).frame(width: 1), alignment: .trailing)
    }

    private func mapCell(
        _ text: String,
        width: CGFloat,
        weight: Font.Weight = .regular,
        tint: Color? = nil
    ) -> some View {
        Text(text)
            .font(.system(size: 12).weight(weight))
            .foregroundStyle(tint ?? Theme.macInk.opacity(0.74))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(width: width, alignment: .leading)
            .frame(minHeight: 42)
            .overlay(Rectangle().fill(Theme.macHair).frame(width: 1), alignment: .trailing)
            .overlay(Rectangle().fill(Theme.macHair).frame(height: 1), alignment: .bottom)
    }

    private func iconGroup(_ title: String, items: [CockpitIconItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.macInk.opacity(0.58))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.icon)
                            .font(.system(size: 14).weight(.semibold))
                            .foregroundStyle(Theme.macRed)
                            .frame(width: 18)
                        Text(item.label)
                            .font(.system(size: 12).weight(.semibold))
                            .foregroundStyle(Theme.macInk.opacity(0.82))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Theme.macEntry.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.macHair.opacity(0.7), lineWidth: 1))
                }
            }
        }
    }

    private func agentHeader(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Theme.macInk.opacity(0.54))
            .padding(.horizontal, 8)
            .frame(width: width, height: 32, alignment: .leading)
            .overlay(Rectangle().fill(Theme.macHair).frame(width: 1), alignment: .trailing)
    }

    private func agentCell(
        _ text: String,
        width: CGFloat,
        weight: Font.Weight = .regular,
        tint: Color? = nil
    ) -> some View {
        Text(text)
            .font(.system(size: 11).weight(weight))
            .foregroundStyle(tint ?? Theme.macInk.opacity(0.74))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .frame(width: width, alignment: .leading)
            .frame(minHeight: 36)
            .overlay(Rectangle().fill(Theme.macHair).frame(width: 1), alignment: .trailing)
    }
}

private struct CockpitApp: Identifiable {
    let id: String
    let name: String
    let icon: String
    let belongsThere: String
    let adamPattern: String
    let agentJob: String
    let tint: Color

    static let defaults: [CockpitApp] = [
        CockpitApp(
            id: "harness",
            name: "Harness",
            icon: "command",
            belongsThere: "brainstorming, orchestration, delegation",
            adamPattern: "Any Adam Pattern step",
            agentJob: "delegate, review, ledger",
            tint: Theme.macInk
        ),
        CockpitApp(
            id: "news-calm",
            name: "News Calm",
            icon: "newspaper",
            belongsThere: "mild curiosity, unfamiliar domains",
            adamPattern: "Context / Circle",
            agentJob: "watch, expose, collect sources",
            tint: Color(hex: 0x7FA7D8)
        ),
        CockpitApp(
            id: "notorious",
            name: "Notorious Recall",
            icon: "clock.arrow.circlepath",
            belongsThere: "crossed-threshold reminders and delegations",
            adamPattern: "Circle / Close the Gap / Choose Success",
            agentJob: "queue, clarify, define done",
            tint: Theme.macRed.opacity(0.9)
        ),
        CockpitApp(
            id: "understood",
            name: "Understood",
            icon: "square.stack.3d.up",
            belongsThere: "understood enough to take action",
            adamPattern: "Choose Success / Code the Pattern / Create Kill Switch",
            agentJob: "synthesize, price, specify first action",
            tint: Color(hex: 0x78C6A3)
        ),
        CockpitApp(
            id: "savy",
            name: "SAVY",
            icon: "sparkles",
            belongsThere: "mature processes with leverage and payoff",
            adamPattern: "Clear Sign of Success / Compound",
            agentJob: "build, market, optimize",
            tint: Color(hex: 0xE2B15A)
        )
    ]
}

private struct CockpitIconItem: Identifiable {
    let id: String
    let label: String
    let icon: String

    init(_ label: String, _ icon: String) {
        self.id = "\(label)-\(icon)"
        self.label = label
        self.icon = icon
    }

    static let pattern: [CockpitIconItem] = [
        CockpitIconItem("None", "checkmark"),
        CockpitIconItem("Context", "list.number"),
        CockpitIconItem("Circle", "eye"),
        CockpitIconItem("Close the Gap", "arrow.left.and.right"),
        CockpitIconItem("Choose Success", "target"),
        CockpitIconItem("Code the Pattern", "hammer"),
        CockpitIconItem("Create Kill Switch", "xmark.octagon"),
        CockpitIconItem("Clear Sign of Success", "checkmark.seal"),
        CockpitIconItem("Compound", "arrow.triangle.2.circlepath")
    ]

    static let choose: [CockpitIconItem] = [
        CockpitIconItem("Priority", "exclamationmark.3"),
        CockpitIconItem("Effort", "timer"),
        CockpitIconItem("Energy", "bolt")
    ]

    static let schedule: [CockpitIconItem] = [
        CockpitIconItem("Due", "calendar"),
        CockpitIconItem("Start / defer", "calendar.badge.clock"),
        CockpitIconItem("Repeat", "arrow.2.squarepath"),
        CockpitIconItem("Nudge", "bell"),
        CockpitIconItem("End", "clock.badge.checkmark")
    ]

    static let organize: [CockpitIconItem] = [
        CockpitIconItem("Lift", "sparkles"),
        CockpitIconItem("Flag", "flag"),
        CockpitIconItem("Tags", "tag"),
        CockpitIconItem("Add a recent tag", "clock.arrow.circlepath")
    ]

    static let details: [CockpitIconItem] = [
        CockpitIconItem("Notes", "note.text"),
        CockpitIconItem("Link", "link"),
        CockpitIconItem("Image", "photo")
    ]

    static let placePeople: [CockpitIconItem] = [
        CockpitIconItem("Location", "location"),
        CockpitIconItem("Waiting on / delegate to", "person")
    ]
}

private struct CockpitRouteStep: Identifiable {
    let id: String
    let app: String
    let icon: String
    let signal: String
    let action: String
    let tint: Color

    static let threeDPrinting: [CockpitRouteStep] = [
        CockpitRouteStep(
            id: "news-calm",
            app: "News Calm",
            icon: "newspaper",
            signal: "3D printing is interesting, but unfamiliar.",
            action: "Expose sources, videos, industries, and use cases.",
            tint: Color(hex: 0x7FA7D8)
        ),
        CockpitRouteStep(
            id: "notorious",
            app: "Notorious Recall",
            icon: "clock.arrow.circlepath",
            signal: "AI coding may make entry easier.",
            action: "Remember it, form questions, queue agent research.",
            tint: Theme.macRed.opacity(0.9)
        ),
        CockpitRouteStep(
            id: "understood",
            app: "Understood",
            icon: "square.stack.3d.up",
            signal: "Cost, delivery, space, and use case are concrete enough to act.",
            action: "Price, space, materials, setup, first action.",
            tint: Color(hex: 0x78C6A3)
        ),
        CockpitRouteStep(
            id: "savy",
            app: "SAVY",
            icon: "sparkles",
            signal: "Adam prints an iPhone accessory he uses.",
            action: "Market, productize, test demand, compound process.",
            tint: Color(hex: 0xE2B15A)
        )
    ]
}

private struct CockpitAgent: Identifiable {
    let id: Int
    let name: String
    let app: String
    let adamPattern: String
    let mission: String
    let prompt: String
    let tint: Color

    static let defaults: [CockpitAgent] = [
        agent(1, "Harness Cockpit Operator", "Harness", "Any step", "Route raw ideas before research starts."),
        agent(2, "News Calm Scout", "News Calm", "Context / Circle", "Expose unfamiliar domains calmly."),
        agent(3, "Notorious Threshold Scout", "Notorious Recall", "Circle / Close the Gap", "Decide whether curiosity is worth remembering."),
        agent(4, "Research Calibrator", "Notorious Recall", "Close the Gap / Choose Success", "Define what great research must include."),
        agent(5, "Understood Synthesizer", "Understood", "Choose Success", "Turn research into an Understood action shape."),
        agent(6, "Action Planner", "Understood", "Code the Pattern", "Convert the action shape into a small real-world path."),
        agent(7, "Kill-Switch Designer", "Understood", "Create Kill Switch", "Define stop conditions before project energy rises."),
        agent(8, "SAVY Fit Validator", "SAVY", "Create Kill Switch / Clear Sign of Success", "Test whether this is Adam-shaped at this point."),
        agent(9, "SAVY Market Builder", "SAVY", "Clear Sign of Success / Compound", "Build market knowledge around a mature process."),
        agent(10, "Process Operator", "SAVY", "Compound", "Turn one win into reusable process."),
        agent(11, "Data Steward", "Harness", "Evidence / Provenance", "Classify existing app and Notion data."),
        agent(12, "Fleet Ledger Operator", "Harness", "Review queue / fleet ledger", "Normalize agent outputs into Harness review queue.")
    ]

    private static func agent(_ id: Int, _ name: String, _ app: String, _ adamPattern: String, _ mission: String) -> CockpitAgent {
        CockpitAgent(
            id: id,
            name: name,
            app: app,
            adamPattern: adamPattern,
            mission: mission,
            prompt: """
            Deploy \(name).

            cockpit_owner: Harness
            app: \(app)
            adam_pattern_step: \(adamPattern)
            target: What do I want?
            trigger:
            pursue_signal:
            kill_switch:
            source_tier:
            next_decision_for_adam:

            Mission: \(mission)
            Return the right shape: node tree for architecture, table for comparisons, matrix for two-axis decisions, short prose for meaning.
            """,
            tint: tint(for: app)
        )
    }

    private static func tint(for app: String) -> Color {
        switch app {
        case "News Calm":
            return Color(hex: 0x7FA7D8)
        case "Notorious Recall":
            return Theme.macRed.opacity(0.9)
        case "Understood":
            return Color(hex: 0x78C6A3)
        case "SAVY":
            return Color(hex: 0xE2B15A)
        default:
            return Theme.macInk
        }
    }
}
#endif
