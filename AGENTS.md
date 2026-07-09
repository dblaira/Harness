# AGENTS.md — Harness

## Cursor Cloud specific instructions

Harness has two surfaces. Only one of them runs on this Linux cloud VM.

### Swift app (macOS + iOS) — NOT buildable on the cloud VM
- The primary product (`Sources/Harness`, `Packages/OntologyKit`) is a native
  SwiftUI app. It requires macOS + Xcode + `xcodegen` + the iOS Simulator, none
  of which exist on this Linux VM. Build/test commands are in `README.md`
  (`xcodegen generate`, `xcodebuild ... -scheme Harness`).
- Do not try to install Swift-for-Linux to work around this: the app and
  `OntologyKit` import Apple-only frameworks (SwiftUI, AppKit, UIKit, Darwin,
  CoreGraphics, ImageIO, CryptoKit), so they cannot compile off-Mac. Swift unit
  tests (`HarnessTests`, `Tests/`) likewise only run under Xcode on a Mac.
- `project.yml` is the source of truth; `Harness.xcodeproj` is generated and
  gitignored. The `scripts/sync-ontology.sh` prebuild step is a no-op off-Mac
  (the canonical iCloud folder is absent) and intentionally keeps the committed
  `Packages/OntologyKit/Sources/OntologyKit/Resources/*.ttl` copies.

### Python pipeline — this is what runs on the cloud VM
- System Python lacks `rdflib`/`pyshacl`. Use the repo virtualenv:
  `.venv/bin/python`. The update script creates `.venv` and installs deps.
- Core control surface (the "hello world"): `review_queue.py` — seeds 23 claims,
  accepts one, SHACL-validates the emitted Turtle via
  `scripts/validate_connection_turtle.py` (shapes in `Ontology/shapes/`), then
  appends to `accepted-graph.ttl` and `decision-ledger.json`.
  - `.venv/bin/python review_queue.py --status` — counts only
  - `.venv/bin/python review_queue.py` — interactive review (reads stdin;
    pipe answers, e.g. `printf 'y\nq\n' | .venv/bin/python review_queue.py`)
  - `.venv/bin/python review_queue.py --export` — print accepted graph
- `momentum_gate.py` is pure stdlib (no venv needed): the plain-words / length
  gate every answer passes through.
- `review_queue.py` writes gitignored scratch files to the repo root
  (`queue.json`, `accepted-graph.ttl`, `decision-ledger.json`). Delete them to
  reset to a fresh queue.
- Some `scripts/ingest_*.py` and `scripts/sync_ledger.py` depend on external
  resources that are absent here (Supabase creds, the macOS app's SQLite ledger
  at `~/Library/Application Support/Harness/`). They exit gracefully with a
  "blocked/not found" message — that is expected, not a setup failure.
- Lint/smoke check for the Python side:
  `.venv/bin/python -m py_compile momentum_gate.py review_queue.py scripts/*.py`.
  There is no Python test suite (all automated tests are Swift/Xcode-only).
