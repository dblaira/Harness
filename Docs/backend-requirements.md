# Harness Backend Requirements

Date: 2026-06-30

## Purpose

Harness needs a backend that lets the macOS and iOS apps ask AI systems for help while forcing those systems to consult Adam's deterministic meaning layer first.

The backend is not only a chat relay. It is the authority, memory, trace, and validation layer between the app and the model.

## Core Requirement

Every meaningful answer must follow this order:

1. Receive the user prompt.
2. Check the deterministic layer first.
3. Retrieve accepted graph authority through RDF/SPARQL where possible.
4. Retrieve supporting memory only after graph authority is checked.
5. Build a constrained model packet.
6. Run the selected model or agent.
7. Evaluate the result.
8. Save the run trace.
9. Create memory or ontology candidates only when warranted.

The model may infer from the graph, but it should not replace the graph.

## Deterministic Layer Requirements

The backend must treat the ontology and knowledge graph as the source of meaning.

Required capabilities:

- Load accepted RDF/Turtle graph files.
- Query accepted graph claims through SPARQL.
- Support local Fuseki or an equivalent SPARQL endpoint.
- Keep candidate claims separate from accepted graph claims.
- Validate candidate Turtle before graph promotion.
- Run SHACL validation before accepting new structured claims.
- Store SPARQL proof or query traces for graph-backed answers.
- Cite which graph rule, axiom, or claim shaped an answer.

Minimum graph states:

- `suggested`: model- or user-suggested idea.
- `candidate`: structured claim awaiting validation or review.
- `validated`: syntactically and structurally valid claim.
- `accepted`: approved graph authority.
- `rejected`: not accepted, with reason.

## Memory Requirements

Harness needs memory, but memory must be subordinate to the deterministic layer.

### Working Memory

Current run context:

- user prompt,
- selected backend,
- short current conversation,
- selected graph authority,
- selected supporting memory,
- active app state.

This should be temporary unless saved as a run trace.

### Procedural Memory

Instructions for how agents should act:

- app rules,
- communication style rules,
- tool-use policies,
- safety policies,
- backend-specific instructions,
- "plain answer first" requirements,
- "name the rule used" requirements.

Procedural memory may live in markdown or app-bundled policy files, but the backend should version and cite it.

### Semantic Memory

Durable facts, concepts, beliefs, preferences, and relationships.

Important distinction:

- accepted semantic memory belongs in the ontology or accepted graph;
- probable semantic memory can live in vector search or summaries;
- probable memory cannot be cited as deterministic authority.

### Episodic Memory

Dated history of runs:

- prompt,
- backend selected,
- graph claims retrieved,
- model response,
- tools called,
- errors,
- evaluation results,
- final answer,
- user correction or acceptance.

Episodic memory should support later review, search, and consolidation.

### Candidate Memory

Potential durable memory extracted from repeated episodes or explicit user statements.

Candidate memory must not be silently promoted.

Candidate memory requires:

- source run ids,
- evidence text,
- proposed claim,
- proposed graph form when possible,
- status,
- review or validation result.

## Retrieval Requirements

The backend should support two retrieval paths.

### Authority Retrieval

This runs first.

Sources:

- accepted RDF graph,
- accepted ontology files,
- promoted graph rules,
- SHACL shapes,
- SPARQL query results.

Output:

- `GraphAuthorityHit` records with subject, predicate, object, source, and query trace.

### Supporting Retrieval

This runs second.

Sources:

- episodic memory,
- notes,
- prior chats,
- embeddings,
- local files,
- research captures.

Output:

- `MemoryHit` records with source, score, reason selected, and authority level.

Supporting retrieval may guide the model, but it must be labeled separately from accepted graph authority.

## Model And Agent Routing Requirements

Harness should route to multiple backends:

- Codex,
- Grok,
- Claude API,
- Hermes local agent,
- future local models.

Each run must record:

- backend,
- model name when known,
- invocation method,
- prompt packet hash or saved prompt packet,
- success/failure,
- duration,
- token/cost data when available.

