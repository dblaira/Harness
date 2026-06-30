#if os(macOS)
import Foundation
import OntologyKit

@MainActor
final class MacWorkbenchModel: ObservableObject {
    @Published var ontology: Ontology = .empty
    @Published var runs: [HarnessRun] = []
    @Published var selectedDetail: HarnessRunDetail?
    @Published var draft = ""
    @Published var backend: Backend = .codex
    @Published var apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    @Published var isRunning = false
    @Published var status = "Ledger ready"
    @Published var searchText = ""
    let toolGroups = WorkbenchToolGroup.defaults

    private let ledger: RunLedgerStore
    private let service: HarnessRunService

    init() {
        let store: RunLedgerStore
        do {
            store = try RunLedgerStore.applicationDefault()
        } catch {
            store = try! RunLedgerStore.inMemory()
        }
        self.ledger = store
        self.service = HarnessRunService(ledger: store)
        Task { await refreshRuns() }
    }

    func updateOntology(_ ontology: Ontology) {
        self.ontology = ontology
    }

    func refreshRuns() async {
        do {
            runs = try await ledger.listRuns()
            if selectedDetail == nil, let first = runs.first {
                selectedDetail = try await ledger.runDetail(id: first.id)
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func searchRuns() async {
        do {
            runs = try await ledger.searchRuns(searchText)
        } catch {
            status = error.localizedDescription
        }
    }

    func selectRun(_ run: HarnessRun) async {
        do {
            selectedDetail = try await ledger.runDetail(id: run.id)
        } catch {
            status = error.localizedDescription
        }
    }

    func newSession() {
        selectedDetail = nil
        draft = ""
        searchText = ""
        status = "New session"
    }

    func markCandidate(_ candidate: MemoryCandidate, as status: CandidateState) {
        guard [.suggested, .candidate, .rejected].contains(status) else {
            self.status = "Candidate review cannot accept graph authority."
            return
        }
        let selectedRunId = selectedDetail?.run.id
        let ledger = ledger

        Task {
            do {
                try await ledger.updateCandidateStatus(
                    id: candidate.id,
                    status: status,
                    validationResult: Self.reviewMessage(for: status)
                )
                let detail: HarnessRunDetail?
                if let selectedRunId {
                    detail = try await ledger.runDetail(id: selectedRunId)
                } else {
                    detail = nil
                }
                await MainActor.run {
                    if let detail {
                        self.selectedDetail = detail
                    }
                    self.status = Self.reviewMessage(for: status)
                }
            } catch {
                await MainActor.run {
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        draft = ""
        isRunning = true
        status = "Checking graph authority"
        let selectedBackend = backend
        let key = apiKey.isEmpty ? nil : apiKey

        let service = service
        let ledger = ledger
        let ontology = ontology

        Task.detached(priority: .userInitiated) {
            let adapter = AgentRunnerBackendAdapter(backend: selectedBackend, apiKey: key)
            do {
                let detail = try await service.createRun(
                    prompt: prompt,
                    ontology: ontology,
                    backend: adapter
                )
                let latestRuns = try await ledger.listRuns()
                await MainActor.run {
                    self.selectedDetail = detail
                    self.runs = latestRuns
                    self.status = detail.run.success ? "Trace saved" : "Backend failed; trace saved"
                    self.isRunning = false
                }
            } catch {
                await MainActor.run {
                    self.status = error.localizedDescription
                    self.isRunning = false
                }
            }
        }
    }

    private static func reviewMessage(for status: CandidateState) -> String {
        switch status {
        case .suggested:
            return "Candidate returned to suggested."
        case .candidate:
            return "Candidate marked for review."
        case .rejected:
            return "Candidate rejected."
        case .validated:
            return "Candidate validation is not wired here."
        case .accepted:
            return "Candidate review cannot accept graph authority."
        }
    }
}

enum WorkbenchInspectorTab: String, CaseIterable, Identifiable {
    case authority = "Authority"
    case memory = "Memory"
    case trace = "Trace"
    case candidates = "Candidates"

    var id: String { rawValue }
}

struct WorkbenchToolGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let tools: [WorkbenchTool]

    static let defaults: [WorkbenchToolGroup] = [
        WorkbenchToolGroup(
            id: "authority",
            title: "Authority",
            tools: [
                WorkbenchTool(title: "Ontology steward", icon: "checkmark.seal", state: .available, detail: "accepted graph"),
                WorkbenchTool(title: "Graph trace", icon: "point.3.connected.trianglepath.dotted", state: .available, detail: "query proof"),
                WorkbenchTool(title: "Candidate review", icon: "tray.and.arrow.up", state: .readOnly, detail: "no promotion")
            ]
        ),
        WorkbenchToolGroup(
            id: "context",
            title: "Context",
            tools: [
                WorkbenchTool(title: "Vault search", icon: "doc.text.magnifyingglass", state: .readOnly, detail: "supporting memory"),
                WorkbenchTool(title: "Repo context", icon: "folder", state: .available, detail: "local files"),
                WorkbenchTool(title: "Run ledger", icon: "clock.arrow.circlepath", state: .available, detail: "SQLite trace")
            ]
        ),
        WorkbenchToolGroup(
            id: "backends",
            title: "Backends",
            tools: [
                WorkbenchTool(title: "Codex", icon: "terminal", state: .available, detail: "local CLI"),
                WorkbenchTool(title: "Grok", icon: "sparkles", state: .available, detail: "local CLI"),
                WorkbenchTool(title: "Claude", icon: "cloud", state: .available, detail: "API key"),
                WorkbenchTool(title: "Hermes local", icon: "shippingbox", state: .planned, detail: "planned")
            ]
        )
    ]
}

struct WorkbenchTool: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let state: WorkbenchToolState
    let detail: String

    init(id: String? = nil, title: String, icon: String, state: WorkbenchToolState, detail: String) {
        self.id = id ?? title.lowercased().replacingOccurrences(of: " ", with: "-")
        self.title = title
        self.icon = icon
        self.state = state
        self.detail = detail
    }
}

enum WorkbenchToolState: String, Equatable {
    case available = "available"
    case readOnly = "read-only"
    case planned = "planned"
}
#endif
