#!/usr/bin/env bash
# Nightly (or on-demand) multi-Mac GitHub workspace audit.
# Authority: Main vault "Multi-Mac GitHub Coordination.md"
# GitHub is source of truth; iCloud Documents/GitHub is forbidden for active repos.

set -euo pipefail

REPORT_DIR="${HOME}/Library/Logs/multi-mac-repo-health"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="${REPORT_DIR}/report-${STAMP}.txt"
LATEST="${REPORT_DIR}/latest.txt"
CONFIG="${HOME}/.config/adam-multi-mac/machines.conf"

mkdir -p "$REPORT_DIR" "$(dirname "$CONFIG")"

# Canonical repo root on THIS machine
if [[ -d "${HOME}/Developer/GitHub" ]]; then
  CANON="${HOME}/Developer/GitHub"
elif [[ -d "${HOME}/GitHub" ]]; then
  CANON="${HOME}/GitHub"
else
  CANON=""
fi

FORBIDDEN="${HOME}/Documents/GitHub"

REPOS=(
  Harness
  Re_Call
  Understood
  understood-app
  understood-app-public
  dblaira.github.io
  material-health
  nutrition-app
  Boring_News
)

hostname_short="$(hostname -s 2>/dev/null || hostname)"
user_id="$(id -un)"
issues=0

log() { echo "$*" | tee -a "$REPORT"; }
bump_issue() { issues=$((issues + 1)); }

: >"$REPORT"
log "=== Multi-Mac repo health ==="
log "time: $(date -Iseconds)"
log "host: ${hostname_short}"
log "user: ${user_id}"
log "canonical_root: ${CANON:-MISSING}"
log ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Skip auto-repair if run recently (avoids re-sync on every screen unlock)
SYNC_STAMP="${REPORT_DIR}/last-auto-sync"
MIN_GAP_SEC="${MULTI_MAC_SYNC_MIN_INTERVAL:-7200}"

if [[ "${MULTI_MAC_HEALTH_ONLY:-}" != "1" ]] && [[ -x "${SCRIPT_DIR}/sync-all-repos.sh" ]]; then
  run_sync=true
  if [[ -f "$SYNC_STAMP" ]]; then
    last="$(cat "$SYNC_STAMP" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if [[ "$((now - last))" -lt "$MIN_GAP_SEC" ]]; then
      log "--- Auto-repair: skipped (synced within ${MIN_GAP_SEC}s) ---"
      run_sync=false
    fi
  fi
  if [[ "$run_sync" == true ]]; then
    log "--- Auto-repair: clone missing + pull (sync-all-repos) ---"
    if "${SCRIPT_DIR}/sync-all-repos.sh" >>"$REPORT" 2>&1; then
      log "sync-all-repos: finished"
      date +%s >"$SYNC_STAMP"
    else
      log "sync-all-repos: FAILED (see log)"
      bump_issue
    fi
    log ""
  fi
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log "MISSING_CMD: $1"; bump_issue; return 1; }
}

log "--- Tooling ---"
for c in git gh brew; do
  if require_cmd "$c"; then
    case "$c" in
      brew) log "brew: $($c --version | head -1)" ;;
      gh) log "gh: $($c --version | head -1)"; gh auth status -h github.com 2>&1 | sed 's/^/  /' | tee -a "$REPORT" || bump_issue ;;
      git) log "git: $($c --version)" ;;
    esac
  fi
done
log ""

log "--- Forbidden iCloud workspace ---"
if [[ -d "$FORBIDDEN" ]]; then
  log "WARN: ${FORBIDDEN} exists (iCloud-managed). Do not use for active git."
  while IFS= read -r -d '' d; do
    [[ -d "$d/.git" ]] || continue
    rel="${d#"$FORBIDDEN"/}"
    st="$(git -C "$d" status -sb 2>/dev/null | head -1 || echo '?')"
    log "  duplicate: Documents/GitHub/${rel} -> ${st}"
    bump_issue
  done < <(find "$FORBIDDEN" -maxdepth 2 -name .git -type d -print0 2>/dev/null)
