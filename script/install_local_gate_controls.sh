#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$(git branch --show-current)" == "main" ]] || {
  echo "Trusted local gates may be installed only from protected main." >&2
  exit 1
}
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "Trusted local gates require a clean main checkout." >&2
  exit 1
}

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
PROTECTION="$(gh api "repos/$REPO/branches/main/protection")"
RUNNERS="$(gh api "repos/$REPO/actions/runners")"
PROTECTION="$PROTECTION" RUNNERS="$RUNNERS" python3 - <<'PY'
import json, os
required = {
    "Acceptance contract", "Gate script tests", "macOS tests, SwiftLint, Periphery",
    "CodeQL (swift)", "CodeQL (python)", "GPT-5.6 Sol review", "Signed Mac handoff",
}
protection = json.loads(os.environ["PROTECTION"])
runners = json.loads(os.environ["RUNNERS"])
actual = set(protection.get("required_status_checks", {}).get("contexts", []))
errors = []
if actual != required: errors.append("full required status context set is not installed")
if not protection.get("enforce_admins", {}).get("enabled"): errors.append("branch protection does not enforce administrators")
if runners.get("total_count") != 0: errors.append("public repository has a self-hosted runner")
if errors: raise SystemExit("; ".join(errors))
PY

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
  scripts/verify_codex_runtime.py \
  scripts/verify_app_identity.py \
  scripts/resolve_harness_repo.py \
  "$DEST/scripts/"
install -m 0644 scripts/verify_running_app.swift "$DEST/scripts/"
install -m 0644 .github/codex/review.schema.json .github/codex/sol-review.md "$DEST/.github/codex/"

# shellcheck disable=SC2016 # Generated wrapper expands ROOT when it runs.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  "ROOT=\$(/usr/bin/python3 '$DEST/scripts/resolve_harness_repo.py' --cwd \"\$PWD\")" \
  'export HARNESS_REPO_ROOT="$ROOT"' \
  "exec '$DEST/script/sol_review_gate.sh' \"\$@\"" \
  > "$BIN/harness-sol-review"
# shellcheck disable=SC2016 # Generated wrapper expands ROOT when it runs.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  "ROOT=\$(/usr/bin/python3 '$DEST/scripts/resolve_harness_repo.py' --cwd \"\$PWD\")" \
  'export HARNESS_REPO_ROOT="$ROOT"' \
  "exec '$DEST/script/handoff_gate.sh' \"\$@\"" \
  > "$BIN/harness-handoff"
# shellcheck disable=SC2016 # Generated wrapper expands ROOT when it runs.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  "ROOT=\$(/usr/bin/python3 '$DEST/scripts/resolve_harness_repo.py' --cwd \"\$PWD\" 2>/dev/null || true)" \
  'if [[ -z "$ROOT" ]]; then printf '\''%s\n'\'' '\''{"continue":true}'\''; exit 0; fi' \
  'cd "$ROOT"' \
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
