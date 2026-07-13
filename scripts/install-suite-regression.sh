#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="${HARNESS_SUITE_REGRESSION_HOME:-$HOME/.local/share/harness-suite-regression}"
BIN_DIR="$HOME/.local/bin"

install -d "$DESTINATION/Regression" "$DESTINATION/scripts/regression_probes" "$BIN_DIR"
install -m 0644 "$ROOT/Regression/suite-regression.json" "$DESTINATION/Regression/suite-regression.json"
install -m 0644 "$ROOT/Regression/python-requirements.txt" "$DESTINATION/Regression/python-requirements.txt"
install -m 0755 "$ROOT/scripts/suite_regression.py" "$DESTINATION/scripts/suite_regression.py"
install -m 0755 "$ROOT/scripts/regression_probes/news_calm_delete_route.py" \
  "$DESTINATION/scripts/regression_probes/news_calm_delete_route.py"
install -m 0755 "$ROOT/scripts/harness-suite-regression" "$BIN_DIR/harness-suite-regression"

echo "Installed Codex-owned suite regression command: $BIN_DIR/harness-suite-regression"
echo "Evidence directory: $HOME/Library/Logs/Harness/SuiteRegression"
