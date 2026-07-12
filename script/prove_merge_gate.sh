#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${HARNESS_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT_DIR"
[[ "$(git branch --show-current)" == "main" && -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "Merge-gate probes require a clean protected main checkout." >&2
  exit 1
}
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
PROTECTION="$(gh api "repos/$REPO/branches/main/protection")"
[[ "$(printf '%s' "$PROTECTION" | jq -r .enforce_admins.enabled)" == true \
    && "$(printf '%s' "$PROTECTION" | jq -r .required_pull_request_reviews.url)" != null \
    && "$(printf '%s' "$PROTECTION" | jq -r .allow_force_pushes.enabled)" == false ]] || {
  echo "Refusing probes because live main protection is not fail-closed for admins." >&2
  exit 1
}

MAIN_SHA="$(git rev-parse HEAD)"
BRANCH="codex/gate-rejection-probe-${MAIN_SHA:0:8}"
OUTPUT_DIR="$ROOT_DIR/.local-artifacts/github-protection/$MAIN_SHA/rejection-probes"
mkdir -p "$OUTPUT_DIR"
PR_NUMBER=""
cleanup() {
  git switch main >/dev/null 2>&1 || true
  [[ -z "$PR_NUMBER" ]] || gh pr close "$PR_NUMBER" --delete-branch >/dev/null 2>&1 || true
  git branch -D "$BRANCH" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git switch -c "$BRANCH"
git commit --allow-empty -m "Gate rejection probe"
git push git@github.com:dblaira/Harness.git "$BRANCH"
PR_NUMBER="$(gh pr create --base main --head "$BRANCH" --title 'Gate rejection probe' --body 'Deliberately incomplete probe. Every protected check must block this PR.')"
PR_NUMBER="${PR_NUMBER##*/}"

set +e
git push git@github.com:dblaira/Harness.git HEAD:main > "$OUTPUT_DIR/direct-push.log" 2>&1
DIRECT_RESULT=$?
git push --force-with-lease git@github.com:dblaira/Harness.git HEAD:main > "$OUTPUT_DIR/force-push.log" 2>&1
FORCE_RESULT=$?
for METHOD in merge squash rebase; do
  gh api -X PUT "repos/$REPO/pulls/$PR_NUMBER/merge" -f merge_method="$METHOD" \
    > "$OUTPUT_DIR/$METHOD-merge.log" 2>&1
  printf '%s\n' "$?" > "$OUTPUT_DIR/$METHOD-result.txt"
done
set -e

DIRECT_RESULT="$DIRECT_RESULT" FORCE_RESULT="$FORCE_RESULT" OUTPUT_DIR="$OUTPUT_DIR" PR_NUMBER="$PR_NUMBER" python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ["OUTPUT_DIR"])
results = {
    "direct_push_rejected": int(os.environ["DIRECT_RESULT"]) != 0,
    "force_push_rejected": int(os.environ["FORCE_RESULT"]) != 0,
    "missing_check_merge_rejected": int((root / "merge-result.txt").read_text()) != 0,
    "squash_rejected": int((root / "squash-result.txt").read_text()) != 0,
    "rebase_rejected": int((root / "rebase-result.txt").read_text()) != 0,
    "probe_pull_request": int(os.environ["PR_NUMBER"]),
}
results["status"] = "PASS" if all(value for key, value in results.items() if key.endswith("rejected")) else "FAIL"
(root / "rejection-attestation.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results, indent=2))
if results["status"] != "PASS":
    raise SystemExit("one or more forbidden delivery paths was not rejected")
PY

echo "Protected main rejected direct, force, missing-check, squash, and rebase delivery paths."
