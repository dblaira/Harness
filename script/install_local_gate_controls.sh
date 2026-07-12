#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
BRANCH="$(git branch --show-current)"
if [[ "$BRANCH" != "main" ]]; then
  [[ "${1:-}" == "--bootstrap-pr" && "${2:-}" == "19" ]] || {
    echo "Trusted local gates may be installed only from protected main." >&2
    exit 1
  }
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
  SHA="$(git rev-parse HEAD)"
  PR_JSON="$(gh api "repos/$REPO/pulls/19")"
  [[ "$REPO" == "dblaira/Harness" \
      && "$(printf '%s' "$PR_JSON" | jq -r .base.sha)" == "0ce97219a340d9a53f5afb2a773bb2c9eb81b807" \
      && "$(printf '%s' "$PR_JSON" | jq -r .head.sha)" == "$SHA" \
      && "$(printf '%s' "$PR_JSON" | jq -r .state)" == "open" ]] || {
    echo "Bootstrap install is restricted to the reviewed Harness PR #19 revisions." >&2
    exit 1
  }
fi
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "Trusted local gates require a clean main checkout." >&2
  exit 1
}

VERSION="$(git rev-parse HEAD)"
DEST="$HOME/.local/share/harness-release-gates/$VERSION"
BIN="$HOME/.local/bin"
mkdir -p "$DEST/script" "$DEST/scripts" "$DEST/.github/codex" "$BIN"
install -m 0755 script/sol_review_gate.sh script/handoff_gate.sh "$DEST/script/"
install -m 0755 \
  scripts/release_gate.py \
  scripts/render_sol_review.py \
  scripts/require_latest_status.py \
  scripts/run_with_timeout.py \
  scripts/validate_acceptance_contract.py \
  scripts/validate_sol_review.py \
  scripts/validate_xcresult.py \
  scripts/verify_codex_auth.py \
  "$DEST/scripts/"
install -m 0644 .github/codex/review.schema.json .github/codex/sol-review.md "$DEST/.github/codex/"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  "export HARNESS_REPO_ROOT='$ROOT_DIR'" \
  "exec '$DEST/script/sol_review_gate.sh' \"\$@\"" \
  > "$BIN/harness-sol-review"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  "export HARNESS_REPO_ROOT='$ROOT_DIR'" \
  "exec '$DEST/script/handoff_gate.sh' \"\$@\"" \
  > "$BIN/harness-handoff"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  "ROOT='\$(git rev-parse --show-toplevel 2>/dev/null || true)'" \
  "if [[ \"\$ROOT\" != '$ROOT_DIR' ]]; then printf '%s\\n' '{\"continue\":true}'; exit 0; fi" \
  "exec /usr/bin/python3 '$DEST/scripts/release_gate.py' hook" \
  > "$BIN/harness-stop-gate"
chmod 0755 "$BIN/harness-sol-review" "$BIN/harness-handoff" "$BIN/harness-stop-gate"

HOOKS_FILE="$HOME/.codex/hooks.json"
HOOKS_FILE="$HOOKS_FILE" python3 - <<'PY'
import json, os
from pathlib import Path
path = Path(os.environ["HOOKS_FILE"])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except FileNotFoundError:
    data = {}
hooks = data.setdefault("hooks", {}).setdefault("Stop", [])
command = str(Path.home() / ".local/bin/harness-stop-gate")
entry = {"hooks": [{"type": "command", "command": command, "timeout": 30}]}
if entry not in hooks:
    hooks.append(entry)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY

ln -sfn "$DEST" "$HOME/.local/share/harness-release-gates/current"
echo "Installed immutable Harness gate controls from protected main commit $VERSION."
