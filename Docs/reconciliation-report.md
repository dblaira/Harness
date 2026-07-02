The 334,879 triples came from generated Hermes/Alignment Turtle files over Adam's Obsidian Main vault, merged into `Ontology/Alignment/accepted-alignment-graph.ttl` and loaded into Fuseki's default `understood` dataset.
Adam's 21 clicked beliefs are in Fuseki: no.
Queue that should survive: Harness.

# Reconciliation Report: Harness Graph vs. Obsidian Vault Fuseki

This is a read-only audit. I changed no graph data, deleted nothing, and merged nothing.

## 1. FUSEKI CONTENTS

Fuseki endpoint checked: `http://100.111.154.126:3030/understood/query`

Live count at audit time: 334,931 triples. That is 52 more than the 334,879 count in the task, so the server appears to have been reloaded or slightly changed since that number was recorded.

Named graphs: none. The triples are loaded into the default graph only. A SPARQL named-graph count query returned no named graphs.

Triple count per graph:

| Graph | Triple count |
| --- | ---: |
| Default graph, dataset `understood` | 334,931 |
| Named graphs | 0 |

Sample subjects in Fuseki:

| Subject example | What it indicates |
| --- | --- |
| `https://understood.app/vault/table-cell/31bd716bc8496416` | Markdown table-cell extraction from the vault |
| `https://understood.app/vault/heading/8128201efe013d5d` | Heading extracted from a vault note |
| `https://understood.app/reading/work/2516ccf250c20c4a` | Reading/book-highlight corpus item |
| `https://understood.app/vault/frontmatter/acc850237bc9ceb1` | Frontmatter extracted from a vault note |

Main vocabularies seen:

| Vocabulary | Use in Fuseki |
| --- | --- |
| `https://understood.app/ontology/alignment#` | Main generated alignment vocabulary: vault notes, headings, frontmatter, tables, claims, review fields |
| `https://schema.org/` | Generic document, name, text, about, action, quotation, creative-work terms |
| `http://purl.org/dc/terms/` | Source, identifier, created/modified provenance |
| `http://www.w3.org/ns/prov#` | Generated-at-time provenance |
| `https://www.commoncoreontologies.org/` | CCO alignment classes |

Source of the triples:

The source is not Harness's accepted graph. The source is the Obsidian Main vault at `/Users/adamblair/Documents/Main`, processed by scripts in `Ontology/Alignment/scripts/`, then merged by `Ontology/Alignment/build_accepted_graph.sh` into `Ontology/Alignment/accepted-alignment-graph.ttl`. The loader script `Ontology/Alignment/scripts/reload_fuseki_accepted_graph.sh` posts that merged file to the Fuseki default graph. `start_fuseki_tailnet_only.sh` starts the tailnet-only Fuseki container and reloads the same accepted-alignment graph.

The clearest script evidence is:

| Script | What it does |
| --- | --- |
| `generate_vault_alignment.py` | Scans every Markdown note in `/Users/adamblair/Documents/Main` and emits note, folder, tag, heading, wiki-link, and semantic-claim facts. |
| `generate_note_content_alignment.py` | Emits content hashes, byte/word/line counts, tasks, and quotes from Markdown files. |
| `generate_formalization_coverage_alignment.py` | Marks how much of each note has been structurally or meaningfully formalized. |
| `build_accepted_graph.sh` | Merges many `*-alignment-v1.ttl` files into `accepted-alignment-graph.ttl` using Jena `riot`. |
| `reload_fuseki_accepted_graph.sh` | Posts `accepted-alignment-graph.ttl` into Fuseki's default graph. |

Important naming issue: `accepted-alignment-graph.ttl` is named "accepted", but it is not the same as Harness's Adam-clicked `accepted/accepted-graph.ttl`.

## 2. OVERLAP

Direct Fuseki checks for Harness-specific subjects returned no matches.

