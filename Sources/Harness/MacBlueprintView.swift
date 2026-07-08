#if os(macOS)
import SwiftUI

/// Shell for the v6-mockup cockpit screen (WO-F). Five regions per
/// docs/design-brief-ios-workbench.md: Step Rail, Sources pool, Delegate
/// composer, Organize, Ledger strip. This work order only stands up the
/// switcher case and the region scaffold — the gate-bound rail (WO-G), the
/// v6 ink (WO-H), and the carousel (WO-I) land in later work orders.
struct MacBlueprintView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                blueprintSection(title: "Step Rail", icon: "list.number") {
                    placeholderNote("Wires to PatternGateChecker in WO-G.")
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Blueprint")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(Theme.macInk)

            Text("Shell only — the Adam Pattern rail, sources pool, composer, organize panel, and ledger arrive in later work orders.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.macInk.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.macEntry.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.macHair, lineWidth: 1))
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
#endif
