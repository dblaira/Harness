# CLAUDE.md — Harness

**Active goal (approved 2026-07-08):** build the Blueprint Cockpit v1
per `docs/PLAN-blueprint-cockpit-v1.md`. Phase 0 (gate spine +
recovery fixes) comes before any cockpit UI. Design source:
`docs/design-brief-ios-workbench.md` (approved v6 visual).

Hard rules for that work, no exceptions:

1. The Adam Pattern gate **fails CLOSED** — Fuseki unreachable means
   steps 5–8 stay locked. Never copy the fail-open pattern in
   `GraphHealth.swift:33-35`.
2. Every shell-out goes through `AgentRunner.shell()`. No new raw
   `Process` code.
3. A verification Pass is invalid without an on-disk artifact path.
4. Adam's words are quoted verbatim, never paraphrased — "when you
   use your own words or add words to it, it loses all its meaning."
   Titles and notes are his words or nothing. Dissent cards are the
   one agent-speech surface and must be visually marked as such.
5. Words, colors, and icons come from `docs/design-vocabulary.md`.
   New needs go back to Adam as one question.

The law: "Agents propose. The bouncer checks. You decide. No agent
ever spends, trades, contacts, or commits to anything." (SOUL.md —
the vault copy wins.)

Cognitive constraints for every screen and message:
`docs/design-constraints-cognitive.md`.
