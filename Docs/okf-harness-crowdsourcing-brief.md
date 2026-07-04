---
type: agent_brief
title: Harness + Open Knowledge Format Crowdsourcing Brief
created: 2026-07-04
status: revised-after-agent-review
source: Codex conversation summary with Claude critique incorporated
intended_audience:
  - Codex
  - Claude
  - Gemini
  - Hermes
  - external technical reviewers
trust_level: discussion-summary
---

# Harness + Open Knowledge Format Crowdsourcing Brief

## Purpose

This brief summarizes a discussion about whether Google's Open Knowledge Format
(OKF) should influence the Harness macOS app. The current recommendation is not
to build a full OKF connector yet. The better near-term move is to borrow OKF's
frontmatter conventions for Harness source cards.

Please evaluate the idea critically. Do not simply agree with the proposal.

## Current Harness Context

Harness is a native macOS app designed to put Adam's personal ontology,
judgment rules, accepted beliefs, and working context in front of LLMs.

The current architecture separates knowledge into trust tiers:

- Accepted authority: RDF/Turtle graph files, accepted beliefs, axioms, and
  validated ontology claims.
- Candidate memory: possible claims waiting for review and validation.
- Supporting memory: GitHub repos, Obsidian notes, Apple Notes exports,
  NotebookLM imports, Firecrawl results, and other source material.
- Model output: useful but never accepted as authority by itself.

Harness already has a strong safety instinct:

- Supporting sources do not become accepted truth automatically.
- NotebookLM and Firecrawl are treated like synthesized external research
  unless explicitly labeled otherwise.
- Candidate claims must pass review before promotion.
- RDF/Turtle and SHACL remain the stricter validation layer.

## What OKF Appears To Offer

Open Knowledge Format is a Markdown-and-YAML-based format for representing
knowledge in a way that both humans and agents can read.

The interesting claim is not only that OKF stores knowledge. The interesting
claim is that OKF may be a useful packet format for agent-to-agent and
human-to-agent communication.

In plain terms:

- Humans can read Markdown.
- Agents can parse YAML frontmatter.
- Files can be linked together.
- Context can travel between agents without being trapped in chat history.
- Knowledge can be structured without the authoring friction of RDF/Turtle.

Reference:

- https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md

## Revised Strategic Role

OKF should not replace Harness's accepted RDF/Turtle graph, and Harness should
not add an OKF-specific connector until there is a real ecosystem or native OKF
export flow to connect to.

The better hypothesis is:

> OKF becomes a compatible naming convention for source cards and agent packets.
> RDF/Turtle remains the accepted authority and validation layer.

This creates a bridge:

```text
Markdown/frontmatter -> source card -> supporting memory -> candidate claim -> validation -> accepted graph
```

The important correction from agent review:

> Harness already reads Markdown as searchable text, but it does not yet fully
> parse frontmatter as structured source metadata. That gap is the useful slice.

## Three Real-World Harness Use Cases

### 1. NotebookLM Research Becomes Reusable Context

Today, NotebookLM can produce useful research artifacts, but they are easy to
lose in Downloads, hard to classify, and hard to reuse across agents.

With frontmatter-aware source cards, Harness could import a NotebookLM output
and wrap it as a structured source pack:

- type: notebooklm_research_pack
- title: human-readable title
- source: file path or URL
- trust_level: supporting_memory
- summary: short synthesis
- key_claims: claims to inspect, not automatically believe
- provenance: where it came from

This would make NotebookLM research easier to reference later without Adam
needing to re-explain the context.

### 2. Understood Insights Become Candidate-Ready

Understood may generate patterns, observations, summaries, or behavioral
insights. Those should not automatically become accepted beliefs, but they
should not disappear into loose notes either.

An OKF file could capture each insight as a structured packet:

- type: candidate_insight
- source_app: Understood
- observed_pattern: the possible insight
- supporting_evidence: links or summaries
- confidence: low, medium, high
- review_status: pending

Harness could then surface these in the Candidates queue instead of requiring
manual translation into RDF/Turtle.

### 3. Agent Handoffs Become Inspectable

Harness often needs to hand work to Codex, Claude, Gemini, Hermes, or other
tools. Chat handoffs are fragile because context is embedded in long messages.

An OKF work packet could include:

- type: agent_work_packet
- goal: what the agent should accomplish
- accepted_rules: rules the agent must follow
- supporting_sources: files or links to inspect
- constraints: what not to do
- open_questions: uncertainty to resolve
- desired_output: what the user wants back

The agent could return an OKF report:

- type: agent_report
- findings: what it found
- evidence: links and file references
- risks: issues discovered
- recommendation: next action
- candidate_claims: claims worth reviewing

This would make Harness more powerful because context would become portable,
inspectable, and reusable.

## Likely Value Proposition

The value is not that OKF is more formally correct than RDF. It is not.

The value is that OKF could make Harness easier to feed, easier to inspect, and
easier to connect to other agents.

