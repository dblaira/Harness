> ⚠️ SUPERSEDED by `SPEC-delegation-agents-v1.2.md` (2026-07-05, Suite-language revision — laws unchanged). Kept for history.

---
type: feature_spec
title: Opportunity Scouts v1.1 — The Board, the Envelope, the Fleet Contract
created: 2026-07-04
supersedes: SPEC-opportunity-scouts-v1.md
status: approved-for-codex — blanket approval recorded 2026-07-04; former blocking inputs filled with overridable defaults (see Open Questions)
owner: Adam Blair
builds_on: Harness review queue, SHACL bouncer, Firecrawl adapters, run ledger
approved_visual: Notion — "Opportunity Board — Row Schema Preview (SPEC v1.1)"
trust_level: proposal — nothing here enters /accepted without the queue
---

# Opportunity Scouts v1.1

## FOR ADAM (read this, skip the rest if you want)

**What changed since v1 — six things, all yours:**

1. **The Board replaces the card cap.** Cap authority, never data. Scouts
   emit unlimited rows into one dense, sortable, numeric grid. Your eye
   scans in bulk; the system never throttles signal.
2. **Cards demoted to push channel.** Only Now-band items with real
   timing edges interrupt you. Everything else pools on the Board for
   your schedule.
3. **One envelope for every card.** OKF frontmatter (`type` `title`
   `description` `tags` `resource` `timestamp`) + your `trust_level`,
   with judgment fields as payload. Source cards and opportunity rows
   are now ONE convention — Codex builds it once.
4. **`resource` is the dedup key.** Forty echoes of one URL collapse to
   one row with `attention: 40`. Crowd focus becomes a number you sort by.
5. **Fleet gating flipped.** Scouts #2–#100 enter by schema conformance
   + budget fit. Precision stats prune (retire scouts you always Pass),
   never gate.
6. **New Clear Sign:** one hour on the Board → ≥1 Pursue you'd never
   have found manually. Your sentence, made observable.

**Your test when Codex says the initial build is done:** press "Run scout" → rows
appear on the Board, deduped by resource, every row citing R-IDs and ≥1
source → sort by Priority, sweep-Pass a batch, Pursue one → Pursue wrote
a single itemized ledger entry, Pass wrote batch entries → a file
declaring `trust_level: accepted` displays as supporting memory with
"self-declared label ignored" → Trace shows queries, spend, and rows
emitted. Zero external side effects from any verb.

**The law, unchanged:** *Scouts propose. The bouncer checks. You decide.
No agent ever spends, trades, contacts, or commits to anything.*

---

## Changelog v1 → v1.1

| # | v1 | v1.1 |
|---|-----|------|
| 1 | Card queue, ≤5/run ≤10/day cap | Board primary, rows uncapped; caps moved to spend |
| 2 | Cards = the surface | Cards = Now-band push only |
| 3 | Opportunity SHACL shape (bespoke) | OKF envelope + typed payload; SHACL keyed on `type` |
| 4 | Source cards = separate roadmap item | Same envelope; one convention, one build |
| 5 | Attention-density (descriptive) | `resource` dedup makes it mechanical |
| 6 | Clear Sign: 1 card in 14 days | Clear Sign: 1 hour on Board → ≥1 manual-miss Pursue |
| 7 | Fleet earns entry via precision | Fleet enters via conformance; precision prunes |

## Problem Statement

Adam's highest-value skill (discernment) is spent on his lowest-value
activity (fetching). v1 correctly built the judgment pipeline but
throttled input volume — protecting a bottleneck Adam doesn't have. His
aptitude profile (Graphoria 70th, Number Facility 85th) and demonstrated
throughput (4,873 extractions metabolized into patterns) show bulk
scanning is his native format. The scarce resource is not his scanning
bandwidth; it is his *authority* — decisions that write to the ledger.
v1.1 uncaps data and keeps authority itemized.

## Goals

1. **Taste as authority.** ≥10 Discernment Rules through the queue into
   `/accepted` within 7 days, citable as R-01…R-n.
2. **Board live.** Scout #1 emitting deduped, rule-cited rows to the
   Board within 14 days of the initial build start.
3. **The Clear Sign.** One hour of Board scanning yields ≥1 Pursue Adam
   judges he would not have found manually. First fire within 30 days.
