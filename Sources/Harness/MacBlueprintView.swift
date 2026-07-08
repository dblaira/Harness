#if os(macOS)
import SwiftUI
import OntologyKit

/// Shell for the v6-mockup cockpit screen (WO-F/WO-G). Five regions per
/// docs/design-brief-ios-workbench.md: Step Rail, Sources pool, Delegate
/// composer, Organize, Ledger strip. The Step Rail is now live and bound
/// to PatternGateChecker (fail-closed). The v6 ink (WO-H) and the
/// carousel (WO-I) land in later work orders.
struct MacBlueprintView: View {
    @ObservedObject var model: MacWorkbenchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                blueprintSection(title: "Step Rail", icon: "list.number") {
                    stepRail
                }
                blueprintSection(title: "Sources", icon: "tray") {
                    placeholderNote("Unlabeled capture pool lands in WO-N.")
                }
                blueprintSection(title: "Delegate", icon: "text.cursor") {
                    placeholderNote("Three-field composer lands in WO-J.")
                }
                blueprintSection(title: "Organize", icon: "square.stack.3d.up") {
                    placeholderNote("Slide Deck / Mind Map / Audio land in WO-O.")
                }
                blueprintSection(title: "Ledger", icon: "chart.bar") {
                    placeholderNote("Fleet ledger lands in WO-M.")
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.macBg)
        .task { await model.refreshPatternGate() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blueprint")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(Theme.macInk)

            Text("Shell only — the sources pool, composer, organize panel, and ledger arrive in later work orders.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.macInk.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
    }

    // MARK: - Step Rail (WO-G)

    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            gateStatusLine

            HStack(alignment: .top, spacing: 8) {
                ForEach(observationalSteps) { step in
                    PatternObservationalCell(
                        step: step,
                        rating: model.patternGateState.ratings[step.id],
                        onSubmit: { rating, note in
                            model.submitPatternRating(step: step.id, rating: rating, evidenceNote: note)
                        }
                    )
                }
            }

            HStack(alignment: .top, spacing: 8) {
                ForEach(executionSteps) { step in
                    PatternExecutionCell(step: step, unlocked: model.patternGateState.executionUnlocked)
                }
            }
        }
    }

    private var observationalSteps: [PatternStep] {
        model.ontology.pattern.filter { $0.zone == .observational }
    }

    private var executionSteps: [PatternStep] {
        model.ontology.pattern.filter { $0.zone == .execution }
    }

    private var gateStatusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.patternGateState.executionUnlocked ? Theme.savyGreen : Theme.macRed.opacity(0.7))
                .frame(width: 7, height: 7)
            Text(model.patternGateState.executionUnlocked ? "unlocked" : "locked")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Theme.macInk.opacity(0.7))
            Text("· \(model.patternGateState.source.rawValue)")
                .font(.caption2)
                .foregroundStyle(Theme.macInk.opacity(0.46))
            Spacer()
            Button {
                Task { await model.refreshPatternGate() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.macInk.opacity(0.5))
            .help(model.patternGateState.detail)
        }
    }

    private func blueprintSection<Content: View>(
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
    }

    private func placeholderNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.macInk.opacity(0.46))
    }
}

/// Cells 1-4: an isolated rating number once recorded (ratings are
/// write-once — PatternEvidenceStore.record throws on a second rating
/// for the same step), otherwise the entry control.
private struct PatternObservationalCell: View {
    let step: PatternStep
    let rating: Int?
    let onSubmit: (Int, String) -> Void

    @State private var draftRating: Double = 7
    @State private var evidenceNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cellHeader

            if let rating {
                Text("\(rating)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.macRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Stepper("Rating: \(Int(draftRating))", value: $draftRating, in: 1...10, step: 1)
                        .font(.caption)
                    TextField("Evidence note", text: $evidenceNote)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Rate") {
                        onSubmit(Int(draftRating), evidenceNote)
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(evidenceNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(Theme.macEntry.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.macHair, lineWidth: 1))
    }

    private var cellHeader: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text("\(step.id)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.macRed)
                Text(step.title)
                    .font(.system(size: 12).weight(.semibold))
                    .foregroundStyle(Theme.macInk.opacity(0.85))
            }
            Text(step.description)
                .font(.caption2)
                .foregroundStyle(Theme.macInk.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Cells 5-8: locked at 45% ink until PatternGateChecker says
/// executionUnlocked — never derived any other way.
private struct PatternExecutionCell: View {
    let step: PatternStep
    let unlocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("\(step.id)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
                    .font(.caption2)
            }
            Text(step.title)
                .font(.system(size: 12).weight(.semibold))
            Text(step.description)
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.macInk.opacity(unlocked ? 0.88 : 0.45))
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(Theme.macEntry.opacity(unlocked ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.macHair, lineWidth: 1))
    }
}
#endif
