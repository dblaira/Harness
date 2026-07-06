---
name: preserve-the-actual-words
description: "Adam: 'I need to find a way to preserve the actual words that represent the connection that I made.' Never reword what Adam said. Derived tasks must be titled with his exact words from the source transcript; agent restatements live only in separate, clearly labeled fields. Applies whenever an agent decomposes, retitles, summarizes, or reports on anything Adam said or wrote."
---

# Preserve the Actual Words

Skill name and every rule below come from Adam's own words. Agent-coined
terminology in this file is quarantined in the "agent terms" section at
the bottom — the same rule this skill enforces.

## In Adam's words (canonical, unedited)

> "The actual order of the word spoken, even if they're not grammatically
> correct. Even if they don't paint an accurate picture of what I'm
> feeling, they are the symbols and the characters and the graphics, if
> you will, of how it blends together in the moment."

> "Each specific level or signpost or location along the journey does
> have a complete feeling to it. And that should not be tampered with or
> adjusted in any way, or especially in the beginning, I could lose the
> whole thing."

> "The few words that I use automatically access that part of my psyche
> to where I can recall and judge properly."

## The rules

1. **The transcript is immutable.** Store Adam's full original utterance
   unmodified — grammar errors, run-ons, filler included. Never clean it
   up in place.

2. **His actual words title everything.** Every derived task, delegation,
   or research thread is titled with a contiguous quote of Adam's own
   words (roughly 3–8 words) from the span that generated it. Keep his
   word order even if not grammatically correct.

3. **Agent rewording is quarantined.** If an agent needs its own
   restatement (sub-agent handoff, search queries), it lives in a
   separate, clearly labeled field — never replacing his words, never
   displayed as the primary label.

4. **Judging runs against his words.** Reports lead with his quoted words
   and reference the source span, so Adam can "recall and judge properly"
   against the original connection — not against an agent's rewording.

5. **"Especially in the beginning."** The newer the idea, the stricter
   the rule. A fresh connection tolerates zero rewording.

## Extraction protocol

- Prefer phrases Adam emphasized, repeated, or coined — novel word
  combinations are the strongest keys.
- Never "fix" his phrasing inside a quote. "Build homes, not power
  plants" stays exactly that.
- If a derived task has no source span (agent-inferred dependency), mark
  it explicitly as agent-originated so it never masquerades as Adam's
  connection.

## Rewrites (bad → good)

- Title: "Prediction markets as live signal" → the exact words Adam
  spoke that spawned it (agent's restatement moves to the labeled field).
- "Rewrote your notes into 12 actionable tasks" → "12 tasks, each titled
  with your words; my restatements are in the labeled field."
- Cleaning the transcript before storage → storing raw; cleaned copies
  are derived and link back.

## Harness eval: `preserve-the-actual-words`

Deterministic check, same family as `no-time-estimates`:

- FAIL if a derived item's title shares no contiguous 3+ word span with
  its source transcript (case- and punctuation-insensitive).
- FAIL if the stored source transcript differs from the original
  utterance.
- PASS with note if agent restatements exist only in separate labeled
  fields and every displayed title quotes Adam.
- Record in EvalResult; show in Trace.

## Ontology hook

Belief candidate: `adam-pattern#PreserveTheActualWords` — "The few words
Adam uses automatically access the connection; derived artifacts must
quote them, never reword them." Enforce through the same Authority
channel as `EnforceStepNaming`.

## Agent terms (quarantined)

Terms an agent coined while building this skill, kept out of the rules
above: "verbatim anchor," "anchor phrase," "agent_gloss," "retrieval
cue," "encoding specificity." Useful for lookup; not Adam's words.
