# SPEC — Hermes Parity v1

status: implementation in progress (2026-07-06)
goal: Harness gains the Hermes agent's capabilities and personality — skills,
memory, routines, a real tool loop, a helpful doer voice — while keeping the law.

## The law (unchanged, verbatim)

"Agents propose. The bouncer checks. You decide. No agent ever spends,
trades, contacts, or commits to anything."

- Nothing enters /accepted except through Adam's queue.
- trust_level is a claim, never a credential — clamped at ingestion.
- The Kill Switch is spend caps; raising them is an Adam decision, logged.

## Adam's exact-words law

"the only thing I will listen to our rules and skills and descriptions that
use my exact words" — personality text is LOADED VERBATIM from Adam's files
(vault SOUL.md, Response Rules, skills), never paraphrased into code strings.

## Diagnosis (why Harness feels strict today)

- `PromptPacketBuilder.makePacket` (AuthorityRetrieval.swift:209-286) +
  `ClaudeClient.systemPrompt` (ClaudeClient.swift:28-37) frame a cage:
  "constrained by his confirmed personal ontology. Reason INSIDE these rules."
- `Rule:` / `Adam Pattern Step:` markers demanded twice per answer.
- Refusal bias: "When no confirmed rule applies, say so plainly."
- No helpfulness/execution mandate anywhere; every backend single-shot with
  tools affirmatively disabled (grok `--disallowed-tools ... --max-turns 1`
  AgentRunner.swift:260-267; Codex `"tools": []` CodexSessionClient.swift:86).
- Context budget spent enumerating all axioms/connections instead of task help.

## Architecture

Four ideas: (A) Hermes-style three-tier prompt, (B) `~/.hermes` + vault files
read in place as shared truth (never copied), (C) agentic tool loop where every
mutation flows through the bouncer, (D) learning writes proposals, not truth.

