# Harness Architecture Brief

Date: 2026-06-30

## Plain Answer

Harness should be the control plane around Codex, Grok, Claude, and Hermes.

It should not be "another chat app." Its job is to decide what memory is allowed into a run, which rule shaped the answer, whether the answer passed, and what should be remembered later.

## Sources Reviewed

- Firecrawl transcript: `You Can Learn AI Agent Memory System In 12 Min`
- Firecrawl transcript: `You Can Learn AI Agent Harness & Loop Engineering In 19 Min`
- Local Harness repo: `/Users/adamblair/Documents/GitHub/Harness`
- Claude log material related to Hermes setup and authorization behavior
- Existing Understood Suite ontology and Hermes governance notes in the Obsidian vault

The Firecrawl captures are saved in this repo at:

- `Docs/Research/video-agent-harness-1.md`
- `Docs/Research/video-agent-harness-2.md`

## What The Videos Add

The two useful concepts are memory separation and run control.

Memory separation:

- Working memory: current prompt, current chat, selected rules.
- Procedural memory: how the agent should behave.
- Semantic memory: durable facts, beliefs, axioms, ontology terms.
- Episodic memory: dated run history, tool calls, outcomes, corrections.
- Consolidation gate: turns repeated episodic evidence into memory candidates.

Run control:

- Retrieve only relevant memory.
- Build the prompt.
- Run the selected model or CLI.
- Capture the trace.
- Evaluate the output.
- Retry or stop.
- Save the run.
- Propose memory updates only through a review queue.

## Correction To The Claude Research Brief

Claude's brief is useful, but it treats "semantic memory" mostly like normal agent memory: embeddings, vector search, and summarized durable facts.

That is not enough for this project.

Harness has to separate two kinds of memory:

- Probabilistic memory: embeddings, chat history, summaries, similarity search, model judgment.
- Deterministic memory: accepted RDF/Turtle, ontology terms, SHACL validation, SPARQL query results, promoted graph edges.

The deterministic layer is the authority layer. Vector search may suggest what matters, but it does not decide what is true inside the Understood Suite.

For Harness, the correct rule is:

Plain English input -> candidate claim -> existing standard term where possible -> Turtle -> SHACL validation -> SPARQL proof -> accepted graph.

That means Harness should not only retrieve "relevant memories." It should distinguish:

- retrieved context,
- candidate meaning,
- validated meaning,
- accepted graph authority.

## Deterministic Layer Role

The ontology is not just personal memory.

It is a machine-readable contract that can constrain Codex, Grok, Claude, Hermes, and future agents before Adam sees an answer.

Important existing rules from the Understood Suite work:

- Candidate memory requires review before durable agent memory.
- Hermes should start in the scoped Hermes Agent Workspace.
- Hermes should prefer read-only review until an explicit edit request.
- Hermes must consult RDF, SHACL, and SPARQL guardrails before acting.
- Promoted candidates must pass Docker/RDF validation and be answerable through SPARQL.

Harness should therefore treat the graph as more than content. It should treat it as an executable authority source.

In practical terms, a Harness answer should be able to show:

- the natural-language question,
- the retrieved candidate context,
- the accepted graph claims used,
- the SPARQL query or trace that proved those claims,
- the rule or axiom that shaped the answer,
- the eval result that allowed the answer through.

## What Harness Already Has

The current repo has a good starting shell:

- `OntologyKit` loads bundled Turtle files.
- `ClaudeClient.systemPrompt(from:)` turns the ontology into a system prompt.
- `AgentRunner` can call Codex, Grok, or Claude.
- The iOS/macOS UI already shows the correct idea: ask a question, route through a model, and require the answer to name the rule used.

This is enough for a prototype.

It is not yet a full harness.

## Current Gaps

The current app mostly does prompt-prefixing.

Missing pieces:

- No persistent `RunRecord`.
- No trace of retrieved rules, prompts, tool calls, errors, or eval results.
- No bounded repair loop.
- No formal output evaluation.
- No episodic memory store.
- No consolidation queue.
- No retrieval layer beyond simple text matching and broad prompt inclusion.
- No local safety boundary for secrets, filesystem access, or tool permissions.
- No SPARQL/Fuseki query path from the app into the accepted graph.
- No SHACL validation path for candidate memory.
- No explicit state distinction between suggested memory, candidate memory, validated memory, and accepted graph memory.

## Target Runtime Flow

One Harness run should follow this sequence:

1. Receive user prompt.
2. Identify intent and backend: Codex, Grok, Claude, or Hermes.
3. Retrieve probable context from local notes, prior runs, and embeddings.
4. Query accepted graph authority through SPARQL/Fuseki where possible.
5. Select relevant ontology facts, axioms, pattern steps, and prior runs.
6. Build the constrained prompt.
7. Execute the model or CLI.
8. Store a trace event for each important step.
9. Evaluate the answer.
10. If it fails, retry once or return the failure plainly.
11. Save the run as episodic memory.
12. If repeated evidence appears, create a memory candidate for review.
13. If a candidate is promoted, validate it through Turtle/SHACL/SPARQL before it enters accepted graph memory.

## Minimum Data Models

Harness should add these core records before adding more screens:

- `HarnessRun`: id, date, backend, user prompt, final answer, status, duration.
- `MemoryHit`: rule id, label, source file, score, reason selected.
- `TraceEvent`: timestamp, type, summary, payload path.
- `EvalResult`: check id, passed, reason, severity.
- `MemoryCandidate`: proposed fact, evidence run ids, status.
- `GraphAuthorityHit`: subject, predicate, object, source graph, SPARQL trace.
- `ValidationResult`: candidate id, Turtle path, SHACL status, SPARQL proof status.

## First Evals

The first evaluation layer should be simple and deterministic:

- Answer starts with the plain answer.
- Answer names the rule or says no confirmed rule applies.
- Answer does not expose secrets.
- Answer stays under the configured length cap when requested.
- Backend failure is captured as a failed run, not dropped.
- Memory candidates are never promoted directly into durable memory.
- Accepted graph claims are labeled separately from model guesses.
- Candidate memory cannot be shown as accepted graph authority.

## Hermes Authorization Lesson

The useful Claude-log lesson is not "wire every channel immediately."

The useful lesson is:

- CLI/Desktop first.
- Scoped `Hermes-Agent` workspace first.
- Read-only review before broad write access.
- Memory candidates before durable memory.
- Worktrees, checkpoints, and command approvals for code.
- Messaging gateways only after local behavior is predictable.

Harness should preserve that boundary. It can coordinate Hermes, but it should not blindly turn Hermes into a fully authorized remote control layer.

## Next Implementation Step

Build the run ledger first.

That means adding local persistence for `HarnessRun`, `MemoryHit`, `TraceEvent`, and `EvalResult`, then showing a run detail view that answers:

- What did I ask?
- What memory was used?
- Which rule shaped the answer?
- Did the answer pass?
- What should be remembered later?

That is the first point where Harness becomes a real harness instead of a styled chat shell.
