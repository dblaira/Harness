# Cognitive Design Constraints — Harness

Source: Johnson O'Connor aptitude profile (Adam Blair, #327815-14).
Canonical skills this defers to: `cognitive-fit`,
`articulate-leadership-communication`, `no-time-estimates`,
`requirement-is-the-test` (in `Docs/skills/`). Where wording overlaps,
those skills win the phrasing. Adam's words are quoted verbatim, per
`adams-words`: "When you use your own words or add words to it, it
loses all its meaning."

## The constraint, in Adam's words

> "my high numeric and clerical talents (Graphoria, Numerical
> Reasoning) are currently bottlenecked by the cognitive friction of
> organizing complex abstract structures (Structural Visualization,
> Analytical Reasoning) and tracking detailed parameters (Number
> Memory)."
> — Adam, 2026-07-06

## The numbers (Johnson O'Connor percentiles)

| Aptitude | %ile |
|---|---|
| Number Facility | 85 |
| Numerical Reasoning | 75 |
| Graphoria | 70 |
| Inductive Reasoning | 60 |
| Analytical Reasoning | 13 |
| Structural Visualization | 5 |
| Number Memory | 5 |

## What Harness must do about it

The system removes the friction Adam named; Adam supplies the judgment.

1. **Organizing complex abstract structures** is the system's job —
   flows arrive pre-sequenced: numbered steps, checklists, one
   decision per screen. Never require holding the architecture in
   mind.
2. **Tracking detailed parameters** is the system's job — every value
   (keys, backends, limits, statuses) is shown at the moment of use.
   Requiring recall of a value set earlier is a defect.
3. **Output feeds the high aptitudes** — format routing per
   `cognitive-fit`: Tables for exact value lookup, Matrices for
   cross-referencing, Node Trees for hierarchy and flow, Pure Text
   only for interpretation. Response layout per
   `articulate-leadership-communication`.

## The acceptance question

Per `requirement-is-the-test`, for every screen, error message, and doc:

> Does this require organizing a complex abstract structure in mind,
> or recalling a detailed parameter?

If yes, it fails. Move that load into the UI.

## Applied to the recovery plan (`harness-usability-recovery-plan.md`)

- WO-2 (per-backend Keychain): the app tracks the keys, not Adam.
- WO-4 (readiness indicators, honest status): the app shows backend
  state at the moment of use.
- WO-5 (auto-select working backend): the app does the sequencing.
- Error messages name the fix ("run `codex login`"), never just the
  failure.
