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

