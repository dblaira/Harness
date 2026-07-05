---
type: feature_spec
title: Delegation Agents v1.2 — The Cockpit, the Envelope, the Fleet Contract
created: 2026-07-05
supersedes: SPEC-opportunity-scouts-v1.1.md
status: approved — language-alignment revision of approved v1.1, recorded 2026-07-05; no law changed
owner: Adam Blair
builds_on: Harness review queue, SHACL bouncer, Firecrawl adapters, run ledger, Cockpit (dc9b893)
approved_visual: Notion — "Opportunity Board — Row Schema Preview (SPEC v1.1)" (schema approved there; names updated here)
trust_level: proposal — nothing here enters /accepted without the queue
---

# Delegation Agents v1.2

## FOR ADAM (read this, skip the rest if you want)

**What changed since v1.1 — one thing: the words are now yours.**

Every law, cap, guard, and test from v1.1 stands unchanged. What died is
the invented vocabulary. The app already speaks Understood Suite words
(commit `dc9b893`); this spec now matches the app.

| v1.1 said | v1.2 says (your word) |
|---|---|
| Opportunity card | **Delegation** (`type: delegation`) |
| Opportunity Board | **Delegation Queue** |
| Band (Now / Hold / Out) | **App** (News Calm / Notorious Recall / Understood / SAVY) |
| Now-band push cards | **Nudge** — timing edges interrupt; everything else waits |
| Scan / Now / By Band views | **All / By App** views |
| Scout | **Agent** (the fleet; `scout_id: agent-…`) |
| Card cap → spend cap | **Kill Switch** (Pattern step 6, named as such) |

**The mental model:** Harness is the cockpit — it begins the work and owns
brainstorming, orchestration, delegation, evidence, provenance, the review
queue, and the fleet ledger. The Suite apps hold what agents bring back,
by maturity: News Calm (mild curiosity, unfamiliar domains) → Notorious
Recall (crossed threshold, research questions, delegations) → Understood
(understood enough to act) → SAVY (mature, leveraged, compounding).

**Your test when the build says Phase 1 is done:** press "Run agent" →
delegations appear in the Queue, deduped by resource, every one citing
R-IDs and ≥1 source → sort by Priority, sweep-Pass a batch, Pursue one →
Pursue wrote a single itemized ledger entry, Pass wrote batch entries →
a file declaring `trust_level: accepted` displays as supporting memory
with "self-declared label ignored" → Trace shows queries, spend, and
delegations emitted. Zero external side effects from any verb.

**The law, unchanged:** *Agents propose. The bouncer checks. You decide.
No agent ever spends, trades, contacts, or commits to anything.*

---

## The Adam Pattern, mapped onto this feature

1. **Context / 2. Circle** — agents watch the world (Firecrawl); what they
   find lands as News Calm–grade curiosity or crosses a threshold.
3. **Close the Gap** — Deepen verb (P1): scoped follow-up research on one
   delegation.
4. **Choose Success** — your Discernment Rules (R-01…R-n) in `/accepted`
   ARE the precise targets; every delegation must cite the rules it fits.
5. **Code the Pattern** — the envelope + Queue + verbs: one repeatable
   system, built once, reused by every agent.
6. **Create Kill Switch** — spend caps. Per-run and per-day budget,
   per-watchlist off switch. Raising a cap is an Adam decision, logged.
7. **Clear Sign of Success** — one hour in the Queue → ≥1 Pursue you'd
   never have found manually.
8. **Compound** — the fleet: agents #2–#100 enter by schema conformance,
   get pruned by your Pass-rate. Precision stats compound; volume never
   substitutes for them.

## Problem Statement (unchanged)

Adam's highest-value skill (discernment) is spent on his lowest-value
activity (fetching). The scarce resource is not scanning bandwidth —
bulk scanning is his native format (Graphoria 70th, Number Facility
85th) — it is his *authority*: decisions that write to the ledger.
Uncap the data; keep authority itemized.

## Goals

1. **Taste as authority.** ≥10 Discernment Rules through the queue into
   `/accepted`, citable as R-01…R-n.
