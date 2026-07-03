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
    @Published var selectedTool: WorkbenchTool?
    @Published var reviewQueueCandidates: [MemoryCandidate] = []
    let toolGroups = WorkbenchToolGroup.defaults

    private let ledger: RunLedgerStore
    private let service: HarnessRunService
    private let reviewQueue: ReviewQueueStore

    init() {
        let store: RunLedgerStore
        do {
            store = try RunLedgerStore.applicationDefault()
        } catch {
            store = try! RunLedgerStore.inMemory()
        }
        self.ledger = store
        self.service = HarnessRunService(ledger: store)
        self.reviewQueue = ReviewQueueStore(ledger: store)
        Task {
            await refreshRuns()
            await refreshReviewQueue()
        }
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

    func selectTool(_ tool: WorkbenchTool) {
        selectedTool = tool
        status = "\(tool.title): \(tool.state.rawValue)"
    }

    func refreshReviewQueue() async {
        do {
            reviewQueueCandidates = try await reviewQueue.loadPendingClaims()
            status = "\(reviewQueueCandidates.count) candidate\(reviewQueueCandidates.count == 1 ? "" : "s") waiting"
        } catch {
            reviewQueueCandidates = []
            status = "Candidates unavailable: \(error.localizedDescription)"
        }
    }

    func scanForNewPatterns() {
        status = "Scanning Supabase evidence"
        Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try Self.runEvidenceIngest()
                }.value
                reviewQueueCandidates = try await reviewQueue.loadPendingClaims()
                status = output
            } catch {
                status = "Evidence scan failed: \(error.localizedDescription)"
            }
        }
    }

    func decideReviewQueueCandidate(_ candidate: MemoryCandidate, decision: ReviewQueueDecision) {
        let reviewQueue = reviewQueue
        Task {
            do {
                let outcome = try await reviewQueue.decide(claimId: candidate.id, decision: decision)
                let pending = try await reviewQueue.loadPendingClaims()
                await MainActor.run {
                    self.reviewQueueCandidates = pending
                    if let blocked = outcome.blockedReason {
                        self.status = blocked
                    } else {
                        self.status = "\(pending.count) candidate\(pending.count == 1 ? "" : "s") waiting"
                    }
                }
            } catch {
                await MainActor.run {
                    self.status = error.localizedDescription
                }
            }
        }
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

    func prepareCandidateForGraphReview(_ candidate: MemoryCandidate) {
        let proposedGraph = CandidateGraphDraftBuilder().draft(for: candidate)
        let draftCandidate = MemoryCandidate(
            id: candidate.id,
            runId: candidate.runId,
            sourceRunIds: candidate.sourceRunIds,
            evidenceText: candidate.evidenceText,
            proposedClaim: candidate.proposedClaim,
            proposedGraph: proposedGraph,
            status: .candidate,
            validationResult: candidate.validationResult,
            createdAt: candidate.createdAt
        )
        let validation = TurtleCandidateValidator().validate(candidate: draftCandidate)
        guard validation.passed else {
            status = validation.detail
            return
        }

        let selectedRunId = selectedDetail?.run.id
        let ledger = ledger
        Task {
            do {
                try await ledger.updateCandidateReview(
                    id: candidate.id,
                    status: .validated,
                    proposedGraph: proposedGraph,
                    validationResult: "Ready for graph review. Not accepted authority."
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
                    self.status = "Candidate ready for graph review."
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

    nonisolated private static func runEvidenceIngest() throws -> String {
        let scriptURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/GitHub/Harness/scripts/ingest_evidence.py")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw NSError(
                domain: "HarnessEvidenceIngest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "scripts/ingest_evidence.py was not found."]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path]
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            let message = error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? output
                : error
            throw NSError(
                domain: "HarnessEvidenceIngest",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }

        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let count = json["candidates_created"] as? Int {
            return "Evidence scan complete: \(count) new candidate\(count == 1 ? "" : "s")."
        }
        return "Evidence scan complete."
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
                WorkbenchTool(
                    title: "Ontology steward",
                    icon: "checkmark.seal",
                    state: .available,
                    detail: "accepted graph",
                    summary: "Retrieves accepted ontology facts before model execution.",
                    permission: "Read-only bundled Turtle graph.",
                    provenance: "Authority hits are recorded on each run."
                ),
                WorkbenchTool(
                    title: "Graph trace",
                    icon: "point.3.connected.trianglepath.dotted",
                    state: .available,
                    detail: "query proof",
                    summary: "Shows the local query trace behind accepted graph hits.",
                    permission: "Read-only run inspection.",
                    provenance: "Trace text is saved in the run ledger."
                ),
                WorkbenchTool(
                    title: "Candidate review",
                    icon: "tray.and.arrow.up",
                    state: .readOnly,
                    detail: "no promotion",
                    summary: "Marks suggested memory for review, rejection, or graph-review preparation.",
                    permission: "Can update candidate status; cannot accept graph authority.",
                    provenance: "Candidate status changes persist in the ledger."
                )
            ]
        ),
        WorkbenchToolGroup(
            id: "context",
            title: "Context",
            tools: [
                WorkbenchTool(
                    title: "Vault search",
                    icon: "doc.text.magnifyingglass",
                    state: .readOnly,
                    detail: "supporting memory",
                    summary: "Finds local notes as supporting memory after authority retrieval.",
                    permission: "Read-only markdown, text, and Turtle files.",
                    provenance: "Memory hits are labeled supporting, not accepted."
                ),
                WorkbenchTool(
                    title: "Repo context",
                    icon: "folder",
                    state: .available,
                    detail: "local files",
                    summary: "Keeps Harness project docs and source files visible to retrieval.",
                    permission: "Read-only project context for this surface.",
                    provenance: "Source file paths are shown in memory cards."
                ),
                WorkbenchTool(
                    title: "Run ledger",
                    icon: "clock.arrow.circlepath",
                    state: .available,
                    detail: "SQLite trace",
                    summary: "Persists prompts, replies, authority, memory, evals, traces, and candidates.",
                    permission: "Writes local Application Support ledger records.",
                    provenance: "Every saved run has a prompt packet hash."
                )
            ]
        ),
        WorkbenchToolGroup(
            id: "backends",
            title: "Backends",
            tools: [
                WorkbenchTool(
                    title: "Codex",
                    icon: "terminal",
                    state: .available,
                    detail: "local CLI",
                    summary: "Routes model packets to the local Codex CLI on macOS.",
                    permission: "Uses existing CLI authentication.",
                    provenance: "Backend metadata records local-cli invocation."
                ),
                WorkbenchTool(
                    title: "Grok",
                    icon: "sparkles",
                    state: .available,
                    detail: "local CLI",
                    summary: "Routes model packets to the local Grok CLI on macOS.",
                    permission: "Uses existing CLI authentication.",
                    provenance: "Backend metadata records local-cli invocation."
                ),
                WorkbenchTool(
                    title: "Claude",
                    icon: "cloud",
                    state: .available,
                    detail: "API key",
                    summary: "Routes model packets to Claude through the configured API key.",
                    permission: "Uses environment or entered Anthropic API key.",
                    provenance: "Backend metadata records https-api invocation."
                ),
                WorkbenchTool(
                    title: "Hermes local",
                    icon: "shippingbox",
                    state: .available,
                    detail: "local model",
                    summary: "Routes model packets to a local Hermes 3 (8B) model via Ollama. No subscription, no API key, no network egress.",
                    permission: "Requires `ollama serve` running locally on 127.0.0.1:11434.",
                    provenance: "Backend metadata records local-http invocation."
                )
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
    let summary: String
    let permission: String
    let provenance: String

    init(
        id: String? = nil,
        title: String,
        icon: String,
        state: WorkbenchToolState,
        detail: String,
        summary: String,
        permission: String,
        provenance: String
    ) {
        self.id = id ?? title.lowercased().replacingOccurrences(of: " ", with: "-")
        self.title = title
        self.icon = icon
        self.state = state
        self.detail = detail
        self.summary = summary
        self.permission = permission
        self.provenance = provenance
    }
}

enum WorkbenchToolState: String, Equatable {
    case available = "available"
    case readOnly = "read-only"
    case planned = "planned"
}
#endif
