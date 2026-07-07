#!/usr/bin/env bash
# Push any repo that has local commits not on GitHub yet (clean working tree only).
# Does not auto-commit — uncommitted work gets a log line only.

set -euo pipefail

if [[ -d "${HOME}/Developer/GitHub" ]]; then
  ROOT="${HOME}/Developer/GitHub"
elif [[ -d "${HOME}/GitHub" ]]; then
  ROOT="${HOME}/GitHub"
else
  exit 0
fi

REPOS=(Harness Re_Call Understood understood-app understood-app-public dblaira.github.io material-health nutrition-app Boring_News)

for name in "${REPOS[@]}"; do
  path="${ROOT}/${name}"
  [[ -d "${path}/.git" ]] || continue
  dirty="$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$dirty" != "0" ]]; then
    echo "SKIP_PUSH_DIRTY: ${name} (${dirty} files) — commit or stash first"
    continue
  fi
  git -C "$path" fetch origin -q 2>/dev/null || true
  st="$(git -C "$path" status -sb 2>/dev/null | head -1)"
  if [[ "$st" == *"ahead"* ]]; then
    echo "PUSH: ${name} ${st}"
    if git -C "$path" push origin HEAD 2>&1; then
      echo "OK: ${name} pushed"
    else
      echo "FAIL: ${name} push"
      exit 1
    fi
  fi
done