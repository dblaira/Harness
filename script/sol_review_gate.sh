#!/usr/bin/env bash
set -euo pipefail

CONTROL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="${HARNESS_REPO_ROOT:-$(pwd)}"
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"
cd "$ROOT_DIR"

[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "Commit or remove every working-tree change before independent review." >&2
  exit 1
}

SHA="$(git rev-parse HEAD)"
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
PR_NUMBER="$(gh api "repos/$REPO/commits/$SHA/pulls" --jq '[.[] | select(.state == "open")] | first | .number')"
[[ -n "$PR_NUMBER" && "$PR_NUMBER" != "null" ]] || {
  echo "No open pull request is bound to commit $SHA." >&2
  exit 1
}
BASE_SHA="$(gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .base.sha)"
HEAD_SHA="$(gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .head.sha)"
[[ "$HEAD_SHA" == "$SHA" ]] || {
  echo "The open pull request head does not match local HEAD." >&2
  exit 1
}

OUTPUT_DIR="$ROOT_DIR/.local-artifacts/sol-review/$SHA"
BUNDLE="$OUTPUT_DIR/review-bundle"
PROMPT="$OUTPUT_DIR/sol-review-prompt.md"
REVIEW="$OUTPUT_DIR/sol-review.json"
LOG="$OUTPUT_DIR/codex-review.log"
COMMENT="$OUTPUT_DIR/github-comment.md"
AUTH_PROOF="$OUTPUT_DIR/authorization.json"
RUNTIME_PROOF="$OUTPUT_DIR/codex-runtime.json"
CONTRACT="$ROOT_DIR/.github/acceptance-contract.json"
rm -rf "$OUTPUT_DIR"
mkdir -p "$BUNDLE/base" "$BUNDLE/head"

[[ -f "$CONTRACT" ]] || { echo "Checked-in acceptance contract is missing." >&2; exit 1; }
gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .body > "$OUTPUT_DIR/reviewed-pr-body.md"
python3 "$CONTROL_DIR/scripts/validate_acceptance_contract.py" \
  --contract-json "$CONTRACT" \
  --pr-body-file "$OUTPUT_DIR/reviewed-pr-body.md" \
  --repo "$REPO" \
  --pr-number "$PR_NUMBER" \
  --base-sha "$BASE_SHA"
CONTRACT_DIGEST="$(python3 -c 'import json,sys;sys.path.insert(0,sys.argv[1]);import validate_acceptance_contract as v;print(v.contract_digest(json.load(open(sys.argv[2]))))' "$CONTROL_DIR/scripts" "$CONTRACT")"
PR_CONTRACT_DIGEST="$(python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import validate_acceptance_contract as v;print(v.pr_contract_digest(open(sys.argv[2]).read()))' "$CONTROL_DIR/scripts" "$OUTPUT_DIR/reviewed-pr-body.md")"

AUTH_FILE="${CODEX_HOME:-$HOME/.codex}/auth.json"
python3 "$CONTROL_DIR/scripts/verify_codex_auth.py" --auth-file "$AUTH_FILE" --output "$AUTH_PROOF"

git archive "$BASE_SHA" | tar -x -C "$BUNDLE/base"
git archive "$HEAD_SHA" | tar -x -C "$BUNDLE/head"
git diff --binary --find-renames "$BASE_SHA...$HEAD_SHA" > "$BUNDLE/changes.patch"
find "$BUNDLE/base" "$BUNDLE/head" -name AGENTS.md -type f -delete
git show "$BASE_SHA:AGENTS.md" > "$BUNDLE/AGENTS.md"
cp "$CONTROL_DIR/.github/codex/sol-review.md" "$PROMPT"
{
  printf '\nBase SHA: %s\nHead SHA: %s\n' "$BASE_SHA" "$HEAD_SHA"
  printf '\nUntrusted pull request title:\n'
  gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .title
  printf '\nUntrusted pull request body:\n'
  gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .body
} >> "$PROMPT"

gh api -X POST "repos/$REPO/statuses/$SHA" \
  -f state=pending \
  -f context='GPT-5.6 Sol review' \
  -f description="ChatGPT Sol review pending contract:${CONTRACT_DIGEST:0:12}" \
  -f target_url="https://github.com/$REPO/pull/$PR_NUMBER" >/dev/null

