# PLAN — Blueprint Cockpit v1 (macOS)

**Status:** planned 2026-07-08, grounded by a 5-agent codebase sweep
(run `wf_c364f9c0-cd9`; full evidence in the workflow journal).
Design source: `design-brief-ios-workbench.md` (v6 mockup approved:
"yep. That's it."). View name still pending Adam's word — `blueprint`
is the code-level placeholder only.

## The honest answer first

**Yes — this can actually work.** It is two projects wearing one
design:

- **Project A (the cockpit UI): mostly days-distance recombination.**
  The switcher seam, SAVY components, the 8 pattern steps with the
  exact 1–4/5–8 zone split, the leverage formula, all four decision
  verbs, the Kill Switch numbers, and even the three composer
  placeholder strings already exist in the repo.
- **Project B (the SHACL lock + the build loop): the two central
  promises have zero executing code today.** The gate exists as
  unexecuted TTL (`adam_pattern.ttl:99-121`) plus a keyword heuristic
  (`RunEvaluation.swift:86-98`). The build loop has no substrate at
  all (zero hits for simctl/fastlane/XCUITest/ASC keys).

The killer risk is not effort but HABIT: every existing Fuseki caller
**fails open** (`GraphHealth.swift:33-35` counts Fuseki-down as pass)
and existing evals pass on keyword matching. Copying those habits
produces a cockpit that looks enforced while enforcing nothing — the
exact flattery failure the design exists to prevent.

## Hard rules for every phase

1. **The gate fails CLOSED.** Fuseki unreachable → cells 5–8 stay
   locked. Mandatory fallback read of local `accepted-graph.ttl`
   (write target of `ReviewQueueStore.swift:348-360`).
2. **No new Process code.** Every shell-out goes through the
   already-fixed `AgentRunner.shell()` (background drains, timeout
   with partial output — `AgentRunner.swift:589-628`). The 1MB
   `/bin/cat` test is the acceptance test for any new caller.
3. **A Pass is invalid without an artifact.** Extend `EvalResult`
   (GRDB, `BackendModels.swift:254-268`) so verification rows must
   carry an on-disk artifact path (screenshot/video). Never copy the
   keyword-match eval pattern.
4. **Dissent is agent speech.** The case-against card is the ONE
   surface that is explicitly not Adam's words — render it as
   `SavyDarkCard`, never let it feed titles or verbatim fields.
5. **Existing switcher navigation stays** until the Mind Map earns
   navigation through daily use.

## Phase 0 — Preconditions + the gate spine

*The lock gets built before any cockpit UI, so everything binds to
real graph state from day one.*

- **WO-A — Fix the send-path stall (recovery-plan WO-3, confirmed
  NOT fixed).** `MemoryRetrieval.swift:45-185` still synchronously
  reads up to 1,500 iCloud files per send (on path at
  `HarnessRunService.swift:201-204`). Skip non-downloaded items,
  256KB cap, wall-clock budget, duration trace.
  *Test: send with a cold vault completes without the scan on the
  critical path.*
- **WO-B — Fix fresh-machine builds (WO-6a/6b, confirmed NOT
  fixed).** `scripts/sync-ontology.sh:11-14,29-32` exits 1 without
  the iCloud folder; evidence-ingest path hardcoded. Warn-and-continue
  + honor `ONTOLOGY_ACCEPTED_DIR` everywhere.
  *Test: `xcodebuild build` succeeds on a machine with no iCloud.*
- **WO-C — StepEvidenceRatingShape.** New SHACL shape in
  `Ontology/shapes/connection-shape.ttl` (1–10 range, one rating per
  step, evidence note). The python validator
  (`scripts/validate_connection_turtle.py`) picks up new shapes with
  zero script changes.
  *Test: rating 11 is rejected; rating 7 with note validates.*
