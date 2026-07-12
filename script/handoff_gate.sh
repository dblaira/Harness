#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  echo "usage: $0 --contract FILE --observed FILE --verifier NAME" >&2
  exit 2
}

CONTRACT=""
OBSERVED=""
VERIFIER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract) CONTRACT="$2"; shift 2 ;;
    --observed) OBSERVED="$2"; shift 2 ;;
    --verifier) VERIFIER="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$CONTRACT" && -f "$OBSERVED" && -n "$VERIFIER" ]] || usage
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "Commit or remove every working-tree change before capturing release evidence." >&2
  exit 1
}

SHA="$(git rev-parse HEAD)"
OUTPUT_DIR="$ROOT_DIR/.local-artifacts/release-gate/$SHA"
UNIT_RESULT_BUNDLE="$OUTPUT_DIR/HarnessUnitTests.xcresult"
UI_RESULT_BUNDLE="$OUTPUT_DIR/HarnessRequirementUI.xcresult"
FINAL_UI_RESULT_BUNDLE="$OUTPUT_DIR/HarnessFinalRelaunchUI.xcresult"
SCREENSHOT="$OUTPUT_DIR/visible-result.png"
FINAL_SCREENSHOT="$OUTPUT_DIR/final-relaunch-visible-result.png"
VIDEO="$OUTPUT_DIR/visible-requirement.mov"
SATISFACTION_DIR="$OUTPUT_DIR/satisfaction-gate"
APP_BUNDLE="$ROOT_DIR/.build/HarnessCandidateDerivedData/Build/Products/Debug/Harness.app"
CANDIDATE_DERIVED_DATA="$ROOT_DIR/.build/HarnessCandidateDerivedData"
UNIT_DERIVED_DATA="$ROOT_DIR/.build/HarnessUnitDerivedData"
mkdir -p "$OUTPUT_DIR"
rm -rf "$UNIT_RESULT_BUNDLE" "$UI_RESULT_BUNDLE" "$FINAL_UI_RESULT_BUNDLE" "$SATISFACTION_DIR"
rm -f "$SCREENSHOT" "$FINAL_SCREENSHOT" "$VIDEO"
mkdir -p "$SATISFACTION_DIR"

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
PR_NUMBER="$(gh api "repos/$REPO/commits/$SHA/pulls" --jq '[.[] | select(.state == "open")] | first | .number')"
[[ -n "$PR_NUMBER" && "$PR_NUMBER" != "null" ]] || {
  echo "No open pull request is bound to commit $SHA." >&2
  exit 1
}
PR_BODY_FILE="$OUTPUT_DIR/reviewed-pr-body.md"
gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .body > "$PR_BODY_FILE"
python3 scripts/validate_acceptance_contract.py \
  --contract-json "$CONTRACT" \
  --pr-body-file "$PR_BODY_FILE"

CONTRACT_UI_TEST="$(CONTRACT="$CONTRACT" /usr/bin/python3 - <<'PY'
import json, os
from pathlib import Path
print(json.loads(Path(os.environ["CONTRACT"]).read_text(encoding="utf-8"))["ui_test_identifier"])
PY
)"
UI_TEST="$CONTRACT_UI_TEST"
if [[ "$CONTRACT_UI_TEST" == "INFRASTRUCTURE_ONLY" ]]; then
  UI_TEST="HarnessUITests/HarnessCriticalFlowTests/testSignedAppLaunchesItsVisibleDelegationSurface"
