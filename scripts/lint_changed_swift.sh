#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
BASE_SHA="${1:-origin/main}"
CONFIG="${SWIFTLINT_CONFIG:-$ROOT_DIR/.swiftlint.yml}"
cd "$ROOT_DIR"
git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null || {
  echo "SwiftLint base commit is unavailable: $BASE_SHA" >&2
  exit 1
}

SWIFT_FILES=()
CHANGED_FILES="$(mktemp)"
trap 'rm -f "$CHANGED_FILES"' EXIT
if ! git diff --name-only --diff-filter=ACMR "$BASE_SHA"...HEAD -- '*.swift' > "$CHANGED_FILES"; then
  echo "Unable to inspect Swift changes from $BASE_SHA to HEAD." >&2
  exit 1
fi
while IFS= read -r line; do
  [[ -n "$line" ]] && SWIFT_FILES+=("$line")
done < "$CHANGED_FILES"

if [[ ${#SWIFT_FILES[@]} -eq 0 ]]; then
  echo "No changed Swift files to lint."
  exit 0
fi

for file in "${SWIFT_FILES[@]}"; do
  swiftlint lint --strict --config "$CONFIG" "$file"
done