2. **Queue live.** Agent #1 emitting deduped, rule-cited delegations
   into the Delegation Queue.
3. **Clear Sign of Success.** One hour in the Queue yields ≥1 Pursue
   Adam judges he would not have found manually.
4. **Zero authority leaks.** 0 delegations enter `/accepted`, 0 external
   actions, 0 self-declared trust labels obeyed. Verified by tests.

## Non-Goals

- **Auto-execution of anything.** Standing rule, not a version cut.
- **Autonomous promotion.** No delegation self-promotes.
- **OKF connector / bundle furniture.** Envelope adopted; ecosystem not.
- **Volume caps as safety.** Safety = Kill Switch (spend) + dedup + app
  placement. Reintroducing volume caps is an Adam decision, logged.
- **Livestream / realtime ingestion.** Post-fleet (P2+).
- **Paywalled / ToS-restricted sources.** Agents read what Adam could
  legally read in a browser.

## The Envelope (the fleet contract — laws unchanged from v1.1)

Every artifact an agent emits is a markdown file with YAML frontmatter.
OKF-conformant (only `type` required upstream; unknown keys tolerated).

**Envelope (all types):** `type` · `title` · `description` · `tags` ·
`resource` · `timestamp` · `trust_level`

**Payload `type: delegation`:** `opp_id` (DELEGATION-nnnn) · `fit` ·
`rules_hit` · `app` · `window_days` · `effort` · `dollar_order` ·
`attention` · `times_seen` · `sources` · `scout_id` (agent id)

**Payload `type: source_card`:** `retrieved_by` · `content_hash` ·
`linked_opportunities`

**Laws:**
- `trust_level` is a claim, never a credential. Ingestion clamps every
  file to supporting-memory ceiling; the self-declared value renders as
  metadata with "self-declared label ignored."
- `resource` is the dedup key. Same canonical resource → merge:
  `times_seen++`, `attention` recount, newest `timestamp`, history kept.
- SHACL keys on `type`. Delegation requires `rules_hit ≥ 1`,
  `resource ≥ 1`, `fit ∈ [0,1]`, `app ∈ {News Calm, Notorious Recall,
  Understood, SAVY}`. Source card requires `resource`, `retrieved_by`,
  `content_hash`. Malformed → blocked with a plain-English reason,
  graph untouched.
- Golden fixtures: `Tests/fixtures/OPP-0001.md` + `OPP-0001-source.md`
  (already in Suite language as of `dc9b893`).

## The Delegation Queue (primary view)

One dense grid, one row per deduped delegation. Numbers first. Machine
holds structure (persistent sorts, stable IDs, row history); Adam's eye
supplies recognition only.

- **Columns:** Delegation · ID · Arena · Fit · Rules Hit · $ Order ·
  Effort · Window Days · Attention · First Seen · Times Seen · App ·
  Sources · Agent · Priority.
- **Priority (default sort):** `fit × 50` if no window, else
  `fit × 100 / (window_days + 1)`.
- **Views:** All (default priority-sorted full queue) · By App.
- **Bulk-scan yes, bulk-authority no:** Pass and dismiss sweep
  (multi-row). Pursue is itemized — one click, one row, one ledger
  entry. The graph never takes bulk writes.

**Nudge (the push channel):** only delegations with `window_days` below
a per-watchlist threshold interrupt Adam. Everything else pools in the
Queue for his schedule. All Queue verbs also work on a Nudge.

## Requirements

### P0 — Must have (build state as of 2026-07-05)

1. **Discernment Rules in the graph.** Adam's, via existing queue;
   stable R-IDs; SPARQL-queryable from `/accepted`. *(Adam — pending)*
2. **Envelope + typed SHACL.** Parser, both shapes, trust clamp,
   dedup-by-resource. ✅ **Built** (`6f0a484`, renamed `dc9b893`);
   fixtures validate; clamp and dedup tested.
3. **The Delegation Queue.** Columns, All / By App views, Priority formula,
   persistent state, multi-row select. ✅ **Built** (`c45051f`, renamed
   `dc9b893`). Open detail: Hold captures no return condition yet.