4. **Zero authority leaks.** 0 rows enter `/accepted`, 0 external
   actions, 0 self-declared trust labels obeyed. Verified by tests.

## Non-Goals (v1.1)

- **Auto-execution of anything.** Standing rule, not a version cut.
- **Autonomous promotion.** No row self-promotes. Standing Rule 1.
- **OKF connector / bundle furniture.** `index.md`, `log.md`, folder
  conventions stay out. The envelope is adopted; the ecosystem is not.
  Run ledger already does the log's job.
- **Row caps as safety.** Removed by design. Safety = spend caps +
  dedup + bands. Reintroducing row caps requires an Adam decision.
- **Livestream / realtime ingestion.** Post-fleet concern (P2+).
- **Paywalled / ToS-restricted sources.** Scouts read what Adam could
  legally read in a browser.

## The Card Envelope (new — the fleet contract)

Every artifact a scout or agent emits is a markdown file with YAML
frontmatter. OKF-conformant by construction (only `type` required
upstream; unknown keys tolerated).

**Envelope (all types):** `type` · `title` · `description` · `tags` ·
`resource` · `timestamp` · `trust_level`

**Payload `type: opportunity`:** `opp_id` `fit` `rules_hit` `band`
`window_days` `effort` `dollar_order` `attention` `times_seen`
`sources` `scout_id`

**Payload `type: source_card`:** `retrieved_by` `content_hash`
`linked_opportunities`

**Laws of the envelope:**
- `trust_level` is a claim, never a credential. Ingestion clamps every
  file to supporting-memory ceiling; the self-declared value renders as
  metadata with "self-declared label ignored."
- `resource` is the dedup key. New file, same canonical resource →
  merge: `times_seen++`, `attention` recount, newest `timestamp` kept,
  row history preserved.
- Keys are snake_case; Board columns are display names (`$ Order` ↔
  `dollar_order`).
- SHACL keys on `type`. Opportunity shape requires: `rules_hit ≥ 1`,
  `resource ≥ 1`, `fit ∈ [0,1]`, `band ∈ {Now, Hold, Out}`. Source-card
  shape requires: `resource`, `retrieved_by`, `content_hash`. Malformed
  → blocked with plain-English reason, graph untouched.
- **Golden fixtures:** the two sample files on the approved Notion
  preview page (OPP-0001 + its source card). Codex commits them to
  `Tests/fixtures/` and validates the shapes against them.

## The Board (new — primary P0 surface)

One dense grid, one row per deduped opportunity. Numbers first.

- **Columns:** Headline · Opp ID · Arena · Fit · Rules Hit · $ Order ·
  Effort · Window Days · Attention · First Seen · Times Seen · Band ·
  Sources · Scout · Priority.
- **Priority (default sort):** `fit × 50` if no window, else
  `fit × 100 / (window_days + 1)`.
- **Views:** Scan (Priority ↓) · Now only (Window ↑) · By Band.
- **Machine holds structure:** persistent sorts, pinned flags, stable
  IDs, row history. Adam's eye supplies recognition only. *(Analytical
  Reasoning 13th, Number Memory 5th — the Board carries sequence and
  state so he never has to.)*
- **Bulk-scan yes, bulk-authority no:** Pass and dismiss work in sweeps
  (multi-row select). Pursue is itemized — one click, one row, one
  ledger entry. The graph never takes bulk writes.

**Cards, rescoped:** the push channel. Only Now-band rows with
`window_days` below a per-watchlist threshold surface as cards. All
card verbs also available on Board rows.

## Requirements

### P0 — Must have

1. **Discernment Rules in the graph.** Via existing queue; stable R-IDs;
   SPARQL-queryable from `/accepted`. *(Carried from v1.)*
2. **Card envelope + typed SHACL.** Parser (envelope whitelist +
   payload by type), both shapes, trust clamp, dedup-by-resource.
   - [ ] Golden fixtures validate against their shapes.
   - [ ] File with `trust_level: accepted` → supporting memory +
     "self-declared label ignored."
   - [ ] Two files, same resource → one row, `times_seen: 2`.
   - [ ] Missing `rules_hit` or `resource` → blocked, plain-English
     reason, graph untouched.
3. **The Opportunity Board.** Columns, three views, Priority formula,
   persistent sort state, multi-row select.
   - [ ] Sort survives app restart; row IDs stable across runs.
   - [ ] Sweep-Pass N rows → N ledger entries batch-tagged; Pursue
     disabled in multi-select.