else
  log "OK: no ${FORBIDDEN}"
fi
log ""

log "--- Canonical repos (${CANON:-n/a}) ---"
if [[ -z "$CANON" ]]; then
  log "FAIL: no Developer/GitHub or ~/GitHub"
  bump_issue
else
  for name in "${REPOS[@]}"; do
    path="${CANON}/${name}"
    if [[ ! -d "$path/.git" ]]; then
      log "MISSING: ${name} (not cloned at ${path})"
      bump_issue
      continue
    fi
    git -C "$path" fetch origin --prune --quiet 2>/dev/null || true
    st="$(git -C "$path" status -sb 2>/dev/null | head -1)"
    dirty="$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$dirty" != "0" ]]; then
      log "DIRTY: ${name} (${dirty} files) ${st}"
      bump_issue
    elif [[ "$st" == *"ahead"* ]] || [[ "$st" == *"behind"* ]] || [[ "$st" == *"diverged"* ]]; then
      log "DRIFT: ${name} ${st}"
      bump_issue
    else
      log "OK: ${name} ${st}"
    fi
  done
fi
log ""

log "--- Cross-path duplicates (same repo name in Documents + canonical) ---"
if [[ -n "$CANON" && -d "$FORBIDDEN" ]]; then
  for name in "${REPOS[@]}"; do
    a="${CANON}/${name}"
    b="${FORBIDDEN}/${name}"
    [[ -d "$a/.git" && -d "$b/.git" ]] || continue
    ha="$(git -C "$a" rev-parse HEAD 2>/dev/null)"
    hb="$(git -C "$b" rev-parse HEAD 2>/dev/null)"
    if [[ "$ha" != "$hb" ]]; then
      log "SPLIT_BRAIN: ${name} canonical=${ha:0:7} documents=${hb:0:7}"
      bump_issue
    else
      log "dup_paths_same_commit: ${name} (${ha:0:7}) — still remove Documents copy when safe"
    fi
  done
fi
log ""

log "--- Remote machines (optional SSH) ---"
REMOTE_SNAPSHOT='set -e; u=$(id -un); h=$(hostname -s); if [[ -d "$HOME/Developer/GitHub" ]]; then c="$HOME/Developer/GitHub"; elif [[ -d "$HOME/GitHub" ]]; then c="$HOME/GitHub"; else c=""; fi; echo "remote host=$h user=$u canon=${c:-MISSING}"; for r in Harness Re_Call understood-app Boring_News; do p="$c/$r"; [[ -d "$p/.git" ]] || continue; git -C "$p" fetch origin -q 2>/dev/null || true; echo "  $r: $(git -C "$p" status -sb 2>/dev/null | head -1)"; done; [[ -d "$HOME/Documents/GitHub" ]] && echo "  WARN: Documents/GitHub present" || true'

if [[ -f "$CONFIG" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^# ]] && continue
    [[ -z "${line// }" ]] && continue
    host_alias="${line%% *}"
    log "ssh: ${host_alias}"
    if out="$(ssh -o BatchMode=yes -o ConnectTimeout=12 "$host_alias" bash -lc "$REMOTE_SNAPSHOT" 2>&1)"; then
      while IFS= read -r rl; do log "  $rl"; done <<<"$out"
      if grep -q 'WARN: Documents/GitHub' <<<"$out" || grep -qE 'behind|ahead|diverged' <<<"$out"; then
        bump_issue
      fi
    else
      log "  UNREACHABLE: ${host_alias}"
      log "  ${out}"
      bump_issue
    fi
  done <"$CONFIG"
else
  log "SKIP: no ${CONFIG} (copy machines.conf.example)"
fi
log ""

log "=== Summary: ${issues} issue(s) ==="
cp "$REPORT" "$LATEST"

# macOS notification when issues found (best-effort)
if [[ "$issues" -gt 0 ]] && command -v osascript >/dev/null; then
  osascript -e "display notification \"${issues} issue(s). See ${LATEST}\" with title \"Multi-Mac repo health\"" 2>/dev/null || true
fi

exit 0