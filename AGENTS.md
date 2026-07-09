# Agent notes

## Cursor Cloud: Mac access via Tailscale

If secrets `TAILSCALE_AUTHKEY` and `TAILSCALE_SSH_KEY` are set, cloud agents join Adam's private Tailscale network on start.

Then use:
- `ssh studio` — Mac Studio (`blairstudio@100.102.153.54`) — primary build machine
- `ssh mbp` — MacBook Pro (`adamblair@100.111.154.126`)
- `ssh mbp2` — MacBook Pro 2 (`adamblair@100.88.144.50`)

Use these for anything that must run on a Mac (Xcode, local files, Simulator). Prefer `studio` for builds.