- **WO-D — PatternEvidenceStore.** Clone the proven turtle-emit →
  SHACL-validate → append `accepted-graph.ttl` → POST Fuseki path
  from `ReviewQueueStore.decide` (`ReviewQueueStore.swift:274-328`).
  Stores Adam's step ratings as graph claims.
  *Test: a rating round-trips app → validator → accepted graph →
  SPARQL read.*
- **WO-E — PatternGateChecker (fail-closed).** Clone the SPARQL
  read/parse from `FusekiGraphHealthChecker` (`GraphHealth.swift:76-160`)
  but invert the failure semantics; regex fallback over local
  `accepted-graph.ttl` (pattern at `OntologyLoader.swift:76-91`).
  Preflight the python venv like `AgentRunner.preflight` does
  backends; surface Fuseki/venv state in the existing status band.
  *Test: Fuseki stopped → gate reads LOCKED; local file present with
  four ≥7 ratings → gate reads OPEN.*

## Foundation — Shell, rail, and the visual language

- **WO-F — MacBlueprintView shell.** `case blueprint` in
  `WorkbenchCenterView` (`MacChatView.swift:3235`), branches in
  `centerViewContent` (`:375-388`) and `centerViewTitle` (`:1648`),
  new file `Sources/Harness/MacBlueprintView.swift` under
  `#if os(macOS)` (MacChatView is a 3,320-line monolith — never add
  inline). Widen the two 182pt Picker frames (`:1453`, `:1539`);
  check CaseIterable assertions in tests.
  *Test: the switcher shows the new view; @SceneStorage persists it.*
- **WO-G — Step Rail bound to the gate.** 8 cells from `PatternStep`
  (`Models.swift:23-28`, steps at `OntologyLoader.swift:63-72`);
  ratings entered on cells 1–4 write via PatternEvidenceStore; cells
  5–8 render locked from PatternGateChecker only.
  *Test: rate 8/7/9/8 → cells 5–8 unlock; kill Fuseki and delete the
  local file → they re-lock.*
- **WO-H — The v6 ink.** Two reusable pieces in
  `SavyComponents.swift`: a Canvas Benday-dot ground (`.drawingGroup()`)
  and ONE breathing dot (TimelineView). Mechanical pass: crimson
  2–3pt contours, cornerRadius 0, `rotationEffect` card tilts. Ledger
  tilt = trapezoid Shape background with un-tilted rows (never
  rotation3DEffect on a data table).
  *Test: side-by-side with the v6 artifact; motion limited to the one
  dot; reduced-motion respected.*
- **WO-I — FASCINATION carousel.** `SavyQuoteCard`/`SavyStoryCard`
  (`SavyComponents.swift:112-282`) in a horizontal ScrollView with
  ±2–4° tilts; cards sourced from .md files in the watched folder
  (pattern at `MacWorkbenchModel.swift:290-295`).
  *Test: drop a quote .md in the folder → card appears with Adam's
  words verbatim.*

## Buildout — Composer, decisions, ledger

- **WO-J — Three editable fields.** Placeholders already exist
  verbatim (`MacDelegateFormView.swift:155`, `MacChatView.swift:552-556`);
  make fields 2–3 editable and thread through
  `ComposerIntent.composedPrompt` (`ComposerIntent.swift:59-68`).
  *Test: a delegation carries Intent + PreferredApproach +
  DoneCondition, each verbatim.*
- **WO-K — Voice, additive.** `com.apple.security.device.audio-input`
  entitlement + usage string in `project.yml` FIRST, then
  SFSpeechRecognizer appending the raw transcript untouched.
  *Test: spoken sentence lands character-for-character in the field.*
- **WO-L — UP NEXT + case-against.** Top `OpportunityBoardRow` by
  the existing priority (`OpportunityScoutCards.swift:104-108`) as
  one card with the existing verb bar (`MacChatView.swift:1230-1272`);
  never reorder while visible. Dissent = new `case_against`
  frontmatter from the triage prompt, rendered as `SavyDarkCard`.
  *Test: exactly one decision visible; dissent visually marked as
  agent speech; Pursue still primes the composer
  (`MacChatView.swift:1405-1416`).*
