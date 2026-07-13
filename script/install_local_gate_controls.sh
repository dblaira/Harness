#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
ROOT_DIR="$(python3 scripts/resolve_harness_repo.py --cwd "$ROOT_DIR" --require-ref refs/heads/main)"
[[ "$(git branch --show-current)" == "main" ]] || {
  echo "Trusted local gates may be installed only from protected main." >&2
  exit 1
}
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "Trusted local gates require a clean main checkout." >&2
  exit 1
}

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
python3 scripts/verify_repository_gate_state.py --repo "$REPO"

VERSION="$(git rev-parse HEAD)"
DEST="$HOME/.local/share/harness-release-gates/$VERSION"
BIN="$HOME/.local/bin"
mkdir -p "$DEST/script" "$DEST/scripts" "$DEST/.github/codex" "$BIN"
install -m 0755 script/sol_review_gate.sh script/handoff_gate.sh script/hosted_verification_gate.sh script/merge_verified_pr.sh "$DEST/script/"
install -m 0755 \
  scripts/release_gate.py \
  scripts/evidence_binding.py \
  scripts/live_satisfaction_oracle.py \
  scripts/select_pull_request.py \
  scripts/sanitize_review_bundle.py \
  scripts/swift_test_inventory.py \
  scripts/render_sol_review.py \
  scripts/require_latest_status.py \
  scripts/run_with_timeout.py \
  scripts/validate_acceptance_contract.py \
  scripts/validate_sol_review.py \
  scripts/validate_xcresult.py \
  scripts/validate_swiftpm_tests.py \
  scripts/verify_codex_auth.py \
  scripts/verify_codex_runtime.py \
  scripts/verify_control_bundle.py \
  scripts/verify_repository_gate_state.py \
  scripts/verify_hosted_evidence.py \
  scripts/verify_merge_authority.py \
  scripts/verify_app_identity.py \
  scripts/validate_media.py \
  scripts/resolve_harness_repo.py \
  scripts/route_stop_gate.py \
  "$DEST/scripts/"
install -m 0644 scripts/verify_running_app.swift "$DEST/scripts/"
install -m 0644 scripts/preflight_tcc.swift "$DEST/scripts/"
install -m 0644 .github/codex/review.schema.json .github/codex/sol-review.md "$DEST/.github/codex/"

DEST="$DEST" /usr/bin/python3 - <<'PY'
import hashlib, json, os
from pathlib import Path
root = Path(os.environ["DEST"])
files = {}
for path in sorted(root.rglob("*")):
    if path.is_file() and path.name != "control-manifest.json":
        files[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
(root / "control-manifest.json").write_text(json.dumps({"files": files}, indent=2) + "\n", encoding="utf-8")
PY

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
  'set +e' \
  "ROOT=\$(/usr/bin/python3 '$DEST/scripts/route_stop_gate.py' --cwd \"\$PWD\" --installed-root '$ROOT_DIR')" \
  'ROUTE_STATUS=$?' \
  'set -e' \
  'if [[ "$ROUTE_STATUS" == 10 ]]; then printf '\''%s\n'\'' '\''{"continue":true}'\''; exit 0; fi' \
  'if [[ "$ROUTE_STATUS" != 0 ]]; then printf '\''%s\n'\'' '\''{"continue":false,"reason":"Harness repository inspection failed; release evidence is required before stopping."}'\''; exit 0; fi' \
  'cd "$ROOT"' \
  "exec /usr/bin/python3 '$DEST/scripts/release_gate.py' hook" \
  > "$BIN/harness-stop-gate"
chmod 0755 "$BIN/harness-sol-review" "$BIN/harness-handoff" "$BIN/harness-stop-gate"
# shellcheck disable=SC2016 # Generated wrapper expands ROOT when it runs.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  "ROOT=\$(/usr/bin/python3 '$DEST/scripts/resolve_harness_repo.py' --cwd \"\$PWD\")" \
  'export HARNESS_REPO_ROOT="$ROOT"' \
  "exec '$DEST/script/merge_verified_pr.sh' \"\$@\"" \
  > "$BIN/harness-merge"
chmod 0755 "$BIN/harness-merge"

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
hooks[:] = [entry for entry in hooks if not any(
    hook.get("command") == command for hook in entry.get("hooks", []) if isinstance(hook, dict)
)]
hooks.append({"hooks": [{"type": "command", "command": command, "timeout": 300}]})
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY

ln -sfn "$DEST" "$HOME/.local/share/harness-release-gates/current"
echo "Installed immutable Harness gate controls from protected main commit $VERSION."
