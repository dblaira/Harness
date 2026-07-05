> ⚠️ SUPERSEDED: vocabulary in this handoff is outdated as of `dc9b893`. Current contract: `Docs/SPEC-delegation-agents-v1.2.md`. Kept for history.

# Codex Handoff — Opportunity Scouts v1.1, Phase 1

Date: 2026-07-04
Repo: `/Users/blairstudio/GitHub/Harness` · GitHub: `https://github.com/dblaira/Harness` · branch `main`
Spec (read it first, it is the contract): `Docs/SPEC-opportunity-scouts-v1.1.md` — approved 2026-07-04, both former blockers resolved by overridable default.

## You have no prior context — here it is

Harness is Adam Blair's native macOS/iOS agent workbench (Swift/SwiftUI, XcodeGen via `project.yml`, shared package `Packages/OntologyKit`). It is a control plane: graph authority (`/accepted`), supporting memory, run ledger, evaluation, trace. Agents propose; a SHACL "bouncer" validates; only Adam's explicit review-queue decisions write authority.

**What you are building:** Opportunity Scouts — agents that fetch external signals via Firecrawl, triage them against Adam's accepted Discernment Rules (R-IDs in `/accepted`), and emit them as envelope-conformant markdown cards onto a dense sortable **Board**. Adam's eye does recognition; the machine holds all structure. No agent ever executes, spends, trades, contacts, or commits to anything.

## Scope: Phase 1 = P0 items 2–7 of the spec