Prompt tiers (byte-stable per session for cache discipline):
- STABLE: SOUL.md (vault wins, slot #1) → doer-identity block (Hermes
  TASK_COMPLETION / TOOL_USE_ENFORCEMENT language adapted: "execute with your
  tools; anything that spends, contacts, or commits is a proposal for Adam")
  → skills index (category-grouped, "err on the side of loading" header).
- CONTEXT: ontology reframed as context, not cage ("this graph is Adam's
  confirmed truth — use it; cite Rule ids in Supporting Evidence"), policy
  directives, delegation-context rule.
- VOLATILE: whole-file memory snapshot frozen at session start
  (~/.hermes/memories/MEMORY.md + vault Main/Memory hub notes), date-only stamp.
- Response-format rules loaded verbatim from skill files (articulate-
  leadership-communication, cognitive-fit, no-time-estimates, adams-words);
  markers move to the Supporting Evidence chapter, cited once.
- Per-query retrieval hits move OUT of the system prompt into user messages.

Tool loop v1 (iteration budget ~30, per-call trace events into RunLedgerStore):
`shell`, `read_file`, `search_files`, `write_file` (gated), `memory` (stages
MemoryCandidate via ReviewQueueStore — always), `skills_list`, `skill_view`,
`session_search`. Native tool-calling in ClaudeClient, XAIClient, OpenAIClient,
and GrokSessionClient; backends without tool support degrade to single-shot.
Spend/contact/commit tools do not exist in the schema.

The bouncer as UI: `ToolApprovalStore` — dangerous shell patterns, all writes,
all network sends suspend the loop and render an approve/deny card in chat
(SAVY crimson primary). Persistent allowlist. This is the law made visible.

## Workstreams and file ownership (no two workstreams edit the same file)

- WS-A1 PromptAssembler: NEW PromptAssembler.swift, MemorySnapshot.swift;
  EDITS AuthorityRetrieval.swift, SoulLoader.swift, HarnessCapability.swift,
  ClaudeClient.swift (systemPrompt string only); tests.
- WS-A2 Tools: NEW HarnessTools.swift, ToolApprovalStore.swift, ToolExecutor.swift; tests.
  (Runs after A1 — uses the upgraded HarnessCapabilityRegistry API.)
- WS-A3 SAVY components: NEW Sources/Harness/SavyComponents.swift;
  EDITS Theme.swift (Roboto registration, #EFEBE4, missing tokens),
  Docs/design-vocabulary.md palette paragraph.
- WS-A4 Sessions: EDITS RunLedgerStore.swift (sessions table, FTS5);
  NEW SessionStore.swift; tests.
- WS-B1 Loop integration: EDITS BackendModels.swift (ModelPacket tools),
  ClaudeClient.swift, XAIClient.swift, OpenAIClient.swift, GrokSessionClient.swift
  (native tool calls),
  HarnessRunService.swift (the loop, approval suspension, PromptAssembler wiring),
  AgentRunner.swift (remove tool-disabling flags where loop applies); tests.
- WS-B2 Chat UI: EDITS MacWorkbenchModel.swift, MacChatView.swift,
  MacDelegateFormView.swift (approval card, live status, real skill loading,
  session restore). Does NOT touch MacCockpitView.swift or HarnessApp.swift.
- WS-C Routines: NEW RoutineScheduler.swift, RoutinesView.swift;
  EDITS HarnessApp.swift, MacCockpitView.swift (display Hermes cron jobs
  read-only from ~/.hermes/cron/jobs.json incl. last_status, own
  harness-routines.json for native jobs firing headless runs).

## Baseline

190/192 OntologyKit tests green. Pre-existing failures (NOT regressions):
- codexUsesChatGPTAuthenticatedCLIInvocation (BackendReadinessTests.swift:41)
- delegationContextParsesPrompt (DelegationContextTests.swift:17)

## Post-review hardening (adversarial review, applied 2026-07-07)

A six-lens adversarial review (concurrency, security, law, correctness, UI,
fidelity) with 3-vote verification confirmed 24 findings. Fixes applied:

Security (law-critical):
- Subshell/paren-wrap deny bypass — the shell tool's own workdir wrapper wraps
  the command in `( … )`, and `(` was not a command-position separator, so
  every hardline rule was defeated automatically. Added `( ) { }` to the anchor.
  (ToolApprovalStore.swift; regression test subshellWrappedHardlineIsStillDenied.)
- Secret exfiltration via shell — the child inherited the app's full
  environment (ANTHROPIC_API_KEY, XAI_API_KEY), so `echo $XAI_API_KEY` / `env`
  leaked keys past any matcher. Now the agent-invoked shell scrubs
  credential-shaped env vars (AgentRunner.scrubbingSecretEnvironment), and the
  secrets deny-floor matches credential files anywhere (.env, .ssh keys,
  .aws/credentials, .netrc…), not just under ~/.hermes.
  (Tests: secretEnvironmentIsScrubbed, shellSecretFileReadsAreDeniedAnywhere.)
- Network exfil gaps — added nc/ncat/netcat/socat/telnet/tftp, ftp/lftp/sftp,
  curl --upload-file/-T, and full-env-dump to the approval tier.
  (Test: rawSocketNetworkingRequiresApproval.)

Backend readiness (live-auth critical):
- Grok session auth now checks `~/.grok/auth.json` for missing or expired
  tokens before marking the backend live. Missing or expired subscription auth
  surfaces `run grok login --oauth` and the macOS toolbar exposes a Grok authorize
  action; a CLI binary existing on disk is no longer enough. The same session
  proxy path was smoke-tested with a minimal request and returned HTTP 200.
  Grok account auth now supports OpenAI-style `tools` / `tool_calls`, so the
  live app can use shell/read/search/write/memory tools without an xAI API key.
  (Tests: grokAuthorizationActionIsNamed, grokSessionClientIgnoresExpiredToken,
  grokSessionClientDetectsJWTExpiration, grokSessionClientBuildsToolRequestBody,
  grokSessionClientParsesToolCalls.)

Concurrency / state:
- Cancelled or superseded run clobbering a newer run — both completion branches
  now guard on `activeToolLoop === monitor`; the transcript append also guards
  on session identity; cancelRun drops the monitor. (MacWorkbenchModel.swift.)
- Stale approval card — publishes to the main-actor mirror are now applied in
  lock-assigned sequence order, so a late Task can't resurrect a resolved card.
- SQLITE_BUSY from a second ledger connection — applicationDefault() is now one
  shared instance per process, plus a busy timeout. (RunLedgerStore.swift.)
- PromptAssembler byte-stability — the frozen memory snapshot is keyed by
  session id (bounded LRU) so interleaved chat + headless routine sessions
  don't evict each other.
- read_file per-line cap; RoutineScheduler serialized disk persist;
  searchSessions stale-result guard; approval toast made non-interactive;
  new-approval auto-scroll targets the newest request.

Reviewed and intentionally NOT changed (working as designed):
- Per-query retrieval blocks live in `system` after the byte-stable tier prefix
  (a cache-a-prefix design the tests encode: PromptAssemblerTests asserts the
  stable prefix excludes them and `system.hasPrefix(tiers.joined)`).
- Approve-after-cancel still executes the approved command (B2: the pending
  queue is never silently drained; Adam decides from the card).

Residual, documented (inherent or deferred):
- A regex denylist on shell strings can never be fully bypass-proof against
  arbitrary substitution (`rm -rf $(echo /)`). The real backstops are
  env-scrubbing (crown jewels removed), read/write roots confined to Adam's own
  content, every call in the transcript under Adam's eye, and no
  spend/contact/commit tool existing in the schema.
- Chat Cancel still terminates an in-flight routine's CLI subprocess (shared
  global process registry); per-run scoping deferred.
- The Claude tool-loop path does not yet forward image attachments (Grok does).

Baseline after hardening: 187 OntologyKit tests, 2 pre-existing failures only;
`xcodebuild -scheme Harness -destination 'platform=macOS'` → BUILD SUCCEEDED.

## Out of scope v1 (P2, later)

MCP client, hooks, kanban board, subagent delegate tool, background learning
loop, launchd run-while-closed.
