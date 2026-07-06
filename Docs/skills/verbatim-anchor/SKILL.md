---
name: verbatim-anchor
description: Preserve Adam's original words verbatim through every delegation and decomposition. Rewording severs his retrieval cues. Derived tasks must be titled with exact quotes (anchor phrases) from the source transcript; agent paraphrase may exist only in separate, clearly labeled fields. Applies whenever an agent decomposes, retitles, summarizes, or reports on anything Adam said or wrote.
---

# Verbatim Anchor

## Why this exists

Adam's inspiration arrives all at once, prepackaged in a specific
combination of connections, and that combination is encoded in the exact
words he spoke — "the symbols and the characters and the graphics of how
it blends together in the moment." Those words are retrieval cues
(encoding specificity principle): reading them re-activates the full
connection in his psyche, including the parts he could never explicitly
state.

A paraphrase — even a clearer, more grammatical, more accurate one —
carries the gist but severs the cue. Adam looks at the reworded item and
has no connection to it. He cannot recall the original inspiration, so he
cannot grade the agent's results against it. Especially in the early
stages of an idea, rewording can cost him the whole thing.

The insight will evolve as Adam deepens it, and that is fine — but each
signpost along the journey has a complete feeling that must not be
tampered with. Evolution is Adam's move, never the agent's.

## The rules

1. **The transcript is immutable.** Store Adam's full original utterance
   (voice transcript, message, note) unmodified — including grammatical
   errors, run-ons, and filler. Never clean it up in place. It is the
   canonical artifact every derived item points back to.

2. **Anchor phrases title everything.** Every derived task, delegation,
   research thread, or work item must be titled with a contiguous quote
   of Adam's own words from the source — roughly 3–8 words, chosen from
   the span that generated that item. Keep his word order even if it is
   not grammatically correct.

3. **Paraphrase is quarantined.** If an agent needs its own restatement
   (for sub-agent handoff, search queries, or clarity), it lives in a
   separate, clearly labeled field (e.g. `agent_gloss`) — never replacing
   the anchor phrase, never displayed as the primary label.

4. **Grading runs against the origin.** When reporting results back,
   lead with the anchor phrase and reference the source span, so Adam
   judges the work against his original inspiration — not against an
   agent's rewording of it.

5. **Early-stage strictness.** The newer the idea, the stricter the rule.
   A fresh connection tolerates zero rewording; a mature, already-deepened
   thread may carry more agent structure around the anchors.

## Anchor extraction protocol

- Prefer the phrases Adam emphasized, repeated, or coined — novel word
  combinations are the strongest cues.
- Never "fix" his phrasing inside an anchor. "Build homes, not power
  plants" stays exactly that.
- If a derived task genuinely has no source span (an agent-inferred
  dependency, for example), mark it explicitly as agent-originated so it
  never masquerades as Adam's connection.

## Rewrites (bad → good)

- Title: "Prediction markets as live signal" → Title: the exact words
  Adam spoke that spawned it, e.g. "the market already voted on this"
  (gloss field may hold "prediction markets as live signal").
- "Rewrote your notes into 12 actionable tasks" → "12 tasks, each titled
  with your words; my restatements are in the gloss column."
- Cleaning the transcript before storage → storing raw, cleaning only in
  a derived copy that links back.

## Harness eval: `verbatim-anchor`

Deterministic check, same family as `no-time-estimates`:

- FAIL if a derived item's title shares no contiguous 3+ word span with
  its source transcript (case- and punctuation-insensitive match).
- FAIL if the stored source transcript differs from the original
  utterance.
- PASS with note if agent paraphrase exists only in separate labeled
  fields and every displayed title is an anchor phrase.
- Record in EvalResult; show in Trace.

## Ontology hook

Belief candidate for the graph: `adam-pattern#OriginalWordsAreCanonical` —
"Adam's original words are canonical retrieval keys; derived artifacts
must quote them, never paraphrase them." Enforce through the same
Authority channel as `EnforceStepNaming`.
