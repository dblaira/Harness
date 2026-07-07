#!/usr/bin/env bash
# Clone every coordinated repo (if missing) and fast-forward pull to origin/main.
# Run once per Mac when you want all machines to carry the same repo set.

set -euo pipefail

if [[ -d "${HOME}/Developer/GitHub" ]]; then
  ROOT="${HOME}/Developer/GitHub"
elif [[ -d "${HOME}/GitHub" ]]; then
  ROOT="${HOME}/GitHub"
else
  ROOT="${HOME}/Developer/GitHub"
  mkdir -p "$ROOT"
fi

cd "$ROOT"

command -v gh >/dev/null 2>&1 || {
  echo "Need GitHub CLI: brew install gh && gh auth login"
  exit 1
}

# name on disk -> gh repo (override when folder name differs)
clone_repo() {
  local dir="$1"
  local spec="${2:-dblaira/${dir}}"
  if [[ -d "${dir}/.git" ]]; then
    echo "== pull ${dir}"
    git -C "$dir" pull --ff-only
  else
    echo "== clone ${spec} -> ${dir}"
    gh repo clone "$spec" "$dir"
  fi
}

clone_repo Harness
clone_repo Re_Call
clone_repo Understood
clone_repo understood-app
clone_repo understood-app-public
clone_repo dblaira.github.io
clone_repo material-health
clone_repo nutrition-app dblaira/nutrition-app
clone_repo Boring_News

echo ""
echo "Done. Canonical root: ${ROOT}"
echo "Verify: ${ROOT}/Harness/scripts/multi-mac-repo-health.sh"