- **WO-M — Fleet ledger v1 (flat).** Read
  `delegationAgentCreditsUsedToday()` vs caps
  (`MacWorkbenchModel.swift:46-54,1483-1536`) + RunLedgerStore counts;
  "shipped this week" seeded from Pursue ledger actions. Kill Switch
  readout also joins the top bar.
  *Test: numbers match the GRDB ledger; spend updates after a run.*

## Phase 3 — Capture

- **WO-N — The pool.** Stop discarding `.sourceCard` rows
  (`MacWorkbenchModel.swift:320-322` keeps only `.opportunity`);
  render them as the unlabeled pool. Add `.dropDestination(for:)` +
  `onPasteCommand`. Capture-from-anywhere = the watched Delegations
  folder + a Shortcut (share-sheet → folder). Real Share Extension:
  v2. Voice memos: v2, rides WO-K.
  *Test: paste a URL and drop an image → two cards, no names, no
  folders; share from iPhone via Shortcut → card appears.*
- **WO-O — Mind Map as a VIEW.** Node model as markdown/turtle;
  read-only tree first (extend the `treeColumn` pattern,
  `MacCockpitView.swift:233-248`); node color = status. Navigation
  takeover only after it survives daily use.
  *Test: the current build renders as a tree whose warm node matches
  the UP NEXT card.*
- **WO-P — Audio briefs.** AVSpeechSynthesizer (zero AVFoundation in
  repo today) over existing text briefs, scheduled via the
  RoutineScheduler seam (`HarnessApp.swift:34`).
  *Test: a completed run produces a playable "what changed" brief.*

## Phase 4 — The build loop, smallest honest version

*This is a CI product hiding inside a UI ticket. v1 ships ONE spike:*

- **WO-Q — Build-and-screenshot spike.** One script: `xcodebuild
  build` + `xcrun simctl` boot/screenshot, executed through
  `AgentRunner.shell()` with `ONTOLOGY_ACCEPTED_DIR` exported
  (depends on WO-B). The PNG attaches to the run as the EvalResult
  artifact (hard rule 3). One builder, one screen, no parallelism.
  *Test: pressing the card's button yields a real simulator PNG on
  the evidence card.*
- **Sequenced after the spike, each its own project:** per-sentence
  videos (needs an XCUITest target — none exists), the breaker agent,
  parallel builders (ONLY after builder spend is under an extended
  Kill Switch — today's caps meter Firecrawl credits only; and note
  CLI backends are single-shot per `AgentRunner.swift:310-327`, so
  iterating builders must run API-path with the existing ToolExecutor
  bouncer), Supabase advisors in-app, and **fastlane/TestFlight last,
  manual-first, fired only from Pursue** — no Fastfile, no ASC key,
  and signing is disabled in `project.yml` today; TestFlight external
  review is a human-timescale Apple process regardless.

## Cut from v1 (each with its reason)

| Cut | Why |
|---|---|
| Mind Map as sole navigation | Bets navigation on the least-built component; switcher stays |
| macOS Share Extension | Watched folder + Shortcuts = 90% of capture for 5% of work |
| Slide Deck panel | Depends on build-loop evidence that doesn't exist yet |
| Per-live-app ops row | No telemetry source exists; stub the numbers |
| Parallel builders / breaker / videos / fastlane | See Phase 4 — sequenced, not abandoned |
| Voice-first (as a blocker) | Fields ship as text first; voice is additive (WO-K) |

## Verification of the whole plan

The requirement is the test: after the foundation is complete, Adam rates four cells and
watches 5–8 unlock — then we stop Fuseki and watch them lock again.
That single demo proves the design's soul is real. After the final build's
spike, one delegation ends with a genuine simulator screenshot on its
evidence card. Everything else is recombination of code that already
passes tests in this repo.