The most likely benefits are:

- Less manual copy/paste between apps.
- Less dependence on long chat history.
- Easier sharing between agents.
- Better provenance for imported research.
- A clearer path from rough notes to candidate memory.
- More human-readable knowledge files that can still be parsed by software.

The revised value proposition is narrower:

> Adopt the convention, defer the integration.

That means Harness should use OKF-compatible field names where helpful, but not
add a new subsystem just because OKF exists.

## Important Risks And Skeptical Questions

### Risk 1: OKF May Duplicate Existing Markdown Workflows

Harness already reads Markdown from Obsidian and other folders. OKF may only be
useful if Harness enforces a small number of meaningful fields rather than
accepting arbitrary Markdown.

Questions for reviewers:

- What does OKF add beyond ordinary Markdown plus frontmatter?
- Which fields are actually worth standardizing?
- Is the format useful without a strong schema?

### Risk 2: OKF Links Are Less Precise Than RDF Predicates

Markdown links are easy for humans, but they do not encode relationship meaning
as strictly as RDF triples.

Questions for reviewers:

- Where would OKF be too ambiguous?
- Which Harness knowledge should stay RDF-only?
- How should Harness prevent OKF material from being treated as accepted truth?

### Risk 3: The App Could Become More Complex Without Enough Payoff

Adding another connector, parser, import flow, and candidate bridge may increase
surface area.

Questions for reviewers:

- What is the smallest useful OKF integration?
- Should Harness start with read-only ingestion only?
- Should OKF-to-RDF compilation wait until there is repeated usage?

Current answer:

- Do not add an OKF connector yet.
- Do not add a new folder just for OKF yet.
- Build source cards for existing sources first.
- Use OKF-compatible field names inside those cards.

### Risk 4: Agent-to-Agent Claims May Sound Better Than They Are

"Agents talking to agents" is attractive, but the practical value depends on
whether the packets reduce work for Adam.

Questions for reviewers:

- Which workflows would actually save time?
- Which workflows would become another thing to manage?
- What should the UI hide from Adam?

### Risk 5: Frontmatter Could Try To Promote Itself

Frontmatter is a claim about a file. It is not a credential.

A file must never be able to declare its own authority tier. For example, an
imported or agent-written file might include:

```yaml
trust_level: accepted
```

Harness must display that as a self-declared label only. The actual authority
ceiling must come from the connector and the ingestion path, not from the file's
own frontmatter.

Questions for reviewers:

- Should `trust_level` be parsed at all, or only shown as raw metadata?
- What exact UI language should say "self-declared label ignored"?
- Which fields are safe to parse without changing behavior?

## Proposed First Slice

The suggested first implementation should be small and should not be called OKF
integration:

1. Build frontmatter-aware source cards for sources Harness already ingests.
2. Parse a tiny whitelist of fields:
   - type
   - title
   - description
   - tags
   - resource
   - timestamp
   - trust_level
3. Treat `trust_level` as self-declared metadata only.
4. Hardcode the source card's real authority tier to the connector ceiling.
5. Display all frontmatter-ingested cards as supporting memory unless they
   already come from the accepted graph path.
6. Add a visible note when a file self-declares a higher tier than Harness
   allows.

Acceptance test:

> Create a Markdown file with `trust_level: accepted` in frontmatter. Ingest it.
> Verify Harness displays it as supporting memory with a note equivalent to
> "self-declared label ignored." It must not enter accepted authority or bypass
> the Candidates queue.

Do not compile OKF or frontmatter into RDF in the first slice.

## Proposed Second Slice

If the first slice is useful, add:

- "Promote to Candidate" for selected OKF claims.
- A candidate review screen that keeps OKF evidence attached.
- A compiler path from reviewed OKF candidate to Turtle.
- SHACL validation before accepted graph promotion.
- A `frontmatter-no-self-promotion` evaluation check in the trace.

## Suggested Prompt For Other Agents

Use this prompt when sharing the file:

```text
Please review this Harness + OKF proposal critically. I am excited about it,
but I want a skeptical technical assessment.

Focus on:
1. Whether Harness should adopt OKF-compatible field names without adding an
   OKF connector.
2. Whether frontmatter-aware source cards add real value beyond plain Markdown
   retrieval.
3. Whether the trust clamp is sufficient to prevent self-promotion.
4. How this should interact with RDF/Turtle and accepted graph authority.
5. The smallest useful implementation slice.
6. Risks, failure modes, and what not to build yet.

Please give a recommendation: adopt, experiment narrowly, defer, or reject.
```

## Current Working Recommendation

Defer OKF integration. Adopt the convention.

OKF appears valuable as a portable, human-readable naming convention for source
metadata and agent handoff packets. It should not become a new connector or
subsystem yet.

The best next step is frontmatter-aware source cards over existing connectors.
Borrow OKF-compatible field names, clamp all imported file authority to
supporting memory, and require candidate review plus SHACL validation before any
claim reaches the accepted graph.
