
## Multi-Mac repo sync

Nightly health check and install: see Main vault [[Multi-Mac GitHub Coordination]].

- `scripts/multi-mac-repo-health.sh` — runs **sync-all-repos** first (clone missing + pull), then audit. Set `MULTI_MAC_HEALTH_ONLY=1` to skip auto-repair.
- `scripts/install-multi-mac-nightly.sh` — LaunchAgent 23:30 local.
- `scripts/machines.conf.example` → `~/.config/adam-multi-mac/machines.conf`