fi
[[ "$UI_TEST" == HarnessUITests/*/test* ]] || {
  echo "The handoff test must be one exact HarnessUITests method." >&2
  exit 1
}
[[ "$CONTRACT_UI_TEST" == "INFRASTRUCTURE_ONLY" || "$UI_TEST" != "HarnessUITests/HarnessCriticalFlowTests/testSignedAppLaunchesItsVisibleDelegationSurface" ]] || {
  echo "The generic launch smoke test cannot prove a feature requirement. Name an exact requirement test." >&2
  exit 1
}

xcodegen generate
xcodebuild build-for-testing \
  -project Harness.xcodeproj \
  -scheme HarnessUIVerification \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$CANDIDATE_DERIVED_DATA" | tee "$OUTPUT_DIR/signed-build.log"

xcodebuild test \
  -project Harness.xcodeproj \
  -scheme HarnessUnitVerification \
  -destination 'platform=macOS' \
  -derivedDataPath "$UNIT_DERIVED_DATA" \
  -resultBundlePath "$UNIT_RESULT_BUNDLE" \
  -only-testing:HarnessTests
python3 scripts/validate_xcresult.py \
  --xcresult "$UNIT_RESULT_BUNDLE" \
  --required-bundle HarnessTests

HARNESS_REQUIRE_LIVE_SATISFACTION=1 \
HARNESS_SATISFACTION_OUTPUT_DIR="$SATISFACTION_DIR" \
swift test \
  --package-path Packages/OntologyKit \
  --filter satisfactionGateAdamRealQuestionGetsCompleteAnswer | tee "$OUTPUT_DIR/live-satisfaction.log"
SATISFACTION_COUNT="$(find "$SATISFACTION_DIR" -type f -name 'gate-*.md' | wc -l | tr -d ' ')"
[[ "$SATISFACTION_COUNT" == "1" ]] || {
  echo "The required live satisfaction test did not produce exactly one proof artifact." >&2
  exit 1
}
SATISFACTION_ARTIFACT="$(find "$SATISFACTION_DIR" -type f -name 'gate-*.md' -print -quit)"

/usr/sbin/screencapture -v -V120 -m -x -k "$VIDEO" &
VIDEO_PID=$!
video_cleanup() {
  if kill -0 "$VIDEO_PID" 2>/dev/null; then
    kill -TERM "$VIDEO_PID" 2>/dev/null || true
  fi
  wait "$VIDEO_PID" 2>/dev/null || true
}
trap video_cleanup EXIT

python3 scripts/run_with_timeout.py --seconds 110 -- xcodebuild test-without-building \
  -project Harness.xcodeproj \
  -scheme HarnessUIVerification \
  -destination 'platform=macOS' \
  -derivedDataPath "$CANDIDATE_DERIVED_DATA" \
  -resultBundlePath "$UI_RESULT_BUNDLE" \
  "-only-testing:$UI_TEST"

kill -0 "$VIDEO_PID" 2>/dev/null || {
  echo "The video recording ended before the exact UI test completed." >&2
  exit 1
}
wait "$VIDEO_PID"
trap - EXIT
python3 scripts/validate_xcresult.py \
  --xcresult "$UI_RESULT_BUNDLE" \
  --required-test "$UI_TEST" \
  --max-duration 55 \
  --screenshot-output "$SCREENSHOT"
[[ -s "$VIDEO" && -s "$SCREENSHOT" ]] || {
  echo "The exact visible requirement did not produce both video and screenshot evidence." >&2
  exit 1
}

[[ -d "$APP_BUNDLE" ]] || { echo "The tested Harness.app bundle is missing." >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | tee "$OUTPUT_DIR/codesign.log"
/usr/bin/codesign -dvv "$APP_BUNDLE" 2>> "$OUTPUT_DIR/codesign.log"
SIGNATURE="$(/usr/bin/codesign -dvvv "$APP_BUNDLE" 2>&1)"
TEAM_IDENTIFIER="$(printf '%s\n' "$SIGNATURE" | sed -n 's/^TeamIdentifier=//p' | head -1)"
CDHASH="$(printf '%s\n' "$SIGNATURE" | sed -n 's/^CDHash=//p' | head -1)"
[[ "$TEAM_IDENTIFIER" == "7FKUS5M5QS" && -n "$CDHASH" ]] || {
  echo "Harness is not signed by Adam's expected Apple development team." >&2
  exit 1
}

pkill -x Harness >/dev/null 2>&1 || true
/usr/bin/open -n "$APP_BUNDLE"
for _ in {1..20}; do
  PID="$(pgrep -x Harness | head -1 || true)"
  [[ -n "$PID" ]] && break
  sleep 0.25
done
[[ -n "$PID" ]] || { echo "Harness is not running after verification." >&2; exit 1; }
PROCESS_COMMAND="$(ps -p "$PID" -o command=)"
[[ "$PROCESS_COMMAND" == "$APP_BUNDLE/Contents/MacOS/Harness"* ]] || {
  echo "Running Harness process is not the signed and UI-tested app bundle." >&2
  exit 1
}

rm -rf "$FINAL_UI_RESULT_BUNDLE"
python3 scripts/run_with_timeout.py --seconds 110 -- xcodebuild test-without-building \
  -project Harness.xcodeproj \
  -scheme HarnessUIVerification \
  -destination 'platform=macOS' \
  -derivedDataPath "$CANDIDATE_DERIVED_DATA" \
  -resultBundlePath "$FINAL_UI_RESULT_BUNDLE" \
  "-only-testing:$UI_TEST"
python3 scripts/validate_xcresult.py \
  --xcresult "$FINAL_UI_RESULT_BUNDLE" \
  --required-test "$UI_TEST" \
  --max-duration 55 \
  --screenshot-output "$FINAL_SCREENSHOT"
[[ -s "$FINAL_SCREENSHOT" ]] || {
  echo "The final normal relaunch did not produce visible requirement evidence." >&2
  exit 1
}
PID="$(pgrep -x Harness | head -1 || true)"
[[ -n "$PID" ]] || { echo "Harness is not running after final visible verification." >&2; exit 1; }
PROCESS_COMMAND="$(ps -p "$PID" -o command=)"
[[ "$PROCESS_COMMAND" == "$APP_BUNDLE/Contents/MacOS/Harness"* ]] || {
  echo "Final verified Harness process is not the signed and UI-tested app bundle." >&2
  exit 1
}

SOL_URL="$(gh api "repos/$REPO/commits/$SHA/status" | python3 scripts/require_latest_status.py --context 'GPT-5.6 Sol review')" || {
  echo "The newest GPT-5.6 Sol review for commit $SHA is not successful." >&2
  exit 1
}

CONTRACT="$CONTRACT" OBSERVED="$OBSERVED" SCREENSHOT="$SCREENSHOT" VIDEO="$VIDEO" \
VERIFIER="$VERIFIER" SHA="$SHA" OUTPUT_DIR="$OUTPUT_DIR" UNIT_RESULT_BUNDLE="$UNIT_RESULT_BUNDLE" \
UI_RESULT_BUNDLE="$UI_RESULT_BUNDLE" FINAL_UI_RESULT_BUNDLE="$FINAL_UI_RESULT_BUNDLE" \
FINAL_SCREENSHOT="$FINAL_SCREENSHOT" SATISFACTION_ARTIFACT="$SATISFACTION_ARTIFACT" \
APP_BUNDLE="$APP_BUNDLE" PID="$PID" SOL_URL="$SOL_URL" ACTUAL_UI_TEST="$UI_TEST" \
TEAM_IDENTIFIER="$TEAM_IDENTIFIER" CDHASH="$CDHASH" /usr/bin/python3 - <<'PY'
import datetime
import hashlib
import json
import os
from pathlib import Path

def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    if path.is_file():
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    for child in sorted(item for item in path.rglob("*") if item.is_file()):
        digest.update(str(child.relative_to(path)).encode("utf-8"))
        with child.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    return digest.hexdigest()

contract = json.loads(Path(os.environ["CONTRACT"]).read_text(encoding="utf-8"))
observed = Path(os.environ["OBSERVED"]).read_text(encoding="utf-8").strip()
artifacts = {
    "screenshot": os.environ["SCREENSHOT"],
    "video": os.environ["VIDEO"],
    "unit_xcresult": os.environ["UNIT_RESULT_BUNDLE"],
    "ui_xcresult": os.environ["UI_RESULT_BUNDLE"],
    "final_screenshot": os.environ["FINAL_SCREENSHOT"],
    "final_ui_xcresult": os.environ["FINAL_UI_RESULT_BUNDLE"],
    "satisfaction_artifact": os.environ["SATISFACTION_ARTIFACT"],
}
manifest = {
    "schema_version": 1,
    "status": "PASS",
    "commit": os.environ["SHA"],
    "git_tree": os.popen("git rev-parse 'HEAD^{tree}'").read().strip(),
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "requirement_verbatim": contract["requirement_verbatim"],
    "visible_surface": contract["visible_surface"],
    "expected_visible_result": contract["expected_visible_result"],
    "acceptance_test_identifier": contract["ui_test_identifier"],
    "ui_test_identifier": os.environ["ACTUAL_UI_TEST"],
    "observed_visible_result": observed,
    "app_bundle": os.environ["APP_BUNDLE"],
    "app_pid": int(os.environ["PID"]),
    "codesign_verified": True,
    "app_cdhash": os.environ["CDHASH"],
    "app_team_identifier": os.environ["TEAM_IDENTIFIER"],
    "working_tree_clean": True,
    "verifier": os.environ["VERIFIER"],
    "tests": [
        {"name": "macos-unit-tests", "status": "PASS"},
        {"name": "macos-ui-tests", "status": "PASS", "test_identifier": os.environ["ACTUAL_UI_TEST"]},
        {"name": "final-relaunch-ui-test", "status": "PASS", "test_identifier": os.environ["ACTUAL_UI_TEST"]},
        {"name": "live-satisfaction-gate", "status": "PASS"},
    ],
    "sol_review": {"status": "PASS", "check_run_url": os.environ["SOL_URL"]},
    "artifacts": artifacts,
    "artifact_sha256": {name: sha256_path(Path(path)) for name, path in artifacts.items()},
}
path = Path(os.environ["OUTPUT_DIR"]) / "manifest.json"
path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print(path)
PY

python3 scripts/release_gate.py validate --manifest "$OUTPUT_DIR/manifest.json"

gh api -X POST "repos/$REPO/statuses/$SHA" \
  -f state=success \
  -f context='Signed Mac handoff' \
  -f description='Signed app, exact XCUITest, screenshot, video, and results passed' \
  -f target_url="$SOL_URL" >/dev/null
echo "Published the Signed Mac handoff status for $SHA."
