# Harness Usability Recovery Plan

**Status:** Ready to execute
**Goal:** Open Harness from Finder, pick a backend, ask a question, get an answer — every time, no timeouts.

---

## TLDR — three defects make the app feel dead

1. **The CLI runner has a guaranteed deadlock.** When you send a query through Codex or Grok,
   the app waits for the CLI to *finish* before it reads any of the CLI's output. A macOS pipe
   only holds 64 KB. The moment the CLI writes more than that (easy, since every prompt carries
   the full ontology), the CLI freezes mid-write, the app freezes waiting for it, and after
   90 seconds the app kills it and reports a timeout. This is the "everything times out."

2. **The Mac app never loads your saved API keys.** The Mac workbench boots with whatever is in
   the `ANTHROPIC_API_KEY` environment variable — which is *empty* whenever you launch the app
   from Finder or the Dock. It never reads the Keychain, never saves what you paste, and only
   shows the key field when the backend picker is on Claude. So the app silently falls back to
   the CLI path — the one that deadlocks. This is the "I can't use my API." (The iOS view does
   all of this correctly; the Mac view never got parity.)

3. **Every send scans your disk before calling the model.** Each message triggers a scan of up
   to 1,500 files across your GitHub folders, Obsidian vaults, and iCloud — and reading a
   not-yet-downloaded iCloud file blocks until iCloud downloads it. On a cold vault this alone
   can stall a query long past your patience, before the model is even contacted.

Fix these three and the app works. Everything else below is hardening.

---

## Symptom → cause → file

| What you experience | What is actually happening | Where |
|---|---|---|
| Query spins, then "timed out after 90 seconds" | App reads CLI output only after the CLI exits; pipe fills at 64 KB; CLI blocks forever | `Packages/OntologyKit/Sources/OntologyKit/AgentRunner.swift`, `shell()` (lines 102–131): `completion.wait(...)` runs before `readDataToEndOfFile()` |
| Pasted key doesn't stick / app ignores your key | Mac model inits `apiKey` from env only; never reads or writes Keychain | `Sources/Harness/MacWorkbenchModel.swift` line 16; `Sources/Harness/MacChatView.swift` lines 1372–1383 |
| Key works for one backend, breaks another | One shared `apiKey` string for all backends — an Anthropic key pasted under Claude gets sent to OpenAI if the picker is on Codex → 401 | `MacWorkbenchModel.send()` (`key = apiKey.isEmpty ? nil : apiKey`) |
| Long stall before any model activity | Per-send scan of home-directory sources incl. iCloud Obsidian vault; blocking reads of dataless iCloud files | `Packages/OntologyKit/Sources/OntologyKit/MemoryRetrieval.swift` `files()` / `retrieve()`; roots defined in `HarnessConnector.swift` |
| Grok "just hangs" | Prompt passed as a bare positional argument — if the installed grok CLI treats that as an interactive session, the process never exits and hits the 90 s kill | `AgentRunner.swift` line 54 |
| Codex fails with no useful message | No preflight: app doesn't check the CLI exists *and is logged in* before piping a huge prompt into it | `AgentRunner.swift` `codexPath` / `run()` |
| Project sometimes won't build | Pre-build script hard-fails (`exit 1`) when the iCloud canonical ontology folder is missing, even though valid `.ttl` copies are committed in the repo | `scripts/sync-ontology.sh` lines 11–14; wired in `project.yml` `preBuildScripts` |
| "Capture evidence" fails on some machines | Script path is hardcoded to `~/Developer/GitHub/Harness/scripts/ingest_evidence.py` — breaks if the repo lives anywhere else | `MacWorkbenchModel.swift` `runEvidenceIngest()` (line ~847) |

---

## Phase 0 — Use the app *today* (no code changes)

Do these on your Mac, in order:

1. **Immediate workaround:** open Harness → backend picker → **Claude API** → paste your
   Anthropic key → send. That path is pure HTTPS and has none of the deadlock. The key will not
   survive a relaunch until WO-2 ships — that's expected for now.
2. **Sanity-check the CLIs** in Terminal (this tells us whether the CLI path was ever viable):
   - `codex exec --skip-git-repo-check "say hi"` — should print a reply and exit. If it hangs,
     errors, or asks you to log in, run `codex login` first.
   - `grok --help` — confirm it supports non-interactive, single-shot prompts. If it does not,
     the Grok CLI backend cannot work as currently wired (WO-1 notes the fix).