(Item 1 — Discernment Rules through the queue — is Adam's job, not yours. Do not seed rules.)

1. **Card envelope + typed SHACL** — frontmatter parser (envelope whitelist + payload keyed on `type`), opportunity + source_card shapes, trust clamp, dedup-by-resource.
2. **The Opportunity Board** — macOS grid: 15 columns, three views (Scan / Now only / By Band), Priority formula `fit × 50` if no window else `fit × 100 / (window_days + 1)`, persistent sort, multi-row select.
3. **Scout run v1 (manual trigger)** — "Run scout" → Firecrawl Search (+ Scrape shortlisted) → LLM triage citing accepted rules via live SPARQL → envelope files → Board rows + Now-band cards → Trace.
4. **Verbs** — Pursue (itemized only) / Pass (bulk-able) / Hold (needs resurface condition) / Bookmark. Every verb writes ledger entries.
5. **No-execution guarantee** — negative test proving zero outbound calls from any verb except graph/ledger writes.
6. **Spend caps** — per-run + per-day Firecrawl budget, per-watchlist off switch; a cap breach halts fetching mid-run, labels partial results, writes an honest error to Trace. Caps never hide fetched rows. Row caps do not exist — do not add any.

Every P0 checkbox in the spec's Requirements section is an acceptance criterion. Tests green, committed per slice.

## What already exists — build on it, don't duplicate

In `Packages/OntologyKit/Sources/OntologyKit/`:

- `FirecrawlClient.swift` — Search / Scrape / Map adapters, key storage via connector UI, request/response parsing tests exist.
- `ReviewQueueStore.swift` + `RunEvaluation.swift` — the SHACL bouncer and queue live here (a validator path-resolution fix landed recently; check `git log`).
- `RunLedgerStore.swift` — local run ledger. Verbs write here.
- `HarnessRunService.swift` — fixed backend order: authority → memory → execution → evaluation → trace. Scout runs follow the same spine.
- `AuthorityRetrieval.swift` / `MemoryRetrieval.swift` — `/accepted` vs supporting-memory separation. The trust clamp belongs at this boundary.
- `HarnessExecutionRouting.swift` + `AgentPolicy.swift` — route planning and approval gating for Firecrawl actions.
- `MacWorkbenchModel.swift` / `MacChatView.swift` — three-pane workbench with right-side Analysis rail (Authority · Route · Memory · Candidates · Connections · Skills · Trace). The Board is a new center/primary surface; Now-band cards go to the existing candidates/queue pattern.
- Tests: `Packages/OntologyKit/Tests/OntologyKitTests/DeterministicBackendTests.swift` and app-level `Tests/HarnessTests/`.

## Golden fixtures — commit these to `Tests/fixtures/` verbatim

The SHACL shapes must validate against these two files (from the approved Notion preview). They are synthetic sample data.

`Tests/fixtures/OPP-0001.md`:

```yaml
---
type: opportunity
title: Journaling app sunsets exports Aug 1 — migration vacuum
description: Export shutdown strands users' data; Understood import path fits.
tags: [platform-watch, migration]
resource: https://example-journal.app/blog/sunset-notice
timestamp: 2026-06-30T14:12:00Z
trust_level: supporting_memory   # claim, not credential — Harness clamps
opp_id: OPP-0001
fit: 0.91
rules_hit: [R-01, R-02, R-07]
band: Now
window_days: 27
effort: in
dollar_order: 100K
attention: 143
times_seen: 5
sources: 9
scout_id: scout-platform
---
One-paragraph plain-English case for the fit, written by the scout,
citing each rule by ID. Sources listed below as markdown links.
```

`Tests/fixtures/OPP-0001-source.md`:

```yaml
---
type: source_card
title: Sunset notice — Example Journal blog
description: Official announcement of export shutdown, Aug 1 deadline.
tags: [platform-watch]
resource: https://example-journal.app/blog/sunset-notice
timestamp: 2026-07-04T09:03:00Z
trust_level: supporting_memory
retrieved_by: firecrawl-scrape
content_hash: sha256:9f2c…
linked_opportunities: [OPP-0001]
---
Scraped markdown body lives here, provenance-labeled, lowest trust tier.
```

## Laws (test these, not just implement them)

- `trust_level` is a claim, never a credential. Ingestion clamps every file to supporting-memory ceiling; render the self-declared value as metadata with "self-declared label ignored."
- `resource` is the dedup key. Same canonical resource → merge: `times_seen++`, `attention` recount, newest `timestamp` kept, row history preserved. Dedup runs before anything reaches the Board.
- SHACL keys on `type`. Opportunity requires `rules_hit ≥ 1`, `resource ≥ 1`, `fit ∈ [0,1]`, `band ∈ {Now, Hold, Out}`. Source card requires `resource`, `retrieved_by`, `content_hash`. Malformed → blocked with a plain-English reason, graph untouched.
- Pursue is itemized authority — disabled in multi-select; one click, one row, one ledger entry. Sweep-Pass writes N batch-tagged entries.
- Keys snake_case; Board columns are display names (`$ Order` ↔ `dollar_order`).

## Decisions already made (overridable only by Adam)

- **Watchlist #1:** the personal-data platform beat — export shutdowns, API changes, pricing moves across journaling/health/self-tracking apps; migration vacuums the Understood Suite can absorb.
- **Rules:** the 10 drafts enter the queue as-is; Adam's Sometimes/No clicks do the editing.

## Decisions you own (non-blocking — pick, note in commit message)

- Triage LLM: Hermes local vs. Claude API for the rule-matching pass (~50 docs/run). `ClaudeClient.swift`, `OpenAIClient.swift`, `XAIClient.swift` already exist as patterns.
- Board home: Harness-native table is primary; optional Notion mirror is P1, skip for now.
- Hold-resurface condition storage: frontmatter vs. ledger vs. graph.

## Adam's acceptance test (Phase 1 done means exactly this)

Press "Run scout" → rows appear on the Board, deduped by resource, every row citing R-IDs and ≥1 source → sort by Priority, sweep-Pass a batch, Pursue one → Pursue wrote a single itemized ledger entry, Pass wrote batch entries → a file declaring `trust_level: accepted` displays as supporting memory with "self-declared label ignored" → Trace shows queries, spend, and rows emitted. Zero external side effects from any verb.

## Protocol

```sh
cd /Users/blairstudio/GitHub/Harness
git pull --ff-only origin main
swift test --package-path Packages/OntologyKit
xcodebuild -scheme Harness -destination 'platform=macOS' build
```

Commit and push each working slice to `main`. Do not commit `Harness.xcodeproj/`, `build/`, `DerivedData/`, `.build/`, `.local-artifacts/`. Never write to the vault or `/accepted`; never store credentials in the repo. When writing anything Adam will read, obey `Docs/skills/articulate-leadership-communication/SKILL.md` and `Docs/skills/no-time-estimates/SKILL.md` (never estimate Adam's time or attach urgency framing).
