# HANDOFF — Get the new Harness build running on Adam's Mac

For: any agent or person with terminal + Xcode access on Adam's Mac.
Written 2026-07-06. The code is DONE and MERGED. Nothing needs to be
written. The only job: update Adam's local checkout, build, run, and
confirm Adam can SEE the changes.

## The acceptance test (Adam's eyes, nothing else counts)

Open the Harness macOS app. In the top toolbar, immediately RIGHT of the
backend dropdown (reads "Codex"), Adam must see:

1. A small colored dot + a status word: green dot **LIVE**, or orange dot
   **PENDING**, or **FAILED (reason)** in red
2. A ChatGPT account control for Codex; API-key fields remain visible for
   Grok and Claude backends
3. When a backend needs something, the status line names the one action,
   e.g. "Codex: install codex CLI and run codex login --device-auth"
4. While a query runs: a red **Cancel** button next to the progress spinner

If Adam sees those, done. If not, not done — regardless of what any
command reported.

## State of the code

- Repo: `github.com/dblaira/Harness` (recently RENAMED from
  `dblaira/harness` — old remote URLs redirect, but update if anything acts
  confused)
- Everything is merged to `main`: merge commit `2a8e0af`
  ("Merge branch 'cursor/harness-usability-recovery-plan-33b4'"), 2026-07-06
- Local checkout is likely at `~/Developer/GitHub/Harness`

## Steps

1. In the repo folder: `git status` — if there are local edits, stash or
   commit them first and tell Adam. Then `git checkout main && git pull
   origin main`. Confirm `git log --oneline -1` starts with `2a8e0af` or
   later.
2. The Xcode project file is GENERATED and gitignored (`project.yml` is
   the source of truth). Regenerate it: `xcodegen generate`
   (if missing: `brew install xcodegen`).
3. Build-blocker to know about: the pre-build script
   `scripts/sync-ontology.sh` HARD-FAILS if this folder is missing:
   `~/Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Ontology/accepted`
   On Adam's Mac it should exist. If the build fails with "Missing
   canonical ontology folder", that's why — set `ONTOLOGY_ACCEPTED_DIR`
   to a folder containing the `.ttl` files, or fix the script to warn
   instead of exit 1 (that fix is planned as build hardening in
   `Docs/harness-usability-recovery-plan.md`).
4. Open `Harness.xcodeproj`, scheme **Harness**, destination **My Mac**,
   Product → Run. Code signing is already disabled for macOS builds in
   `project.yml`, so no signing setup is needed.
5. Run the tests too:
   `xcodebuild -project Harness.xcodeproj -scheme Harness test -destination 'platform=macOS'`
   New tests that must pass:
   - `AgentRunnerShellTests` — 1 MB through /bin/cat without deadlock
     (the old code deadlocked on anything over 64 KB)
   - `BackendReadinessTests` — readiness state mapping
   - `APIKeyRoutingTests` — each backend loads only its own key
6. Take a screenshot of the running app's toolbar and show Adam.

## If Adam still sees no change after building

- Confirm the app on screen is the one Xcode just launched — not an old
  copy in /Applications or the Dock
- Confirm `git log --oneline -1` in his checkout shows `2a8e0af` or later
- Confirm the scheme built is **Harness** (macOS), not an iOS variant

## What changed (so you can answer questions)

- **The 90-second timeouts**: `AgentRunner.shell()` in
  `Packages/OntologyKit/Sources/OntologyKit/AgentRunner.swift` used to wait
  for the CLI to exit BEFORE reading its output pipe. A macOS pipe holds
  64 KB; bigger replies jammed, the CLI froze, and every such query died at
  90 s. Now background readers drain the pipes while the child runs, and
  timeout errors include the child's partial output.
- **API keys**: `MacWorkbenchModel` (in `Sources/Harness/`) now loads a
  per-backend key — environment variable first, then Keychain — on launch
  and on backend switch, and saves a pasted key on first use. Each backend
  gets only its own key.
- **Readiness**: `AgentRunner.preflight(backend:)` probes CLI presence
  (5-second version check), key presence, or the local Ollama server, and
  maps to SAVY's status vocabulary: "live" / "pending" / "failed (message)"
  / "Checking gateway…".
- **Cancel**: kills registered child processes and cancels the run task.

## Working with Adam (mandatory reading)

Read `Docs/skills/*/SKILL.md` in this repo before replying to him.
The short version:

- Quote his words verbatim; never rename his concepts
  ("When you use your own words or add words to it, it loses all its meaning.")
- Never estimate how long anything will take him; no "quick", no "just"
- Only claim "done" with evidence from HIS vantage point (screenshot,
  what he will see) — a green build log is not evidence
- Plain language: say what a thing does; codes and file paths only in
  parentheses after
- Design choices (words, icons, fonts, colors) come ONLY from
  `Docs/design-vocabulary.md` — anything else goes back to Adam as one
  question