4. **Scout run v1 (manual trigger).** "Run scout" → Firecrawl Search
   (+ Scrape shortlisted) → LLM triage citing accepted rules via live
   SPARQL → envelope files → Board rows + Now-band cards → Trace saves
   queries, spend, rows emitted, rules cited.
5. **Verbs.** Pursue (itemized; records commitment; executes nothing) /
   Pass (bulk-able) / Hold (requires resurface condition) / Bookmark.
   All write ledger entries.
6. **No-execution guarantee.** No code path from any verb to any
   external side effect.
   - [ ] Negative test: every verb on every card type → zero outbound
     calls except graph/ledger writes.
7. **Spend caps.** Per-run and per-day Firecrawl budget; per-watchlist
   off switch. Caps halt fetching, never hide fetched rows.
   - [ ] Cap breach mid-run → run halts, partial results labeled,
     honest error to Trace (no-bluff).

### P1 — Fast follows

8. Scheduled runs (daily cron per watchlist; failures saved honestly).
9. Deepen verb (scoped follow-up Scrape/Map; attaches to same row).
10. Clarify verb (plain-English rule-fit reasoning; weak reasoning
    logged for precision stats).
11. Hold resurfacing (date reached or keyword recurs → row returns).
12. Source-card viewer (click Sources count → provenance panel).

### P2 — Design for, don't build

13. Scout registry: conformance-gated entry, precision-pruned exit;
    per-scout Pass-rate stats.
14. Budget + spend dashboard in Analysis rail.
15. Understood cross-feed: Pursue outcomes → life-data extractions
    (Work/Ambition/Purchase) → correlation layer measures whether the
    system changes the life.

## Success Metrics

**Leading (first 14 days):**
- 10+ accepted Discernment Rules (week 1).
- 100% of rows cite ≥1 R-ID and ≥1 resource (SHACL-enforced; a miss is
  a bug, not a metric).
- 0 duplicate-resource rows on the Board.
- 0 spend-cap breaches without honest Trace errors.

**Lagging (30–90 days):**
- Clear Sign: ≥1 one-hour session → manual-miss Pursue; then ≥1/month.
- Adam's research hours down; Board sessions bounded and chosen.
- Prune list live: ≥1 scout retired or retargeted on precision stats.

## Open Questions

- **(Adam — RESOLVED BY DEFAULT 2026-07-04, overridable)** Watchlist #1:
  **the personal-data platform beat** — export shutdowns, API changes,
  and pricing moves across journaling, health, and self-tracking apps;
  migration vacuums the Understood Suite can absorb. Adam may replace
  this sentence at any time; scout #1 retargets on his word.
- **(Adam — RESOLVED BY DEFAULT 2026-07-04, overridable)** The 10 draft
  rules enter the queue **as-is**; Sometimes/No does the editing. The
  wording that survives Adam's clicks is the authority.
- **(Codex, non-blocking)** Triage LLM: Hermes local vs. Claude API for
  the rule-matching pass (cost vs. quality, ~50 docs/run).
- **(Codex, non-blocking)** Board home: Harness-native table is
  primary; optional Notion mirror as P1 export?
- **(Codex, non-blocking)** Hold-resurface conditions: frontmatter vs.
  ledger vs. graph.

## Phasing

- **Phase 0 — no code.** Rules through the queue. Watchlist sentence
  in force (default above). Codex drafts both SHACL shapes against the
  golden fixtures.
- **Initial Codex build.** P0 items 2–7. Tests green, committed per
  slice. Acceptance = the FOR ADAM test above.
- **Next expansion.** P1 items 8–12.
- **After the Clear Sign fires.** Fleet: conformance-gated
  entry, precision-pruned exit. If precision is bad, fix rules — never
  volume.

## Standing rules extended (append to agent onboarding)

- Scouts propose; no agent executes, spends, trades, contacts, or
  commits.
- Frontmatter is a claim, not a credential. `trust_level` is clamped at
  ingestion, always.
- Every emitted card is envelope-conformant or the bouncer blocks it.
- `resource` dedup runs before anything reaches the Board.
- Pursue is itemized authority; bulk operations may Pass, never Pursue.
- Spend caps are kill switches. Raising them is an Adam decision,
  logged. Row caps do not exist; reintroducing them is an Adam
  decision, logged.