| File or file group | In Fuseki? | Evidence |
| --- | --- | --- |
| `Ontology/accepted/accepted-graph.ttl` | No | `conn-obs-001` was absent; count of reviewed `conn-obs-*` observed-correlation connections was 0. |
| `Ontology/accepted/adam-beliefs.ttl` | No | `connection/conn-001` was absent. |
| `Ontology/accepted/adam-axioms.ttl` | No | `concept/context-without-conviction` was absent. |
| `Ontology/accepted/adam-beliefs-bundle.ttl` | No | `https://understood.app/ontology` bundle ontology subject was absent. |
| `Ontology/accepted/adam_pattern.ttl` | No | Adam Pattern subject from the Harness TTL was absent. |
| `Ontology/accepted/leverage-disposition.ttl` | No | Leverage disposition subject from the Harness TTL was absent. |
| `Ontology/Alignment/accepted-alignment-graph.ttl` | Yes | Fuseki contains the same alignment vocabulary, vault-note subjects, and default-graph bulk count. |
| Hermes/Alignment source TTLs listed in `build_accepted_graph.sh` | Yes, merged | Their contents are present through the merged `accepted-alignment-graph.ttl`, not as separate named graphs. |
| `Ontology/Alignment/Candidates/*.ttl` | Not as a separate queue | The build script does not bulk-load candidate files directly as their own graph. Some promoted/reviewed-candidate records are present through `reviewed-candidate-promotions-v1.ttl`. |

Conclusion: Harness's approved personal graph is not currently loaded in Fuseki. Fuseki is serving the vault-derived alignment graph.

## 3. QUEUE COMPARISON

| Area | Harness queue | Vault semantic candidate queue |
| --- | --- | --- |
| Location | `Ontology/candidates/queue.json` in the canonical iCloud Ontology folder, used by Harness | `Understood Suite/Semantic Candidates/` plus semantic inventory/index notes in the vault |
| Current state | 24 items: 22 accepted, 2 rejected | The candidate folder has a template, not an active queue of pending files |
| Schema | Structured JSON with `id`, `status`, `plain`, `evidence`, `source`, domains, strength, connection type | Markdown template with fields such as candidate statement, triple, evidence, validation, and decision |
| Review mechanism | Harness app and review queue code turn explicit Adam decisions into Turtle | Manual note/template workflow; no observed click-to-approve UI |
| Approval surface | Working human approval surface in Harness | No working click-to-approve surface found |
| Writes accepted graph | Yes. Accepted decisions append validated Turtle to `accepted/accepted-graph.ttl` | No comparable automatic accepted-graph write path found |

Harness has the only working click-to-approve UI and should be the surviving queue.

## 4. PROVENANCE CHECK

The 334K vault-extracted triples do carry source provenance, but they do not carry Adam-approved authority.

What they do carry:

| Provenance field | Meaning |
| --- | --- |
| `dcterms:source` | Source vault file path, such as `Understood Ontology Handoff - 2026-05-15.md` |
| `prov:generatedAtTime` | Generated timestamp for many records |
| `align:relativePath` | Vault-relative path |
| `align:contentHash` | File/content fingerprint |
| `align:formalizationStatus` | Bulk formalization status, currently showing `meaning-formalized` records |

What they do not carry:

| Missing authority signal | Why it matters |
| --- | --- |
| Adam approval per triple | A bulk extraction is not the same thing as a clicked belief. |
| Harness queue decision IDs | The Fuseki graph is not linked to Harness's queue decisions. |
| Accepted/rejected status from Harness | The approved Harness graph is absent. |

The live graph also contains review-looking fields, but they confirm non-approval rather than approval:

| Field | Live value |
| --- | --- |
| `schema:reviewedBy` | `unchecked` for 22 records |
| `align:reviewStatus` | `candidate` for 7 records |

Authority decision: these 334K vault triples should be treated as candidate/context triples, not Adam-approved truth.

## 5. RECOMMENDATION

a. Single authority store: Harness should be the authority store for Adam-approved beliefs, with the canonical files in iCloud `Ontology/accepted/`.

b. Queue that survives: Harness.

c. What gets loaded into Fuseki: load Harness-approved TTLs into a named graph like `/accepted`; load vault/Hermes bulk extractions into a separate named graph like `/candidates`; never mix the two in the default graph without authority labels.

## 6. RISKS

The biggest risk is the filename `accepted-alignment-graph.ttl`: it can make bulk-generated vault alignment sound Adam-approved when it is not.

Because Fuseki currently uses one default graph and no named graphs, a query cannot tell "Adam clicked this" from "a script extracted this from a note" unless it checks individual provenance fields.

Some live graph fields use words like `meaning-formalized`, which can be mistaken for reviewed truth. In this pipeline, that means made queryable/formal, not approved by Adam.

The vault graph includes raw note-derived text and source paths. If downstream systems treat all default-graph triples as trusted memory, private drafts, temporary notes, or sensitive note content could silently become agent authority.

Any agent that reads Fuseki as "the accepted graph" would currently skip the real Harness approval boundary and could answer as if unreviewed vault extractions were Adam-approved beliefs.
