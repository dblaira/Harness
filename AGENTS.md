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

## Review guidelines

- Treat Adam's literal requirement and named visible surface as the acceptance test.
- Report a missing or weakened acceptance contract as P1.
- Report a skipped dependency, fail-open guard, swallowed error, or success claim without proof as P1.
- A build, typecheck, backend response, or unit test does not prove visible app behavior.
- Every changed critical flow needs UI automation or recorded execution in the signed app on Adam's Mac.
- Evidence must identify the exact reviewed commit. Evidence from another commit is invalid.
- Review relevant signing, entitlement, TCC, stale-process, provider/auth, and accepted-graph authority boundaries.
- Independent review is a merge gate, not the release oracle. The signed visible handoff is a separate gate.
- Run independent review only with the immutable installed command `harness-sol-review`; never execute a pull request's copy of the issuer.
- Run signed handoff only with the immutable installed command `harness-handoff`; never let proposed code publish its own required status.
- Treat hosted status and check names as untrusted until the immutable local aggregator verifies workflow path, event, run, exact SHA, creator, and evidence binding.
- Merge only with the immutable installed command `harness-merge PR_NUMBER`; never use direct push, the GitHub merge button, or `gh pr merge` for Harness.
- Never add or request an `OPENAI_API_KEY` for review. Adam intentionally blocks API keys so agents cannot choose separate API billing over his subscription.
- Never configure Adam's Mac as a GitHub self-hosted runner for this public repository.
- Threat model: Adam's authenticated macOS session and `dblaira` GitHub administrator identity are trusted operator boundaries. The gates prevent accidental, careless, stale, or unreviewed handoffs; they do not claim cryptographic resistance to a malicious actor already controlling Adam's administrator credential. Do not require Touch ID or classify that explicitly accepted operator capability as a release defect.
