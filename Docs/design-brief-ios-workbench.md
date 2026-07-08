# Design Brief — The iOS-Building Cockpit

**Status:** synthesized 2026-07-08 by a 9-agent panel (3 readers, 3
designers, 3 judges) from the aptitude profile, the ontology CONTENT
(adam-axioms, adam-beliefs, adam_pattern, leverage-disposition), the
Working Patterns doc, and SOUL.md. Winner: belief-first design (2 of 3
judges), with grafts. Artifact: full-screen mockup published in session
(claude.ai/code/artifact/1bb1be7b-ec2b-4d88-a6f1-454164a38295).
**View name pending Adam's word** — "Blueprint" is a placeholder and is
NOT in the vocabulary.

## The one-line contract

Adam's entire interface to building an iOS app: **speak sentences,
rate four numbers, press Continue.** The system holds the
architecture; he never does.

## The screen (five regions)

1. **Step Rail** (top, tan band): the 8 Adam Pattern steps verbatim.
   Cells 1–4 show evidence ratings as isolated numbers; cells 5–8 at
   45% ink, LOCKED until all four ≥ 7 — enforced by the existing SHACL
   shapes against Fuseki, not UI convention. Kill Switch readout lives
   permanently in the bar above ("live — $4.10 of $25").
2. **Sources pool** (left, unlabeled): recognition-only capture —
   voice memos, screenshots, belief cards with kickers. Approved
   mockups and shipped screens recirculate back in as cards.
3. **Delegate** (center): three fixed composer fields — "What do I
   want?" / "When I am...I like to" (PreferredApproach arrives as a
   recommended default + Change) / "Done looks like..." — per
   conn-004 "Delegation is three sentences" (0.9). Below: ONE UP NEXT
   card, leverage-score ordered (never reordered while visible), with
   a paired **case-against card** — an agent argues why this is still
   Step 1; Adam rates the dispute, not the pitch.
4. **Organize** (right): exactly Slide Deck / Mind Map / Audio. The
   Mind Map is the plan of record AND the only navigation. Audio on
   every deliverable (Tonal 60 / Pitch 65 / Rhythm 55 — the untapped
   cluster).
5. **Ledger strip** (bottom, navy): spend vs cap, runs, "shipped this
   week: n", and a **fleet row per LIVE app** (crash %, review status,
   cert days) — life after ship has a surface.

## The loop (stages = steps, 1:1)

0 Capture (his sentence is the title, forever) → gate card "Would a
major tech company offer to buy this from me?" → 1 Context / 2 Circle
/ 3 Close the Gap / 4 Choose Success (each: one slide or map + audio;
his one act = rate 1–10; ambiguous Done-sentences are disambiguated by
building BOTH readings — example before definition, never paraphrase)
→ gate unlocks → 5 Code the Pattern (2–3 parallel builder attempts per
screen, eval-picked; breaker agent's kill-count as a numeral; forks
never asked — reversible default built, Hold logged with return
condition) → 6 Create Kill Switch (one card of numbers, Save) →
7 Clear Sign of Success (per-sentence video pairs Pass/Fail; nothing
ships un-Passed; TestFlight upload ONLY on Adam's Pursue; unprompted
signals logged verbatim as quote cards) → 8 Compound (Add registers
the build as a named routine; store outcomes — crashes, deletions —
feed the next Context so it compounds on what worked, not what was
easy to approve).

## Stack (all already his)

SwiftUI + template repo; Theme.swift + SavyComponents as a SwiftPM
package every generated app imports (taste enforced by compiler);
Supabase via connected MCP (get_advisors → numbers on evidence cards);
Fuseki/SHACL/SPARQL unchanged as authority; builders = Claude Agent
SDK + Codex CLI parallel, Grok scans, Hermes drafts (existing Backend
cases); xcodebuild/simctl/fastlane pilot — ASC key held by Harness,
never an agent; "what the app remembers" plain-noun table as the one
visible data-layer artifact.

## The honest risk

A screenshot proves a screen renders, not that the data layer is
right, and this design removes the surfaces where such defects show.
Four guards: breaker kill-count numeral, advisor numbers on cards,
per-sentence video gates, case-against cards. The tell: the week the
breaker reads zero everywhere is the week to distrust everything.

## v3 — the Cezanne pass (2026-07-08, from Adam's perception diagram)

