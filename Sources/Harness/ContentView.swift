import SwiftUI
import OntologyKit

struct ContentView: View {
    private let ontology = OntologyLoader.load()
    @State private var selection: Section? = .chat

    enum Section: String, CaseIterable, Identifiable {
        case chat    = "New chat"        // technical: New Session
        case beliefs = "My Rules"        // technical: Connections
        case axioms  = "Cause & Effect"  // technical: Axioms
        case pattern = "The Pattern"     // technical: Adam Pattern
        var id: String { rawValue }
        var technical: String {
            switch self {
            case .chat:    return "New Session (Claude, constrained by your graph)"
            case .beliefs: return "Connections (adam-beliefs.ttl)"
            case .axioms:  return "Axioms (adam-axioms.ttl)"
            case .pattern: return "Adam Pattern (adam_pattern.ttl)"
            }
        }
        var icon: String {
            switch self {
            case .chat:    return "plus.bubble"
            case .beliefs: return "checkmark.seal"
            case .axioms:  return "arrow.right.circle"
            case .pattern: return "list.number"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { s in
                Label(s.rawValue, systemImage: s.icon)
                    .help(s.technical)          // plain label, technical term on hover
                    .listRowBackground(Theme.navy)
                    .foregroundStyle(Theme.tan)
                    .tag(s)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.navy)
            .tint(Theme.red)
            .navigationTitle("Harness")
        } detail: {
            switch selection {
            case .chat:    ChatView(ontology: ontology)
            case .beliefs: beliefsView
            case .axioms:  axiomsView
            case .pattern: patternView
            case .none:    ChatView(ontology: ontology)
            }
        }
    }

    private var beliefsView: some View {
        List(ontology.connections) { c in
            VStack(alignment: .leading, spacing: 4) {
                Text(c.label).font(.body)
                HStack(spacing: 8) {
                    Text(c.id).font(.caption).foregroundStyle(.secondary)
                    Text(c.connectionType.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("My Rules")
    }

    private var axiomsView: some View {
        List(ontology.axioms) { a in
            VStack(alignment: .leading, spacing: 4) {
                Text("\(a.antecedent)  →  \(a.consequent)").font(.body)
                HStack(spacing: 8) {
                    Text(a.id).font(.caption).foregroundStyle(.secondary)
                    Text("confidence \(a.confidence, format: .number)").font(.caption2)
                    Text("evidence \(a.evidenceCount)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("Cause & Effect")
    }

    private var patternView: some View {
        List(ontology.pattern) { step in
            HStack(alignment: .top, spacing: 12) {
                Text("\(step.id)").font(.title3.monospacedDigit().bold())
                    .frame(width: 28)
                    .foregroundStyle(step.zone == .observational ? .blue : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).font(.headline)
                    Text(step.description).font(.subheadline).foregroundStyle(.secondary)
                    Text(step.zone == .observational ? "Watch first" : "Then execute")
                        .font(.caption2)
                        .help(step.zone.rawValue)
                }
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("The Pattern")
    }
}

#Preview {
    ContentView()
}
