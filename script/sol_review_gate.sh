#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
rm -rf "$OUTPUT_DIR"
mkdir -p "$BUNDLE/base" "$BUNDLE/head"

git archive "$BASE_SHA" | tar -x -C "$BUNDLE/base"
git archive "$HEAD_SHA" | tar -x -C "$BUNDLE/head"
git diff --binary --find-renames "$BASE_SHA...$HEAD_SHA" > "$BUNDLE/changes.patch"
find "$BUNDLE/base" "$BUNDLE/head" -name AGENTS.md -type f -delete
git show "$BASE_SHA:AGENTS.md" > "$BUNDLE/AGENTS.md"
cp .github/codex/sol-review.md "$PROMPT"
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
  -f description='Independent local ChatGPT-authorized review is running' \
  -f target_url="https://github.com/$REPO/pull/$PR_NUMBER" >/dev/null

set +e
codex exec \
  --cd "$BUNDLE" \
  --model gpt-5.6-sol \
  --sandbox read-only \
  --ephemeral \
  --config 'model_reasoning_effort="max"' \
  --output-schema "$ROOT_DIR/.github/codex/review.schema.json" \
  --output-last-message "$REVIEW" \
  - < "$PROMPT" 2>&1 | tee "$LOG"
CODEX_RESULT=${PIPESTATUS[0]}
VALIDATION_RESULT=1
if [[ $CODEX_RESULT -eq 0 && -s "$REVIEW" ]]; then
  python3 scripts/validate_sol_review.py \
    --review "$REVIEW" \
    --expected-base "$BASE_SHA" \
    --expected-head "$HEAD_SHA"
  VALIDATION_RESULT=$?
fi
set -e

STATE=failure
if [[ $CODEX_RESULT -eq 0 && $VALIDATION_RESULT -eq 0 ]]; then
  STATE=success
fi
python3 scripts/render_sol_review.py \
  --review "$REVIEW" \
  --output "$COMMENT" \
  --base "$BASE_SHA" \
  --head "$HEAD_SHA" \
  --state "$STATE"
COMMENT_URL="$(gh api -X POST "repos/$REPO/issues/$PR_NUMBER/comments" -f body="$(<"$COMMENT")" --jq .html_url)"
gh api -X POST "repos/$REPO/statuses/$SHA" \
  -f state="$STATE" \
  -f context='GPT-5.6 Sol review' \
  -f description="Independent read-only Sol review: $STATE" \
  -f target_url="$COMMENT_URL" >/dev/null

[[ "$STATE" == success ]] || exit 1
echo "Published passing independent Sol review for $SHA: $COMMENT_URL"
