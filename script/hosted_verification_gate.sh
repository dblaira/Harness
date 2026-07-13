#!/usr/bin/env bash
set -euo pipefail

CONTROL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="${HARNESS_REPO_ROOT:-$(pwd)}"
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"
cd "$ROOT_DIR"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "Hosted evidence aggregation requires a clean exact-head checkout." >&2
  exit 1
}
SHA="$(git rev-parse HEAD)"
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
PR_JSON="$(gh api "repos/$REPO/commits/$SHA/pulls" | python3 "$CONTROL_DIR/scripts/select_pull_request.py" --head-sha "$SHA")"
PR_NUMBER="$(printf '%s' "$PR_JSON" | jq -r .number)"
BASE_SHA="$(printf '%s' "$PR_JSON" | jq -r .base.sha)"
CONTRACT="$ROOT_DIR/.github/acceptance-contract.json"
CONTRACT_DIGEST="$(python3 -c 'import json,sys;sys.path.insert(0,sys.argv[1]);import validate_acceptance_contract as v;print(v.contract_digest(json.load(open(sys.argv[2]))))' "$CONTROL_DIR/scripts" "$CONTRACT")"
EVIDENCE_BINDING="$(python3 "$CONTROL_DIR/scripts/evidence_binding.py" --repo "$REPO" --pr-number "$PR_NUMBER" --base-sha "$BASE_SHA" --head-sha "$SHA" --contract-digest "$CONTRACT_DIGEST")"
OUTPUT_DIR="$ROOT_DIR/.local-artifacts/hosted-verification/$SHA"
REPORT="$OUTPUT_DIR/report.json"
mkdir -p "$OUTPUT_DIR"
gh api -X POST "repos/$REPO/statuses/$SHA" \
  -f state=pending -f context='Trusted hosted verification' \
  -f description="Hosted evidence pending pr:$PR_NUMBER binding:${EVIDENCE_BINDING:0:24}" \
  -f target_url="https://github.com/$REPO/pull/$PR_NUMBER" >/dev/null
STATE=failure
if python3 "$CONTROL_DIR/scripts/verify_hosted_evidence.py" \
  --repo "$REPO" --repo-root "$ROOT_DIR" --base-sha "$BASE_SHA" --head-sha "$SHA" \
  --pr-number "$PR_NUMBER" --output "$REPORT"; then
  STATE=success
fi
COMMENT_URL="$(gh api -X POST "repos/$REPO/issues/$PR_NUMBER/comments" \
  -f body="Trusted hosted verification: **${STATE^^}** for \`$SHA\`.\n\n\`$(jq -c . "$REPORT")\`" --jq .html_url)"
gh api -X POST "repos/$REPO/statuses/$SHA" \
  -f state="$STATE" -f context='Trusted hosted verification' \
  -f description="Hosted evidence $STATE pr:$PR_NUMBER binding:${EVIDENCE_BINDING:0:24}" \
  -f target_url="$COMMENT_URL" >/dev/null
[[ "$STATE" == success ]]
