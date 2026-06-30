# Harness Codex Handoff

Date: 2026-06-30

Repo: `/Users/adamblair/Developer/GitHub/Harness`

GitHub: `https://github.com/dblaira/Harness`

Current branch: `main`

Current state: PR #1 was merged into `main`, the handoff was committed, and local `main` was pushed cleanly. The latest `main` commit before `codex/workbench-run-spine` is `7c4bc33`.

Follow-on branch: `codex/workbench-run-spine` is implementing the macOS run-detail spine, candidate review status controls, and first-pass skills/plugins/tools inventory.

## Plain Summary

Harness is a native macOS and iOS ontology agent workbench.

The goal is not a generic chat app. Harness should become Adam's local-first agent surface for delegation, ontology-aware reasoning, graph authority, memory, run traces, and candidate review.

The app now has:

- A macOS Hermes-inspired workbench layout.
- An iPhone Grok-style quick-launch layout.
- A deterministic backend foundation in `OntologyKit`.
- A local run ledger and authority/memory/eval/candidate model layer.
- A cleaned faint light-brown Harness watermark asset for the iOS launch screen.

## What Was Done

### Repo And GitHub

- The Harness repo is now located at `/Users/adamblair/Developer/GitHub/Harness`.
- Work was developed on `codex/harness-deterministic-workbench`.
- Pull request #1 merged that branch into `main`.
- Local `main` is synced with `origin/main`.
- Junk generated `.local-artifacts/` files were removed locally.
- `.gitignore` now excludes generated local project artifacts.

### Deterministic Backend Foundation

Added local-first backend structures in `Packages/OntologyKit`:

- `BackendModels.swift`
- `AuthorityRetrieval.swift`
- `MemoryRetrieval.swift`
- `RunEvaluation.swift`
- `RunLedgerStore.swift`
- `HarnessRunService.swift`
- `DeterministicBackendTests.swift`

The intended backend order is fixed:

1. Graph authority
2. Supporting memory
3. Model/backend execution
4. Evaluation
5. Trace persistence

Candidate claims are kept separate from accepted authority.

### macOS App

`Sources/Harness/MacChatView.swift` was refactored toward a three-pane workbench:

- Left: sessions, skills/tools, search, read-only vault status.
- Center: transcript, backend picker, composer.
- Right: authority, memory, trace, candidates.

`Sources/Harness/MacWorkbenchModel.swift` was added to support the workbench state.

### Product Memory: Hermes Skills And Plugins Layout

Adam shared a Hermes macOS screenshot on 2026-06-30 and explicitly called out the layout for skills and plugins as a strong reference.

Important product direction:

- Harness should treat skills and plugins as a first-class workbench surface, not a buried settings screen.
- The Hermes-style left navigation pattern is desirable: `New session`, `Skills & Tools`, `Messaging`, `Artifacts`, search, pinned sessions, session history, and a status/footer rail.
- A right-side or inspector-style inventory of local folders, agents, skills, plugins, connectors, or tool domains is useful for making the workbench feel like an operating surface rather than a chat transcript.
- Harness will likely need to manage a large number of skills and plugins, so discoverability, grouping, search, enablement state, and run-time provenance should become part of the design.
- This is not necessarily the first backend task, but it should stay on the near-term product list because it shapes how Adam will delegate work through Harness.

### iOS App

`Sources/Harness/ChatView.swift` was rebuilt into a Grok-style iPhone launch surface:

- No keyboard appears on app launch.
- Top controls include menu, Ask/Imagine selector, and privacy shield.
- Center shows faint Harness watermark.
- Bottom carousel includes quick actions:
  - Analyze Docs
  - Customize Harness
  - Create Videos
  - Edit Images
- Composer includes plus, backend/model selector, mic, and Speak button.
- Existing `AgentRunner` send flow remains in place for text submit.

### Watermark Asset

Added:

- `Sources/Harness/Assets.xcassets/HarnessWatermark.imageset/Contents.json`
- `Sources/Harness/Assets.xcassets/HarnessWatermark.imageset/HarnessWatermark.png`

The watermark was created from the supplied Harness icon. Background outside the thick logo lines was removed so it appears as a faint light-brown outline on the navy iOS surface.

## Verified

These passed before merge:

```sh
xcodebuild -scheme Harness -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme Harness -destination 'platform=macOS' build
swift test --package-path Packages/OntologyKit
```

The iOS simulator was launched and visually checked. The keyboard does not auto-open, and the bottom controls fit.

## Important Files

- `project.yml` - XcodeGen source of truth.
- `Sources/Harness/ChatView.swift` - iOS launch/chat UI.
- `Sources/Harness/MacChatView.swift` - macOS workbench UI.
- `Sources/Harness/MacWorkbenchModel.swift` - macOS workbench state.
- `Sources/Harness/Theme.swift` - shared color tokens.
- `Packages/OntologyKit/Sources/OntologyKit/` - deterministic backend layer.
- `Docs/backend-requirements.md` - backend requirements from the user.
- `Docs/harness-architecture-brief.md` - architecture brief.

## Development Protocol

Use GitHub for code.

Use TestFlight later for app installs.

Simple workflow:

1. Before working: pull latest `main`.
2. Make changes.
3. Build/test.
4. Commit.
5. Push.
6. If using a feature branch, merge PR into `main`.
7. On other machines, pull `main`.

Do not use iCloud or Dropbox to sync the repo.

Do not commit:

- `.local-artifacts/`
- `Harness.xcodeproj/`
- `build/`
- `DerivedData/`
- `.build/`

## Next Useful Work

The next Codex thread should start from `main` and focus on one of these:

1. If `codex/workbench-run-spine` is not merged yet, review and merge that PR first.
2. Add real candidate promotion: proposed Turtle, SHACL validation, SPARQL proof, and explicit accepted-graph write path.
3. Wire the iOS quick actions to real behavior.
4. Add actual attachment/photo/file import behind the plus button.
5. Add voice/speak behavior.
6. Make the skills/plugins/tools inventory dynamic after the static workbench surface is approved.
7. Prepare TestFlight distribution.

## Suggested First Command In A New Codex Thread

```sh
cd /Users/adamblair/Developer/GitHub/Harness
git status -sb
git pull --ff-only origin main
swift test --package-path Packages/OntologyKit
```

Then build the target being worked on:

```sh
xcodebuild -scheme Harness -destination 'platform=iOS Simulator,name=iPhone 17' build
```

or:

```sh
xcodebuild -scheme Harness -destination 'platform=macOS' build
```
