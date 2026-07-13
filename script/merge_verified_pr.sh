#!/usr/bin/env bash
set -euo pipefail

CONTROL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="${HARNESS_REPO_ROOT:-$(pwd)}"
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"
cd "$ROOT_DIR"
[[ $# -eq 1 && "$1" =~ ^[0-9]+$ ]] || { echo "usage: $0 PR_NUMBER" >&2; exit 2; }
PR_NUMBER="$1"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || { echo "Merge requires a clean checkout." >&2; exit 1; }
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
PR_JSON="$(gh api "repos/$REPO/pulls/$PR_NUMBER")"
SHA="$(printf '%s' "$PR_JSON" | jq -r .head.sha)"
BASE_SHA="$(printf '%s' "$PR_JSON" | jq -r .base.sha)"
[[ "$(printf '%s' "$PR_JSON" | jq -r .base.ref)" == main ]] || { echo "Pull request does not target main." >&2; exit 1; }
[[ "$(printf '%s' "$PR_JSON" | jq -r .head.repo.full_name)" == "$REPO" ]] || { echo "Fork pull requests cannot use the signed local merge gate." >&2; exit 1; }
[[ "$(printf '%s' "$PR_JSON" | jq -r .head.ref)" == codex/* ]] || { echo "Pull request is not on an agent-owned codex/ branch." >&2; exit 1; }
[[ "$(git rev-parse HEAD)" == "$SHA" ]] || { echo "Local checkout is not the exact pull-request head." >&2; exit 1; }
python3 "$CONTROL_DIR/scripts/verify_repository_gate_state.py" --repo "$REPO"
python3 "$CONTROL_DIR/scripts/verify_control_bundle.py" --manifest "$CONTROL_DIR/control-manifest.json" \
  --control-dir "$CONTROL_DIR" --repo-root "$ROOT_DIR" --base-sha "$BASE_SHA"
CONTRACT_DIGEST="$(python3 -c 'import json,sys;sys.path.insert(0,sys.argv[1]);import validate_acceptance_contract as v;print(v.contract_digest(json.load(open(sys.argv[2]))))' "$CONTROL_DIR/scripts" .github/acceptance-contract.json)"
BINDING="$(python3 "$CONTROL_DIR/scripts/evidence_binding.py" --repo "$REPO" --pr-number "$PR_NUMBER" --base-sha "$BASE_SHA" --head-sha "$SHA" --contract-digest "$CONTRACT_DIGEST")"
if ! "$CONTROL_DIR/script/hosted_verification_gate.sh"; then
  echo "Fresh hosted evidence verification failed; merge authority was not evaluated." >&2
  exit 1
fi
MANIFEST="$HOME/.local/share/harness-release-evidence/Harness/$SHA/manifest.json"
python3 "$CONTROL_DIR/scripts/release_gate.py" validate --manifest "$MANIFEST"
gh api "repos/$REPO/commits/$SHA/statuses?per_page=100" | \
  python3 "$CONTROL_DIR/scripts/verify_merge_authority.py" --marker "pr:$PR_NUMBER binding:${BINDING:0:24}"
gh pr merge "$PR_NUMBER" --repo "$REPO" --merge --delete-branch --match-head-commit "$SHA"
