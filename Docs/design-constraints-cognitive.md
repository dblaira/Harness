# Cognitive Design Constraints — Harness

Source: Johnson O'Connor aptitude profile (Adam Blair, #327815-14).

## The one rule

**Adam is never the component that remembers state or sequences steps.
The system carries the structure and every parameter; Adam carries the judgment.**

## Why (the numbers)

| Aptitude | %ile | Implication |
|---|---|---|
| Number Facility | 85 | Feed him numbers — he's fast |
| Numerical Reasoning | 75 | He spots data patterns instantly |
| Graphoria | 70 | Dense scannable grids beat prose |
| Inductive Reasoning | 60 | Give facts; he connects them |
| Analytical Reasoning | 13 | System does the sequencing, not Adam |
| Structural Visualization | 5 | Never require holding architecture in his head |
| Number Memory | 5 | Never require recalling a value — re-display it |

## Three translations

1. **Externalize structure** — every flow arrives pre-sequenced: numbered
   steps, checklists, one decision per screen. Never "here's the system,
   figure out the order."
2. **Externalize parameters** — show every value at the moment of use
   (keys, backends, limits, statuses). "As configured earlier" is a bug.
3. **Dense, scannable output** — tables and status grids over paragraphs.
   Short prose only for the "so what."

## The acceptance question

For every screen, error message, and doc:

> Does this make Adam hold a structure in his head or remember a value?

If yes, it fails. Move that load into the UI.

## Applied to the recovery plan

- WO-2 (per-backend Keychain): app remembers keys, not Adam.
- WO-4 (readiness dots, honest status): app tracks backend state visibly.
- WO-5 (auto-select working backend): app does the sequencing.
- Error messages must name the fix ("run `codex login`"), never just the failure.