4. **Agent run v1 (manual trigger).** "Run agent" → Firecrawl Search
   (+ Scrape shortlisted) → LLM triage citing accepted rules via live
   SPARQL → envelope files → Queue rows + Nudges → Trace saves queries,
   spend, delegations emitted, rules cited. ✅ **Built** — manual
   Search + top-source Scrape + selected-backend triage → rule-cited
   Delegation files → Queue refresh → Trace.
5. **Verbs.** Pursue (itemized) / Pass (bulk-able) / Hold (requires
   return condition) / Bookmark. All write ledger entries.
   ✅ **Built** except Hold's return condition.
6. **No-execution guarantee.** Negative test: every verb on every card
   type → zero outbound calls except graph/ledger writes. ✅ **Built**
   for manual agent run dependency path and Queue ledger verbs.
7. **Kill Switch (spend caps).** Per-run + per-day Firecrawl budget;
   per-watchlist off switch. Breach mid-run → halt, label partials,
   honest error to Trace. Caps never hide fetched rows. ✅ **Built**
   for manual agent run.

### P1 — Fast follows

8. Scheduled runs (daily cron per watchlist; failures saved honestly).
9. Deepen verb (scoped follow-up Scrape/Map; attaches to same row).
10. Clarify verb (plain-English rule-fit reasoning; weak reasoning
    logged for precision stats).
11. Hold return (date reached or keyword recurs → row returns).
12. Source viewer (click Sources count → provenance panel).

### P2 — Design for, don't build

13. Agent registry: conformance-gated entry, precision-pruned exit;
    per-agent Pass-rate stats. (The 12-agent launch set enters here.)
14. Budget + spend dashboard in the Analysis rail.
15. Understood cross-feed: Pursue outcomes → life-data extractions
    (Work/Ambition/Purchase) → correlation layer measures whether the
    system changes the life.

## Success Metrics

**Leading:** 10+ accepted Discernment Rules · 100% of delegations cite
≥1 R-ID and ≥1 resource (SHACL-enforced) · 0 duplicate-resource rows ·
0 Kill Switch breaches without honest Trace errors.

**Lagging:** Clear Sign of Success fires (≥1 one-hour session →
manual-miss Pursue; then ≥1/month) · research hours down, Queue
sessions bounded and chosen · ≥1 agent retired or retargeted on
precision stats.

## Decisions in force (overridable only by Adam)

- **Watchlist #1:** the personal-data platform beat — export shutdowns,
  API changes, pricing moves across journaling/health/self-tracking
  apps; migration vacuums the Understood Suite can absorb.
- **Rules:** the 10 drafts enter the queue as-is; Sometimes/No does the
  editing.

## Open Questions (non-blocking, builder's choice)

- Triage LLM: Hermes local vs. Claude API (~50 docs/run).
- Hold return condition storage: frontmatter vs. ledger vs. graph.

## Phasing

- **Phase 1 (in progress).** P0 items 2–7 are built. Remaining open
  details: Adam's 10 accepted rules and Hold return condition.
  Acceptance = the FOR ADAM test.
- **Phase 2.** P1 items 8–12.
- **Phase 3 — after the Clear Sign of Success fires.** The fleet:
  conformance-gated entry, precision-pruned exit. If precision is bad,
  fix rules — never volume.

## Standing rules (append to agent onboarding)

- Agents propose; no agent executes, spends, trades, contacts, or
  commits.
- Frontmatter is a claim, not a credential. `trust_level` is clamped at
  ingestion, always.
- Every emitted file is envelope-conformant or the bouncer blocks it.
- `resource` dedup runs before anything reaches the Queue.
- Pursue is itemized authority; bulk operations may Pass, never Pursue.
- The Kill Switch is spend caps. Raising them is an Adam decision,
  logged. Volume caps do not exist; reintroducing them is an Adam
  decision, logged.
- Speak Suite words. Banned: scan, now, band, stage, field app,
  surface, opportunity card, opportunity board. When a new word is
  needed, take it from Adam's apps — never invent one.
