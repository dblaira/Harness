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
        status = "New session"
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
}

enum WorkbenchInspectorTab: String, CaseIterable, Identifiable {
    case authority = "Authority"
    case memory = "Memory"
    case trace = "Trace"
    case candidates = "Candidates"

    var id: String { rawValue }
}
#endif
