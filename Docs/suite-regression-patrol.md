# Understood Suite Regression Patrol

This is the deterministic test runner that Codex operates on Adam's Macs. It is
not a GitHub self-hosted runner and it does not let an AI agent decide whether a
test passed.

## Contract

- Every app is checked from an exact fetched `main` commit in a disposable Git
  worktree. Adam's active repos and uncommitted changes are never used or edited.
- A command exit, timeout, missing dependency, or failed checkout is `FAIL`.
- A named visible requirement with no executable test is `INCOMPLETE`, never
  green.
- Reports include the exact commit for every app and links to every raw log.
- Generated evidence stays outside source control under
  `~/Library/Logs/Harness/SuiteRegression/`.
- The patrol never promotes an ontology candidate or writes to the accepted
  graph.

## Profiles

- `smoke`: code tests, native builds, Swift package tests, and safe deployed API
  contracts.
- `full`: smoke plus native Xcode unit/UI flows and the live Harness
  Fuseki/Ollama satisfaction gate.
- `stress`: full, with checks marked safe for repetition executed multiple
  times.

## Commands

```sh
./scripts/install-suite-regression.sh
harness-suite-regression --profile smoke --notify
harness-suite-regression --profile full --notify
harness-suite-regression --profile stress --stress-repetitions 3 --notify
```

The installed command is the stable entry point used by the Codex recurring
automation. The automation may diagnose a failure and prepare a repair branch,
but it must not call a failed test green or merge its own repair.
