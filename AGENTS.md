# Agent notes

## How agents use Adam's Macs (required)

Adam signed up for Tailscale so agents work **on his real computers** — the ones already signed into his accounts — not on a blank rented machine that has to fight every login.

**Default rule:** Do the work on his Macs. Prefer `studio` (Mac Studio). Use `mbp` or `mbp2` when the task belongs there.

When Tailscale is joined (secrets `TAILSCALE_AUTHKEY` + `TAILSCALE_SSH_KEY`):
- `ssh studio` — Mac Studio — primary
- `ssh mbp` — MacBook Pro
- `ssh mbp2` — MacBook Pro 2

**Do not say you cannot access his files, apps, builds, or signed-in sessions** without first trying his Macs. If a website or app needs a login, do it from his Mac (already trusted), not from the cloud box.

If Tailscale is not joined yet, run: `bash .cursor/tailscale-join.sh`


## Skills to load (do not skip)

Always: requirement-is-the-test, adams-words, no-time-estimates, cognitive-fit, articulate-leadership-communication.

Stack (when editing matching files): see `.cursor/rules/stack-*.mdc` — nextjs / react-best-practices / figma-swiftui / aws-lambda / context7 / systematic-debugging.

If the same mistake happens twice: create a rule. Prefer system over apology.

## Cursor Cloud specific instructions

Two surfaces. The Swift app belongs on Adam's Macs; the Python pipeline runs on the cloud VM.

### Swift app (macOS + iOS) — build on Adam's Macs, not the cloud box
- The primary product (`Sources/Harness`, `Packages/OntologyKit`) is a native
  SwiftUI app needing Xcode + `xcodegen` + the iOS Simulator, which do not exist
  on the Linux cloud VM. Per the Macs-first rule above, do this work over
  Tailscale (`ssh studio`), where the build/test commands in `README.md`
  (`xcodegen generate`, `xcodebuild ... -scheme Harness`) run.
- Swift-for-Linux is not a workaround: the app and `OntologyKit` import
  Apple-only frameworks (SwiftUI, AppKit, UIKit, Darwin, CoreGraphics, ImageIO,
  CryptoKit). `project.yml` is the source of truth; `Harness.xcodeproj` is
  generated and gitignored. `scripts/sync-ontology.sh` is a no-op off-Mac and
  keeps the committed `Packages/OntologyKit/.../Resources/*.ttl` copies.

### Python pipeline — runs on the cloud VM
- System Python lacks `rdflib`/`pyshacl`. Use the repo virtualenv:
  `.venv/bin/python`. Create it with: `python3 -m venv .venv` then
  `.venv/bin/pip install rdflib pyshacl`.
- Control surface (the "hello world"): `review_queue.py` — seeds 23 claims,
  accepts one, SHACL-validates the Turtle via
  `scripts/validate_connection_turtle.py` (shapes in `Ontology/shapes/`), then
  appends to `accepted-graph.ttl` and `decision-ledger.json`.
  - `.venv/bin/python review_queue.py --status` — counts only
  - interactive review reads stdin, e.g.
    `printf 'y\nq\n' | .venv/bin/python review_queue.py`
  - `.venv/bin/python review_queue.py --export` — print accepted graph
- `momentum_gate.py` is pure stdlib (no venv needed).
- `review_queue.py` writes gitignored scratch files to the repo root
  (`queue.json`, `accepted-graph.ttl`, `decision-ledger.json`); delete them to
  reset.
- Some `scripts/ingest_*.py` and `scripts/sync_ledger.py` need external
  resources absent here (Supabase creds, the macOS app's SQLite ledger). They
  exit gracefully with a "blocked/not found" message — expected, not a failure.
- Python lint/smoke:
  `.venv/bin/python -m py_compile momentum_gate.py review_queue.py scripts/*.py`.
  There is no Python test suite (automated tests are Swift/Xcode-only).
