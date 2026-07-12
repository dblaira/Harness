#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${HARNESS_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT_DIR"
[[ "$(git branch --show-current)" == "main" && -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "Merge-gate probes require a clean protected main checkout." >&2
  exit 1
}
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
MAIN_SHA="$(git rev-parse HEAD)"
PROBE_BASE="codex/gate-probe-base-${MAIN_SHA:0:8}"
PROBE_HEAD="codex/gate-probe-head-${MAIN_SHA:0:8}"
OUTPUT_DIR="$ROOT_DIR/.local-artifacts/github-protection/$MAIN_SHA/rejection-probes"
mkdir -p "$OUTPUT_DIR"
PR_NUMBER=""

cleanup() {
  git switch main >/dev/null 2>&1 || true
  [[ -z "$PR_NUMBER" ]] || gh pr close "$PR_NUMBER" >/dev/null 2>&1 || true
  gh api -X DELETE "repos/$REPO/branches/$PROBE_BASE/protection" >/dev/null 2>&1 || true
  gh api -X DELETE "repos/$REPO/git/refs/heads/$PROBE_HEAD" >/dev/null 2>&1 || true
  gh api -X DELETE "repos/$REPO/git/refs/heads/$PROBE_BASE" >/dev/null 2>&1 || true
  git branch -D "$PROBE_HEAD" "$PROBE_BASE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git branch "$PROBE_BASE" "$MAIN_SHA"
git push git@github.com:dblaira/Harness.git "$PROBE_BASE:$PROBE_BASE"
[[ "$(git ls-remote origin "refs/heads/$PROBE_BASE" | cut -f1)" == "$MAIN_SHA" ]] || {
  echo "Disposable protected base is not synchronized to local main." >&2
  exit 1
}

python3 - "$OUTPUT_DIR/probe-protection.json" <<'PY'
import json, sys
payload = {
    "required_status_checks": {"strict": True, "contexts": ["Deliberately missing probe check"]},
    "enforce_admins": True,
    "required_pull_request_reviews": {
        "dismiss_stale_reviews": True,
        "require_code_owner_reviews": False,
        "required_approving_review_count": 0,
        "require_last_push_approval": False,
    },
    "restrictions": None,
    "required_conversation_resolution": True,
    "allow_force_pushes": False,
    "allow_deletions": False,
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
gh api -X PUT "repos/$REPO/branches/$PROBE_BASE/protection" \
  --input "$OUTPUT_DIR/probe-protection.json" >/dev/null

git switch -c "$PROBE_HEAD" "$MAIN_SHA"
git commit --allow-empty -m "Gate rejection probe"
PROBE_SHA="$(git rev-parse HEAD)"
git push git@github.com:dblaira/Harness.git "$PROBE_HEAD:$PROBE_HEAD"
[[ "$(git ls-remote origin "refs/heads/$PROBE_HEAD" | cut -f1)" == "$PROBE_SHA" ]] || {
  echo "Disposable probe head is not synchronized to its remote." >&2
  exit 1
}
PR_URL="$(gh pr create --base "$PROBE_BASE" --head "$PROBE_HEAD" --title 'Gate rejection probe' --body 'Disposable branch-protection probe with a deliberately missing required check.')"
PR_NUMBER="${PR_URL##*/}"

set +e
git push git@github.com:dblaira/Harness.git "$PROBE_SHA:refs/heads/$PROBE_BASE" > "$OUTPUT_DIR/direct-push.log" 2>&1
DIRECT_RESULT=$?
git push --force-with-lease git@github.com:dblaira/Harness.git "$PROBE_SHA:refs/heads/$PROBE_BASE" > "$OUTPUT_DIR/force-push.log" 2>&1
FORCE_RESULT=$?
for METHOD in merge squash rebase; do
  gh api -X PUT "repos/$REPO/pulls/$PR_NUMBER/merge" -f merge_method="$METHOD" \
    > "$OUTPUT_DIR/$METHOD-merge.log" 2>&1
  printf '%s\n' "$?" > "$OUTPUT_DIR/$METHOD-result.txt"
done
set -e

DIRECT_RESULT="$DIRECT_RESULT" FORCE_RESULT="$FORCE_RESULT" OUTPUT_DIR="$OUTPUT_DIR" PR_NUMBER="$PR_NUMBER" python3 - <<'PY'
import json, os, re
from pathlib import Path

root = Path(os.environ["OUTPUT_DIR"])
push_rejection = re.compile(r"GH0(?:06|13)|protected branch|repository rule violations", re.I)
merge_rejection = re.compile(r"required status check|protected branch|not mergeable|merge cannot be performed", re.I)

def rejected(result: int, log_name: str, pattern: re.Pattern[str]) -> bool:
    text = (root / log_name).read_text(encoding="utf-8", errors="replace")
    return result != 0 and bool(pattern.search(text))

results = {
    "direct_push_rejected": rejected(int(os.environ["DIRECT_RESULT"]), "direct-push.log", push_rejection),
    "force_push_rejected": rejected(int(os.environ["FORCE_RESULT"]), "force-push.log", push_rejection),
    "missing_check_merge_rejected": rejected(int((root / "merge-result.txt").read_text()), "merge-merge.log", merge_rejection),
    "squash_rejected": rejected(int((root / "squash-result.txt").read_text()), "squash-merge.log", merge_rejection),
    "rebase_rejected": rejected(int((root / "rebase-result.txt").read_text()), "rebase-merge.log", merge_rejection),
    "probe_pull_request": int(os.environ["PR_NUMBER"]),
    "production_main_untouched": True,
}
required = [value for key, value in results.items() if key.endswith("rejected")]
results["status"] = "PASS" if all(required) else "FAIL"
(root / "rejection-attestation.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results, indent=2))
if results["status"] != "PASS":
    raise SystemExit("one or more delivery attempts lacked the exact branch-protection rejection")
PY

[[ "$(git ls-remote origin refs/heads/main | cut -f1)" == "$MAIN_SHA" ]] || {
  echo "Production main changed during the disposable rejection probe." >&2
  exit 1
}
echo "Disposable protected branches rejected direct, force, missing-check, squash, and rebase delivery paths; main was untouched."