Adam supplied the Cezanne transactional-perception diagram (perception
= integration of purpose, expectancy/assumptions, past experience,
anchored at point-of-view; stimulus channels: position, size, overlay,
hue, brightness, motion) and asked how those visual/psychological
principles would improve the cockpit. Finding: the v2 layout already
mirrors the diagram (composer = point-of-view anchor, Step Rail =
action/purpose, FASCINATION = expectancy/assumptions, pool = past
experience). v3 applies the technique:

1. **Color modulation replaces borders** — warm advances (the decision
   card is the warmest surface), cool recedes (locked steps, shipped
   cards, failed nodes cool to grey-blue). Depth = temperature.
2. **Dual viewpoints** — Mind Map is the plan view, Slide Deck the
   front view of the SAME build; the active object is warm in both.
3. **Binocular vision** — the case-against card physically overlaps
   behind every pitch; ambiguous Done-sentences render as two
   overlapped readings to pick between.
4. **Tilted planes** — the fleet ledger is a plane tilted up into the
   canvas (rotateX), the operational background rising to the picture
   plane instead of hiding in a drawer.
5. **The stimulus contract** (now a spec table in the artifact):
   POSITION=priority, SIZE=importance, OVERLAY=belonging,
   HUE=temperature/state, BRIGHTNESS=recency, MOTION=aliveness only
   (one breathing dot; nothing else ever moves).
No modal ever hides the canvas; the eye is meant to wander — Adam:
"The chaos is soothing."

## v4 — the Lichtenstein ink (2026-07-08, Adam's idea, verbatim)

> "I wonder in Roy Lichtensteins heavy black lines (in my case red
> lines) could be added to create an artificial color harmony (in my
> case is could force design harmony, even with titled boxes)."

Lichtenstein's own justification (Coplans interview): outlines existed
"partially for visibility and partially because the colors didn't
separate very well. You could use the outlines to 'fudge' over the
incorrect color registration." The tilted/overlapping v3 planes ARE
deliberate misregistration; one uniform contour harmonizes them.

Rules added on top of v3:
1. **LINE joins the stimulus contract as a seventh channel** — form,
   never state. Uniform crimson contour (2–3px) on every object, same
   weight everywhere. Because the line carries no meaning, every
   other channel can.
2. **Benday dots = positionless ground.** Navy dot-field on the
   canvas (the "sky"), grey dots on the cooled past and locked steps
   (printed, not painted), crimson dots on the navy tilted ledger
   (the Sunrise water).
3. **Mock insensitivity** — state collapses to exact tokens (live /
   pending / failed, never "sort of"); adjustment via size, shape,
   juxtaposition only.
4. **Programmed surface** — soft shadows removed; flat fills only.
   "I want my painting to look as if it had been programmed. I want
   to hide the record of my hand" — literal for agent-painted
   screens.
Suite precedent: navy already does the work of black in SAVY/Harness
(Lichtenstein's "free color" economy), and SAVY's quote card already
carries the crimson bar — v4 promotes the house accent to the
universal contour.

## The FASCINATION layer (added 2026-07-08, Adam's idea, verbatim)

> "I could envision another layer below the Adam Pattern boxes at the
> top of the screen. It would contain cards of the concepts currently
> holding my fascination." "The layer just below the Adam Pattern
> would likely be so many, that a carousel feature may be the answer
> to how it's presented."

A horizontal carousel band directly under the Step Rail: cards of
current fascinations (book concepts as quote cards with the crimson
bar, his own captured observations dated and attributed to ADAM).
Content obeys the note rule — his words or verbatim quoted sources
only. Seed cards shipped in the mockup: the Atomic Habits systems
quote (verbatim: "You do not rise to the level of your goals. You
fall to the level of your systems."), the four steps to create a
habit, his "That's odd." not "Eureka!" observation, the Bitter
Lesson line, the menu metaphor, the NotebookLM principle.

## Adam's verdict on the design (2026-07-08, verbatim)

> "I like the design. The chaos is soothing."
> "if all of the notes were constrained to only my written or
> transcribed words, this could really work for me."

**Design consequence (hard rule):** every note surface in the cockpit
— pool card labels, review notes, Change attachments, anything called
a note — contains ONLY Adam's written or transcribed words, or a raw
image. Agent-authored language exists solely inside generated
artifacts (slides, map status words, audio narration) and the closed
vocabulary. This extends `adams-words` from titles and DoneConditions
to the entire note layer.

## Open items for Adam

1. His word for the view name ("Blueprint" is a placeholder).
2. Confirm the fleet-row numbers he wants (crash %, review, certs).
3. First build to run through it end-to-end.