The backend should support macOS-first capabilities where local CLIs are available and iOS-safe behavior where they are not.

## Run Ledger Requirements

Every model interaction must create a run ledger entry.

Required records:

- `HarnessRun`
- `HarnessMessage`
- `GraphAuthorityHit`
- `MemoryHit`
- `TraceEvent`
- `EvalResult`
- `MemoryCandidate`
- `ValidationResult`

The run detail should answer:

- What did Adam ask?
- What graph authority was consulted?
- What supporting memory was used?
- What model or agent answered?
- Which rule shaped the answer?
- Did the answer pass?
- What should be remembered or formalized later?

## Evaluation Requirements

The backend needs deterministic checks before returning or saving important output.

Initial checks:

- answer starts with the plain answer,
- answer names the accepted rule used or says none applied,
- accepted graph claims are not mixed with model guesses,
- candidate memory is not presented as accepted memory,
- secrets are not written to logs or markdown,
- backend failures are recorded,
- output length policy is respected when active.

Later checks:

- SPARQL answerability check,
- SHACL validation check,
- source citation check,
- tool permission check,
- hallucinated graph claim check,
- user correction follow-up check.

## Ontology Growth Requirements

Harness should help the deterministic layer grow.

Required pipeline:

1. Capture useful statement or repeated pattern.
2. Create candidate memory.
3. Compare against existing graph and public vocabularies where relevant.
4. Propose RDF/Turtle.
5. Validate with SHACL.
6. Prove with SPARQL where possible.
7. Promote only through an explicit rule, review, or approved automation.
8. Preserve the evidence trail.

The backend must never collapse this into "the model remembers it."

## Sync Requirements

Harness runs on macOS and iOS, so the backend must support sync.

Minimum:

- local-first storage for app responsiveness,
- eventual sync across devices,
- conflict handling for run records and candidate memory,
- clear device/source attribution,
- offline read access to recent accepted graph rules.

Preferred:

- macOS can run local graph services and CLI agents,
- iOS can consume synced graph snapshots and call approved remote endpoints,
- both clients can view run history and candidate memory.

## Privacy And Safety Requirements

The backend must protect sensitive data.

Required:

- no raw secrets in markdown,
- no API keys in run traces,
- redaction before persistence,
- tool permission boundaries,
- filesystem scope controls,
- clear separation between local-only data and synced data,
- audit trail for graph mutation,
- explicit handling for Hermes authorization boundaries.

## API Requirements

The app needs backend APIs for:

- creating a run,
- retrieving graph authority for a prompt,
- retrieving supporting memory,
- executing a selected backend,
- recording trace events,
- evaluating an answer,
- listing runs,
- viewing a run detail,
- creating memory candidates,
- listing candidate queue,
- validating candidate Turtle,
- promoting accepted graph updates.

The first implementation can be local Swift services. The API boundaries should still be designed as if they may later become HTTP endpoints.

## Storage Requirements

Initial acceptable storage:

- local JSON or SQLite/SwiftData for run ledger,
- bundled Turtle files for accepted graph snapshot,
- local files for trace payloads.

Expected next storage:

- local Fuseki or Jena-backed SPARQL service on macOS,
- synced database for runs and candidates,
- vector store for supporting retrieval,
- graph snapshot export for iOS.

## Non-Goals

Harness should not start by becoming:

- a generic chatbot,
- a generic vector-memory app,
- a full ontology editor,
- a replacement for Protégé,
- an unrestricted Hermes remote-control surface.

The first useful backend is smaller:

accepted graph first, supporting memory second, model third, eval fourth, trace always.

## First Backend Milestone

Build the local run ledger and authority packet builder.

Milestone output:

- a saved `HarnessRun`,
- selected graph authority hits,
- selected supporting memory hits,
- final model answer,
- eval result,
- run detail view data.

This milestone proves that Harness is using the deterministic layer as a working backend requirement, not just as text pasted into a prompt.
