# Design Brief — Harness macOS Layout (NotebookLM direction)

**Status:** v2, revised from Adam's answers 2026-07-07. Mockup shown in
session. Left panel confirmed unlabeled ("Nothing. No name.").
**Governed by:** `design-constraints-cognitive.md` (the constraint),
`design-vocabulary.md` (words/icons/colors), `adams-words` (verbatim),
`requirement-is-the-test` (acceptance).
**Scope note:** `SPEC-hermes-parity-v1.md` governs *capability and
personality* parity. Layout is decoupled — the Hermes layout was a
template, not a requirement, and this replaces it.

## The mental model, in Adam's words

> "I have this ontology and this knowledge graph that locks in my
> beliefs and my more important meanings and then I can add sources
> from online that I want to learn more about or I think that are
> valuable and then I can make request of that information."
> — Adam, 2026-07-07

> "Delegation was right in the middle and that is what this is all
> about."

> "I know. I'm just gonna hand it off. I'm gonna delegated and that
> makes me more ambitious."

> "I would have it look very, very similar to NotebookLM because I'm
> familiar with that and it makes sense to me."

## Why Hermes failed (unchanged from v1)

It is a recall interface. Per `design-constraints-cognitive.md`, the
load sits on the low aptitudes (Structural Visualization 5, Number
Memory 5, Analytical Reasoning 13). NotebookLM's shape passes the
acceptance question; every act is see-and-pick and the organizing is
generated output.

## The triptych (v2 — per Adam)

### Left — the pool. UNLABELED, per Adam: "Nothing. No name."
NotebookLM's Sources panel, Harness skin. NOT delegations — resources.
The panel carries no header word in the UI, ever. ("The pool" is a
docs-only referent; it never appears on screen.)

- Top: `"Add"` button + search bar. Nothing else above the pool.
- One flat list of captured resources: links shared from X, copied
  text, attachments, photos. In Adam's words: "kind of like Safari as
  a reading list or bookmarks."
- Capture from anywhere (macOS share sheet / clipboard) lands here.
- Icons from vocabulary only: `link`, `photo`, file/doc, `message`.

### Center — Delegate (the middle is the point)
Wide center. The composer is the app's heart: `"What do I want?"`,
with `"Done looks like..."` and the SAVY controls (`Pattern`, `Due`,
`Lift`, `Flag`). A source-count chip on the composer shows what the
request runs against. Requests are delegations over ontology +
sources — not queries. Replies check sources against the ontology and
say so.

### Right — `Organize` (exactly three outputs, this order)
Generated output only, never filed by hand. Adam: "no flashcards no
info graphic no short video summaries."

1. **Slide Deck** — "a slide deck like a PowerPoint presentation."
2. **Mind Map** — the node tree; tagline `"The map of leverage."`
   Format basis: `cognitive-fit` "Node Trees for hierarchy and flow."
3. **Audio** — "it could be a podcast. It could just be a voice
   transcription that I could generate so that I could just listen
   to it."

Vocabulary additions needed (Adam's own words, to be added verbatim
to `design-vocabulary.md` on his confirmation): "Slide Deck",
"Mind Map", "Audio". The left panel is deliberately unnamed —
no vocabulary entry, no UI label.

## Acceptance (the requirement is the test)

1. No screen requires remembering where anything lives.
2. Capture to the pool takes one gesture from outside the app.
3. Deleting everything in `Organize` loses nothing Adam typed —
   output, not storage.
4. Every delegation shows which sources it ran against, at the
   moment of use.
5. Only the three named outputs exist. Adding a fourth requires
   Adam's words for it first.

## Surfaces touched (when specced)

`MacChatView.swift` (columns, composer), `MacCockpitView.swift`
(System Tree feeds Mind Map), `RoutinesView.swift` (feeds `Organize`),
`MacDelegateFormView.swift` (controls unchanged). Source capture needs
a share-sheet entry point (new). Implementation gets its own plan
after Adam signs off on the v2 mockup and names the left panel.