3. **Optional:** to give the app your keys via environment for one session, launch the binary
   directly (Finder's `open` does not pass environment variables):
   `ANTHROPIC_API_KEY=sk-ant-... /Applications/Harness.app/Contents/MacOS/Harness`

---

## Work orders

Each one is self-contained: what it does, what changes, and the test that proves it done.
The requirement is the test.

### WO-1 — Fix the CLI pipe deadlock  *(root cause of "times out")*

**What it does:** the app reads the CLI's output *while it runs*, so large replies can never jam
the pipe, and a real reply arrives as fast as the CLI produces it.

**Changes** (`AgentRunner.swift`, `shell()`):
- Attach `readabilityHandler` drains (or background reader threads) to both stdout and stderr
  pipes immediately after `proc.run()`, accumulating into thread-safe buffers.
- Keep the 90 s termination timeout, but on timeout include the partial output in the error so
  you can see what the CLI was doing.
- For Grok: invoke with an explicit non-interactive flag (e.g. `-p`/`--prompt`, per the
  installed CLI's help) instead of a bare positional argument.
- Pass the prompt via stdin instead of argv where the CLI supports it — avoids argv length
  ceilings and shell-visibility of the ontology text.

**Acceptance test:** a unit test runs `/bin/cat` on a 1 MB temp file through `shell()` and gets
the full 1 MB back in under 5 seconds. Today that exact scenario deadlocks and dies at 90 s.

### WO-2 — Per-backend Keychain keys on macOS  *(root cause of "can't use my API")*

**What it does:** the Mac app remembers a separate key for each backend, exactly like iOS
already does — paste once, works forever, never sends a key to the wrong vendor.

**Changes:**
- `MacWorkbenchModel`: on init and on every backend change, load the key via
  `APIKeyStore.loadKey(for: backend)` (the per-backend Keychain accounts already exist —
  `openai_api_key`, `xai_api_key`, `anthropic_api_key`). Save on send, mirroring
  `ChatView.saveAPIKey()`.
- `MacChatView`: show the SecureField for **Codex (OpenAI), Grok (xAI), and Claude** — not just
  Claude — with Save/Remove buttons and a "key saved" indicator.
- Route rule: a saved API key for the selected backend always wins over the CLI path (the
  `AgentRunner.run()` logic already prefers a non-empty key; this just makes the key actually
  arrive).

**Acceptance test:** paste a key, quit, relaunch from Finder → key indicator shows saved and a
query succeeds with zero typing. Unit test: adapter for backend X never receives backend Y's key.

### WO-3 — Take the disk scan off the send path

**What it does:** the model call starts immediately; memory enrichment can add context but can
never delay or fail a query.

**Changes** (`MemoryRetrieval.swift`):
- Skip iCloud files that aren't downloaded (check `ubiquitousItemDownloadingStatus` before
  reading; skip anything not `.current`).
- Cap per-file reads at 256 KB.
- Give the whole scan a wall-clock budget (~2 seconds); return whatever was found when the
  budget expires.
- Emit a trace event with the scan duration so slow sources are visible in the Trace tab.

**Acceptance test:** with a cold iCloud vault, the trace shows the model call starting within
3 seconds of pressing send.

### WO-4 — Backend preflight and honest status

**What it does:** before sending, the app verifies the selected backend can actually respond,
and the status line tells the truth instead of spinning: "Codex CLI not found," "Codex CLI not
logged in — run `codex login`," "Waiting for Claude (12 s elapsed)."

**Changes:**
- `AgentRunner.preflight(backend:)`: CLI backends → binary exists + a fast `--version` probe
  with a 5 s timeout; API backends → key present; Hermes → `127.0.0.1:11434` reachable.
- How readiness is shown in the UI: **Adam decides** — not specified here.
- Add a **Cancel** button while a run is in flight: cancels the Task and kills the child process,
  UI back to idle within 1 second.

**Acceptance test:** selecting Codex with the CLI missing shows the explanation instantly —
not after a 90-second spin. Cancel always returns the UI to idle.

### WO-5 — Pick a default backend that can actually work

**What it does:** on launch the app selects the first *ready* backend (saved key → working CLI
→ local Ollama) instead of hardcoding Codex.

**Changes:** `MacWorkbenchModel.init` uses the WO-4 preflight to choose; persists the user's
last manual choice once they make one.

**Acceptance test:** fresh launch with only an Anthropic key saved auto-selects Claude and a
query succeeds with no configuration.

### WO-6 — Build hardening

**What it does:** the project builds on any machine, with or without the iCloud canonical
ontology folder; the committed `.ttl` files are the fallback.

**Changes:**
- `scripts/sync-ontology.sh`: when the canonical folder is missing, print a warning and
  `exit 0` (keep the committed resources) instead of failing the build.
- `MacWorkbenchModel.runEvidenceIngest()`: resolve the script relative to a configurable root
  (`HARNESS_REPO_ROOT` env or a UserDefaults setting) instead of the hardcoded
  `~/Developer/GitHub/Harness` path.

**Acceptance test:** `xcodegen generate && xcodebuild -project Harness.xcodeproj -scheme
Harness build` succeeds on a machine with no iCloud folder.

### WO-7 (optional) — API client timeouts and retries

Add explicit `timeoutInterval` (60 s request / 120 s resource) to the Claude, OpenAI, and xAI
clients, one retry on transient network failure, and include the HTTP status code in every
error surface. Small change, kills a class of silent hangs on flaky networks.

---

## Order of execution

1. **WO-1 + WO-2 together** — they end the two ways the app is unusable.
2. **WO-4** — visibility, so any remaining failure explains itself.
3. **WO-3** — latency.
4. **WO-5, WO-6, WO-7** — polish and durability.

## About "training it"

The learning loop (candidate memory → review queue → graph promotion) feeds off *successful
runs* — the extractor only fires after a reply comes back. Runs failing is exactly why nothing
has been accumulating. No separate fix needed: once WO-1/WO-2 land and queries succeed,
candidates start flowing into the review queue again. The one training-adjacent fix is the
hardcoded evidence-ingest path (covered in WO-6).

## Clear sign of success

Open the app from Finder, pick any backend with a green dot, ask a question, get an answer with
a named rule — ten times in a row, zero timeouts.

## Kill switch

If, after WO-1 and WO-2, the CLI path still misbehaves on your machine: drop the CLI backends
from the picker and run everything through direct API keys. All three HTTPS clients already
exist and work; the CLIs are an optimization, not a dependency.