set +e
env -u OPENAI_API_KEY -u OPENAI_BASE_URL -u OPENAI_API_BASE -u AZURE_OPENAI_API_KEY \
  -u ANTHROPIC_API_KEY -u GEMINI_API_KEY -u GOOGLE_API_KEY -u GROQ_API_KEY \
  -u MISTRAL_API_KEY -u TOGETHER_API_KEY -u DEEPSEEK_API_KEY -u XAI_API_KEY \
  codex exec \
  --cd "$BUNDLE" \
  --model gpt-5.6-sol \
  --sandbox read-only \
  --ephemeral \
  --ignore-user-config \
  --config 'model_provider="openai"' \
  --config 'model_reasoning_effort="max"' \
  --output-schema "$CONTROL_DIR/.github/codex/review.schema.json" \
  --output-last-message "$REVIEW" \
  - < "$PROMPT" > "$LOG" 2>&1
CODEX_RESULT=$?
if ! python3 "$CONTROL_DIR/scripts/verify_codex_runtime.py" \
  --log "$LOG" --output "$RUNTIME_PROOF"; then
  CODEX_RESULT=1
fi
VALIDATION_RESULT=1
if [[ $CODEX_RESULT -eq 0 && -s "$REVIEW" ]]; then
  python3 "$CONTROL_DIR/scripts/validate_sol_review.py" \
    --review "$REVIEW" \
    --expected-base "$BASE_SHA" \
    --expected-head "$HEAD_SHA"
  VALIDATION_RESULT=$?
fi
set -e

gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .body > "$OUTPUT_DIR/current-pr-body.md"
CURRENT_DIGEST="$(python3 -c 'import json,sys;sys.path.insert(0,sys.argv[1]);import validate_acceptance_contract as v;print(v.contract_digest(json.load(open(sys.argv[2]))))' "$CONTROL_DIR/scripts" "$CONTRACT")"
CURRENT_PR_CONTRACT_DIGEST="$(python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import validate_acceptance_contract as v;print(v.pr_contract_digest(open(sys.argv[2]).read()))' "$CONTROL_DIR/scripts" "$OUTPUT_DIR/current-pr-body.md")"
if [[ "$CURRENT_PR_CONTRACT_DIGEST" != "$PR_CONTRACT_DIGEST" || "$CURRENT_DIGEST" != "$CONTRACT_DIGEST" ]]; then
  CODEX_RESULT=1
  echo "Pull request or checked-in contract changed during review; stale result rejected." >> "$LOG"
fi

STATE=failure
if [[ $CODEX_RESULT -eq 0 && $VALIDATION_RESULT -eq 0 ]]; then
  STATE=success
fi
python3 "$CONTROL_DIR/scripts/render_sol_review.py" \
  --review "$REVIEW" \
  --output "$COMMENT" \
  --base "$BASE_SHA" \
  --head "$HEAD_SHA" \
  --state "$STATE"
COMMENT_URL="$(gh api -X POST "repos/$REPO/issues/$PR_NUMBER/comments" -f body="$(<"$COMMENT")" --jq .html_url)"
gh api -X POST "repos/$REPO/statuses/$SHA" \
  -f state="$STATE" \
  -f context='GPT-5.6 Sol review' \
  -f description="ChatGPT Sol $STATE contract:${CONTRACT_DIGEST:0:12}" \
  -f target_url="$COMMENT_URL" >/dev/null

gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .body > "$OUTPUT_DIR/final-pr-body.md"
FINAL_PR_CONTRACT_DIGEST="$(python3 -c 'import sys;sys.path.insert(0,sys.argv[1]);import validate_acceptance_contract as v;print(v.pr_contract_digest(open(sys.argv[2]).read()))' "$CONTROL_DIR/scripts" "$OUTPUT_DIR/final-pr-body.md")"
if [[ "$FINAL_PR_CONTRACT_DIGEST" != "$PR_CONTRACT_DIGEST" ]]; then
  gh api -X POST "repos/$REPO/statuses/$SHA" \
    -f state=pending \
    -f context='GPT-5.6 Sol review' \
    -f description='PR changed during review publication; fresh review required' \
    -f target_url="https://github.com/$REPO/pull/$PR_NUMBER" >/dev/null
  exit 1
fi

[[ "$STATE" == success ]] || exit 1
echo "Published passing independent Sol review for $SHA: $COMMENT_URL"
