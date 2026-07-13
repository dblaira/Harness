#!/usr/bin/env bash
set -euo pipefail

CONTROL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="${HARNESS_REPO_ROOT:-$(pwd)}"
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"
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
[[ "$(cd "$(dirname "$CONTRACT")" && pwd)/$(basename "$CONTRACT")" == "$ROOT_DIR/.github/acceptance-contract.json" ]] || {
  echo "Handoff must use the checked-in .github/acceptance-contract.json." >&2
  exit 1
}
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "Commit or remove every working-tree change before capturing release evidence." >&2
  exit 1
}

SHA="$(git rev-parse HEAD)"
OUTPUT_DIR="$HOME/.local/share/harness-release-evidence/Harness/$SHA"
CANDIDATE_OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/harness-candidate-evidence.${SHA}.XXXXXX")"

set_artifact_paths() {
  local directory="$1"
  UNIT_RESULT_BUNDLE="$directory/HarnessUnitTests.xcresult"
  UI_RESULT_BUNDLE="$directory/HarnessRequirementUI.xcresult"
  FINAL_UI_RESULT_BUNDLE="$directory/HarnessFinalRelaunchUI.xcresult"
  SCREENSHOT="$directory/visible-result.png"
  FEATURE_SCREENSHOT="$directory/feature-visible-result.png"
  FINAL_SCREENSHOT="$directory/final-relaunch-visible-result.png"
  FINAL_UI_SCREENSHOT="$directory/final-relaunch-xcuitest-result.png"
  FINAL_FEATURE_SCREENSHOT="$directory/final-feature-visible-result.png"
  RUNNING_APP_PROOF="$directory/final-running-app.json"
  INITIAL_RUNNING_APP_PROOF="$directory/recorded-running-app.json"
  MEDIA_PROOF="$directory/media-proof.json"
  TEST_INVENTORY="$directory/protected-test-inventory.json"
  VIDEO="$directory/visible-requirement.mov"
  SATISFACTION_DIR="$directory/satisfaction-gate"
  APP_IDENTITY="$directory/app-identity.json"
  LIVE_SWIFT_TRANSCRIPT="$directory/live-satisfaction-swift.log"
  LIVE_SWIFT_DIR="$directory/live-satisfaction-swift"
}

set_artifact_paths "$CANDIDATE_OUTPUT_DIR"
APP_BUNDLE="$ROOT_DIR/.build/HarnessCandidateDerivedData/Build/Products/Debug/Harness.app"
CANDIDATE_DERIVED_DATA="$ROOT_DIR/.build/HarnessCandidateDerivedData"
UNIT_DERIVED_DATA="$ROOT_DIR/.build/HarnessUnitDerivedData"
GRAPH_SNAPSHOT="$OUTPUT_DIR/accepted-graph-before.json"
LIVE_SWIFT_INVENTORY="$OUTPUT_DIR/live-satisfaction-swift-inventory.json"
LIVE_SERVICE_IDENTITY="$OUTPUT_DIR/live-service-identity.txt"
mkdir -p "$OUTPUT_DIR" "$CANDIDATE_OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
rm -rf "$UNIT_RESULT_BUNDLE" "$UI_RESULT_BUNDLE" "$FINAL_UI_RESULT_BUNDLE" "$SATISFACTION_DIR"
rm -f "$SCREENSHOT" "$FEATURE_SCREENSHOT" "$FINAL_SCREENSHOT" "$FINAL_UI_SCREENSHOT" "$FINAL_FEATURE_SCREENSHOT" "$RUNNING_APP_PROOF" "$INITIAL_RUNNING_APP_PROOF" "$MEDIA_PROOF" "$TEST_INVENTORY" "$VIDEO"
mkdir -p "$SATISFACTION_DIR"

PROPOSAL_SANDBOX="(version 1)(allow default)(deny file-write* (subpath \"$CONTROL_DIR\") (subpath \"$OUTPUT_DIR\") (subpath \"$HOME/.local/bin\") (literal \"$HOME/.codex/hooks.json\"))"
proposal_exec() {
  /usr/bin/sandbox-exec -p "$PROPOSAL_SANDBOX" -- "$@"
}

terminate_proposal_processes() {
  pkill -x Harness >/dev/null 2>&1 || true
  for _ in {1..20}; do
    [[ -z "$(pgrep -x Harness || true)" ]] && return 0
    sleep 0.25
  done
  echo "A proposal Harness process survived final evidence capture." >&2
  return 1
}

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
PULLS_JSON="$(gh api "repos/$REPO/commits/$SHA/pulls")"
PR_JSON="$(printf '%s' "$PULLS_JSON" | python3 "$CONTROL_DIR/scripts/select_pull_request.py" --head-sha "$SHA")"
PR_NUMBER="$(printf '%s' "$PR_JSON" | jq -r .number)"
BASE_SHA="$(printf '%s' "$PR_JSON" | jq -r .base.sha)"
PR_HEAD_SHA="$(printf '%s' "$PR_JSON" | jq -r .head.sha)"
[[ "$PR_HEAD_SHA" == "$SHA" ]] || {
  echo "The pull request head advanced beyond local HEAD; stale handoff refused." >&2
  exit 1
}
python3 "$CONTROL_DIR/scripts/verify_repository_gate_state.py" --repo "$REPO"
python3 "$CONTROL_DIR/scripts/verify_control_bundle.py" \
  --manifest "$CONTROL_DIR/control-manifest.json" \
  --control-dir "$CONTROL_DIR" --repo-root "$ROOT_DIR" --base-sha "$BASE_SHA"
python3 "$CONTROL_DIR/scripts/validate_acceptance_contract.py" \
  --contract-json "$CONTRACT" \
  --repo "$REPO" \
  --pr-number "$PR_NUMBER" \
  --base-sha "$BASE_SHA"
CONTRACT_DIGEST="$(python3 -c 'import json,sys;sys.path.insert(0,sys.argv[1]);import validate_acceptance_contract as v;print(v.contract_digest(json.load(open(sys.argv[2]))))' "$CONTROL_DIR/scripts" "$CONTRACT")"
EVIDENCE_BINDING="$(python3 "$CONTROL_DIR/scripts/evidence_binding.py" \
  --repo "$REPO" --pr-number "$PR_NUMBER" --base-sha "$BASE_SHA" --head-sha "$SHA" \
  --contract-digest "$CONTRACT_DIGEST")"

CONTRACT_UI_TEST="$(CONTRACT="$CONTRACT" /usr/bin/python3 - <<'PY'
import json, os
from pathlib import Path
print(json.loads(Path(os.environ["CONTRACT"]).read_text(encoding="utf-8"))["ui_test_identifier"])
PY
)"
FINAL_ACCESSIBILITY_IDENTIFIER="$(CONTRACT="$CONTRACT" /usr/bin/python3 - <<'PY'
import json, os
from pathlib import Path
print(json.loads(Path(os.environ["CONTRACT"]).read_text(encoding="utf-8"))["final_accessibility_identifier"])
PY
)"
UI_TEST="$CONTRACT_UI_TEST"
BINDING_UI_TEST="HarnessUITests/HarnessCriticalFlowTests/testSignedAppLaunchesItsVisibleDelegationSurface"
if [[ "$CONTRACT_UI_TEST" == "INFRASTRUCTURE_ONLY" ]]; then
  UI_TEST="$BINDING_UI_TEST"
fi
[[ "$UI_TEST" == HarnessUITests/*/test* ]] || {
  echo "The handoff test must be one exact HarnessUITests method." >&2
  exit 1
}
UI_TEST_ARGS=("-only-testing:$BINDING_UI_TEST")
[[ "$CONTRACT_UI_TEST" == "INFRASTRUCTURE_ONLY" || "$UI_TEST" != "$BINDING_UI_TEST" ]] || {
  echo "A product contract must name its feature XCUITest; the immutable binding test runs beside it." >&2
  exit 1
}
if [[ "$UI_TEST" != "$BINDING_UI_TEST" ]]; then
  UI_TEST_ARGS+=("-only-testing:$UI_TEST")
fi

"$CONTROL_DIR/script/hosted_verification_gate.sh"
HOSTED_URL="$(gh api "repos/$REPO/commits/$SHA/status" | python3 "$CONTROL_DIR/scripts/require_latest_status.py" --context 'Trusted hosted verification' --description-contains "pr:$PR_NUMBER binding:${EVIDENCE_BINDING:0:24}")" || {
  echo "Trusted hosted acceptance, tests, static analysis, and CodeQL evidence is unavailable." >&2
  exit 1
}
SOL_URL="$(gh api "repos/$REPO/commits/$SHA/status" | python3 "$CONTROL_DIR/scripts/require_latest_status.py" --context 'GPT-5.6 Sol review' --description-contains "pr:$PR_NUMBER binding:${EVIDENCE_BINDING:0:24}")" || {
  echo "The newest GPT-5.6 Sol review for commit $SHA is not successful; no proposed code was executed." >&2
  exit 1
}
xcrun swift "$CONTROL_DIR/scripts/preflight_tcc.swift"
command -v ffmpeg >/dev/null
command -v ffprobe >/dev/null
python3 "$CONTROL_DIR/scripts/swift_test_inventory.py" \
  --git-ref "$BASE_SHA" --repo-root "$ROOT_DIR" --output "$TEST_INVENTORY"
python3 "$CONTROL_DIR/scripts/live_satisfaction_oracle.py" \
  --snapshot-output "$GRAPH_SNAPSHOT"
GRAPH_DIGEST="$(jq -r .sha256 "$GRAPH_SNAPSHOT")"
[[ "$GRAPH_DIGEST" =~ ^[0-9a-f]{64}$ ]] || {
  echo "The protected accepted-graph snapshot is invalid." >&2
  exit 1
}
{
  for port in 3030 11434; do
    echo "PORT:$port"
    /usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN -Fpc 2>/dev/null || true
  done
} > "$LIVE_SERVICE_IDENTITY"
grep -q '^p' "$LIVE_SERVICE_IDENTITY" || {
  echo "The protected Fuseki and Ollama service identities are unavailable." >&2
  exit 1
}
LIVE_SWIFT_INVENTORY="$LIVE_SWIFT_INVENTORY" /usr/bin/python3 - <<'PY'
import json
import os
from pathlib import Path

Path(os.environ["LIVE_SWIFT_INVENTORY"]).write_text(
    json.dumps(["OntologyKitTests.satisfactionGateAdamRealQuestionGetsCompleteAnswer()"], indent=2) + "\n",
    encoding="utf-8",
)
PY

HARNESS_EXPECTED_PID=0 HARNESS_EXPECTED_WINDOW_BOUNDS=UNSET HARNESS_FINAL_ACCESSIBILITY_IDENTIFIER=UNSET HARNESS_ATTACH_EXISTING_APP=0 proposal_exec xcodegen generate
proposal_exec xcodebuild build-for-testing \
  -project Harness.xcodeproj \
  -scheme HarnessUIVerification \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$CANDIDATE_DERIVED_DATA" | tee "$CANDIDATE_OUTPUT_DIR/signed-build.log"

[[ -d "$APP_BUNDLE" ]] || { echo "The built Harness.app bundle is missing." >&2; exit 1; }
python3 "$CONTROL_DIR/scripts/verify_app_identity.py" \
  --app "$APP_BUNDLE" --output "$APP_IDENTITY"
TEAM_IDENTIFIER="$(jq -r .team_identifier "$APP_IDENTITY")"
CDHASH="$(jq -r .cdhash "$APP_IDENTITY")"

pkill -x Harness >/dev/null 2>&1 || true
for _ in {1..20}; do
  [[ -z "$(pgrep -x Harness || true)" ]] && break
  sleep 0.25
done
[[ -z "$(pgrep -x Harness || true)" ]] || {
  echo "A stale Harness process survived termination; refusing ambiguous app evidence." >&2
  exit 1
}

proposal_exec xcodebuild test \
  -project Harness.xcodeproj \
  -scheme HarnessUnitVerification \
  -destination 'platform=macOS' \
  -derivedDataPath "$UNIT_DERIVED_DATA" \
  -resultBundlePath "$UNIT_RESULT_BUNDLE" \
  -only-testing:HarnessTests
python3 "$CONTROL_DIR/scripts/validate_xcresult.py" \
  --xcresult "$UNIT_RESULT_BUNDLE" \
  --required-bundle HarnessTests \
  --required-test-list "$TEST_INVENTORY"

pkill -x Harness >/dev/null 2>&1 || true
proposal_exec "$APP_BUNDLE/Contents/MacOS/Harness" >"$CANDIDATE_OUTPUT_DIR/recorded-app.log" 2>&1 &
RECORDED_PID=""
for _ in {1..30}; do
  while IFS= read -r CANDIDATE_PID; do
    [[ -n "$CANDIDATE_PID" ]] || continue
    CANDIDATE_COMMAND="$(ps -p "$CANDIDATE_PID" -o command= 2>/dev/null || true)"
    if [[ "$CANDIDATE_COMMAND" == "$APP_BUNDLE/Contents/MacOS/Harness"* ]]; then
      RECORDED_PID="$CANDIDATE_PID"
      break
    fi
  done < <(pgrep -x Harness || true)
  [[ -n "$RECORDED_PID" ]] && break
  sleep 0.2
done
[[ -n "$RECORDED_PID" ]] || { echo "Signed Harness app did not launch for window-bound recording." >&2; exit 1; }
RECORDED_PROOF_PASS=0
for _ in {1..30}; do
  if xcrun swift "$CONTROL_DIR/scripts/verify_running_app.swift" \
    --pid "$RECORDED_PID" \
    --executable "$APP_BUNDLE/Contents/MacOS/Harness" \
    --identifier "$FINAL_ACCESSIBILITY_IDENTIFIER" \
    --output "$INITIAL_RUNNING_APP_PROOF"; then
    RECORDED_PROOF_PASS=1
    break
  fi
  sleep 0.25
done
[[ "$RECORDED_PROOF_PASS" == 1 ]] || { echo "Recorded candidate window never exposed the contracted identifier." >&2; exit 1; }
RECORDED_WINDOW_ID="$(jq -r .window_id "$INITIAL_RUNNING_APP_PROOF")"
[[ "$RECORDED_WINDOW_ID" =~ ^[0-9]+$ ]] || { echo "Recorded candidate window lacks a CGWindowID." >&2; exit 1; }
RECORDED_WINDOW_BOUNDS="$(jq -r '[.window_bounds.x,.window_bounds.y,.window_bounds.width,.window_bounds.height] | join(",")' "$INITIAL_RUNNING_APP_PROOF")"
HARNESS_EXPECTED_PID="$RECORDED_PID" HARNESS_EXPECTED_WINDOW_BOUNDS="$RECORDED_WINDOW_BOUNDS" HARNESS_FINAL_ACCESSIBILITY_IDENTIFIER="$FINAL_ACCESSIBILITY_IDENTIFIER" HARNESS_ATTACH_EXISTING_APP=1 proposal_exec xcodegen generate

/usr/sbin/screencapture -v -V120 -l"$RECORDED_WINDOW_ID" -x -k "$VIDEO" &
VIDEO_PID=$!
video_cleanup() {
  if kill -0 "$VIDEO_PID" 2>/dev/null; then
    kill -TERM "$VIDEO_PID" 2>/dev/null || true
  fi
  wait "$VIDEO_PID" 2>/dev/null || true
}
trap video_cleanup EXIT

python3 "$CONTROL_DIR/scripts/run_with_timeout.py" --seconds 110 -- /usr/bin/sandbox-exec -p "$PROPOSAL_SANDBOX" -- xcodebuild test-without-building \
  -project Harness.xcodeproj \
  -scheme HarnessUIVerification \
  -destination 'platform=macOS' \
  -derivedDataPath "$CANDIDATE_DERIVED_DATA" \
  -resultBundlePath "$UI_RESULT_BUNDLE" \
  "${UI_TEST_ARGS[@]}"

kill -0 "$VIDEO_PID" 2>/dev/null || {
  echo "The video recording ended before the exact UI test completed." >&2
  exit 1
}
wait "$VIDEO_PID"
trap - EXIT
if [[ "$UI_TEST" != "$BINDING_UI_TEST" ]]; then
  python3 "$CONTROL_DIR/scripts/validate_xcresult.py" \
    --xcresult "$UI_RESULT_BUNDLE" --required-test "$UI_TEST" --max-duration 55 --screenshot-output "$FEATURE_SCREENSHOT"
fi
python3 "$CONTROL_DIR/scripts/validate_xcresult.py" \
  --xcresult "$UI_RESULT_BUNDLE" \
  --required-test "$BINDING_UI_TEST" \
  --max-duration 55 \
  --screenshot-output "$SCREENSHOT"
if [[ "$UI_TEST" != "$BINDING_UI_TEST" ]]; then
  cmp -s "$FEATURE_SCREENSHOT" "$SCREENSHOT" || { echo "Feature-test screenshot is not the immutable PID/window-bound evidence surface." >&2; exit 1; }
fi
[[ -s "$VIDEO" && -s "$SCREENSHOT" ]] || {
  echo "The exact visible requirement did not produce both video and screenshot evidence." >&2
  exit 1
}

pkill -x Harness >/dev/null 2>&1 || true
for _ in {1..20}; do
  [[ -z "$(pgrep -x Harness || true)" ]] && break
  sleep 0.25
done
[[ -z "$(pgrep -x Harness || true)" ]] || {
  echo "A stale Harness process survived before the final normal relaunch." >&2
  exit 1
}
proposal_exec "$APP_BUNDLE/Contents/MacOS/Harness" >"$CANDIDATE_OUTPUT_DIR/final-app.log" 2>&1 &
for _ in {1..20}; do
  PID=""
  while IFS= read -r CANDIDATE_PID; do
    [[ -n "$CANDIDATE_PID" ]] || continue
    CANDIDATE_COMMAND="$(ps -p "$CANDIDATE_PID" -o command= 2>/dev/null || true)"
    if [[ "$CANDIDATE_COMMAND" == "$APP_BUNDLE/Contents/MacOS/Harness"* ]]; then
      PID="$CANDIDATE_PID"
      break
    fi
  done < <(pgrep -x Harness || true)
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
xcrun swift "$CONTROL_DIR/scripts/verify_running_app.swift" \
  --pid "$PID" \
  --executable "$APP_BUNDLE/Contents/MacOS/Harness" \
  --identifier "$FINAL_ACCESSIBILITY_IDENTIFIER" \
  --output "$RUNNING_APP_PROOF"
FINAL_WINDOW_BOUNDS="$(jq -r '[.window_bounds.x,.window_bounds.y,.window_bounds.width,.window_bounds.height] | join(",")' "$RUNNING_APP_PROOF")"
HARNESS_EXPECTED_PID="$PID" HARNESS_EXPECTED_WINDOW_BOUNDS="$FINAL_WINDOW_BOUNDS" HARNESS_FINAL_ACCESSIBILITY_IDENTIFIER="$FINAL_ACCESSIBILITY_IDENTIFIER" HARNESS_ATTACH_EXISTING_APP=1 proposal_exec xcodegen generate
python3 "$CONTROL_DIR/scripts/run_with_timeout.py" --seconds 110 -- /usr/bin/sandbox-exec -p "$PROPOSAL_SANDBOX" -- xcodebuild test-without-building \
  -project Harness.xcodeproj \
  -scheme HarnessUIVerification \
  -destination 'platform=macOS' \
  -derivedDataPath "$CANDIDATE_DERIVED_DATA" \
  -resultBundlePath "$FINAL_UI_RESULT_BUNDLE" \
  "${UI_TEST_ARGS[@]}"
if [[ "$UI_TEST" != "$BINDING_UI_TEST" ]]; then
  python3 "$CONTROL_DIR/scripts/validate_xcresult.py" \
    --xcresult "$FINAL_UI_RESULT_BUNDLE" --required-test "$UI_TEST" --max-duration 55 --screenshot-output "$FINAL_FEATURE_SCREENSHOT"
fi
python3 "$CONTROL_DIR/scripts/validate_xcresult.py" \
  --xcresult "$FINAL_UI_RESULT_BUNDLE" \
  --required-test "$BINDING_UI_TEST" \
  --max-duration 55 \
  --screenshot-output "$FINAL_UI_SCREENSHOT"
if [[ "$UI_TEST" != "$BINDING_UI_TEST" ]]; then
  cmp -s "$FINAL_FEATURE_SCREENSHOT" "$FINAL_UI_SCREENSHOT" || { echo "Final feature-test screenshot is not the immutable PID/window-bound evidence surface." >&2; exit 1; }
fi
[[ -s "$FINAL_UI_SCREENSHOT" ]] || {
  echo "The final normal relaunch did not produce visible requirement evidence." >&2
  exit 1
}
kill -0 "$PID" 2>/dev/null || { echo "The normal relaunched Harness PID exited during final verification." >&2; exit 1; }
PROCESS_COMMAND="$(ps -p "$PID" -o command=)"
[[ "$PROCESS_COMMAND" == "$APP_BUNDLE/Contents/MacOS/Harness"* ]] || {
  echo "Final verified Harness process is not the signed and UI-tested app bundle." >&2
  exit 1
}
xcrun swift "$CONTROL_DIR/scripts/verify_running_app.swift" \
  --pid "$PID" \
  --executable "$APP_BUNDLE/Contents/MacOS/Harness" \
  --identifier "$FINAL_ACCESSIBILITY_IDENTIFIER" \
  --output "$RUNNING_APP_PROOF"
WINDOW_ID="$(jq -r .window_id "$RUNNING_APP_PROOF")"
[[ "$WINDOW_ID" =~ ^[0-9]+$ ]] || {
  echo "The exact candidate PID did not produce a screenshotable window identifier." >&2
  exit 1
}
/usr/sbin/screencapture -x -l "$WINDOW_ID" "$FINAL_SCREENSHOT"
[[ -s "$FINAL_SCREENSHOT" ]] || {
  echo "The exact candidate PID window did not produce final screenshot evidence." >&2
  exit 1
}
python3 "$CONTROL_DIR/scripts/validate_media.py" \
  --png "$SCREENSHOT" \
  --png "$FINAL_UI_SCREENSHOT" \
  --png "$FINAL_SCREENSHOT" \
  --video "$VIDEO" \
  --output "$MEDIA_PROOF"

# The reserved full-pipeline Swift test is the only protected OntologyKit test
# omitted by hosted CI. It must pass here with live dependencies required.
LIVE_SWIFT_TEST="OntologyKitTests.satisfactionGateAdamRealQuestionGetsCompleteAnswer"
rm -rf "$LIVE_SWIFT_DIR"
mkdir -p "$LIVE_SWIFT_DIR"
set +e
python3 "$CONTROL_DIR/scripts/run_with_timeout.py" --seconds 600 -- \
  /usr/bin/sandbox-exec -p "$PROPOSAL_SANDBOX" -- \
  /usr/bin/env \
    HARNESS_REQUIRE_LIVE_SATISFACTION=1 \
    HARNESS_SATISFACTION_COMMIT="$SHA" \
    HARNESS_SATISFACTION_OUTPUT_DIR="$LIVE_SWIFT_DIR" \
    /usr/bin/xcrun swift test \
      --package-path "$ROOT_DIR/Packages/OntologyKit" \
      --filter "${LIVE_SWIFT_TEST#*.}" \
  2>&1 | tee "$LIVE_SWIFT_TRANSCRIPT"
LIVE_SWIFT_STATUS="${PIPESTATUS[0]}"
set -e
[[ "$LIVE_SWIFT_STATUS" == "0" ]] || {
  echo "The reserved live satisfaction Swift test failed or exceeded its evidence deadline." >&2
  exit 1
}
python3 "$CONTROL_DIR/scripts/validate_swiftpm_tests.py" \
  --expected "$LIVE_SWIFT_INVENTORY" \
  --transcript "$LIVE_SWIFT_TRANSCRIPT"
LIVE_SWIFT_COUNT="$(find "$LIVE_SWIFT_DIR" -type f -name 'gate-*.md' | wc -l | tr -d ' ')"
[[ "$LIVE_SWIFT_COUNT" == "1" ]] || {
  echo "The reserved live satisfaction Swift test did not produce exactly one proof artifact." >&2
  exit 1
}

# No proposal process may remain alive while protected controls promote and
# generate the final evidence bundle.
terminate_proposal_processes
LIVE_SERVICE_IDENTITY_AFTER="$OUTPUT_DIR/live-service-identity-after.txt"
{
  for port in 3030 11434; do
    echo "PORT:$port"
    /usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN -Fpc 2>/dev/null || true
  done
} > "$LIVE_SERVICE_IDENTITY_AFTER"
cmp -s "$LIVE_SERVICE_IDENTITY" "$LIVE_SERVICE_IDENTITY_AFTER" || {
  echo "A live Fuseki or Ollama service changed identity during proposal execution." >&2
  exit 1
}

# Proposal output is promoted only after proposal processes stop. The sandbox
# denied every proposal process write access to this verifier-owned directory.
/bin/cp -R "$CANDIDATE_OUTPUT_DIR"/. "$OUTPUT_DIR"/
set_artifact_paths "$OUTPUT_DIR"
LIVE_SWIFT_ARTIFACT="$(find "$LIVE_SWIFT_DIR" -type f -name 'gate-*.md' -print -quit)"

# Rebuild protected inventories after promotion, then create the independent
# direct-network proof against the unchanged accepted graph.
python3 "$CONTROL_DIR/scripts/swift_test_inventory.py" \
  --git-ref "$BASE_SHA" --repo-root "$ROOT_DIR" --output "$TEST_INVENTORY"
python3 "$CONTROL_DIR/scripts/validate_swiftpm_tests.py" \
  --expected "$LIVE_SWIFT_INVENTORY" \
  --transcript "$LIVE_SWIFT_TRANSCRIPT"
rm -rf "$SATISFACTION_DIR"
mkdir -p "$SATISFACTION_DIR"
python3 "$CONTROL_DIR/scripts/live_satisfaction_oracle.py" \
  --commit "$SHA" \
  --output-dir "$SATISFACTION_DIR" \
  --expected-graph-digest "$GRAPH_DIGEST" | tee "$OUTPUT_DIR/live-satisfaction.log"
SATISFACTION_COUNT="$(find "$SATISFACTION_DIR" -type f -name 'gate-*.md' | wc -l | tr -d ' ')"
[[ "$SATISFACTION_COUNT" == "1" ]] || {
  echo "The protected direct live satisfaction oracle did not produce exactly one proof artifact." >&2
  exit 1
}
SATISFACTION_ARTIFACT="$(find "$SATISFACTION_DIR" -type f -name 'gate-*.md' -print -quit)"

MID_PR_HEAD="$(gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .head.sha)"
[[ "$MID_PR_HEAD" == "$SHA" ]] || {
  echo "The pull request head advanced during handoff; no stale manifest will be published." >&2
  exit 1
}

CONTRACT="$CONTRACT" OBSERVED="$OBSERVED" SCREENSHOT="$SCREENSHOT" VIDEO="$VIDEO" \
VERIFIER="$VERIFIER" SHA="$SHA" OUTPUT_DIR="$OUTPUT_DIR" UNIT_RESULT_BUNDLE="$UNIT_RESULT_BUNDLE" \
UI_RESULT_BUNDLE="$UI_RESULT_BUNDLE" FINAL_UI_RESULT_BUNDLE="$FINAL_UI_RESULT_BUNDLE" \
FINAL_SCREENSHOT="$FINAL_SCREENSHOT" SATISFACTION_ARTIFACT="$SATISFACTION_ARTIFACT" \
FINAL_UI_SCREENSHOT="$FINAL_UI_SCREENSHOT" RUNNING_APP_PROOF="$RUNNING_APP_PROOF" \
INITIAL_RUNNING_APP_PROOF="$INITIAL_RUNNING_APP_PROOF" RECORDED_WINDOW_ID="$RECORDED_WINDOW_ID" \
MEDIA_PROOF="$MEDIA_PROOF" \
TEST_INVENTORY="$TEST_INVENTORY" \
LIVE_SWIFT_TRANSCRIPT="$LIVE_SWIFT_TRANSCRIPT" LIVE_SWIFT_ARTIFACT="$LIVE_SWIFT_ARTIFACT" \
LIVE_SWIFT_INVENTORY="$LIVE_SWIFT_INVENTORY" GRAPH_SNAPSHOT="$GRAPH_SNAPSHOT" \
LIVE_SERVICE_IDENTITY="$LIVE_SERVICE_IDENTITY" LIVE_SERVICE_IDENTITY_AFTER="$LIVE_SERVICE_IDENTITY_AFTER" \
APP_BUNDLE="$APP_BUNDLE" PID="$PID" SOL_URL="$SOL_URL" HOSTED_URL="$HOSTED_URL" ACTUAL_UI_TEST="$UI_TEST" \
BINDING_TEST_IDENTIFIER="$BINDING_UI_TEST" FINAL_ATTACH_TEST="$BINDING_UI_TEST" FINAL_ACCESSIBILITY_IDENTIFIER="$FINAL_ACCESSIBILITY_IDENTIFIER" \
APP_IDENTITY="$APP_IDENTITY" \
CONTRACT_DIGEST="$CONTRACT_DIGEST" \
EVIDENCE_BINDING="$EVIDENCE_BINDING" PR_NUMBER="$PR_NUMBER" BASE_SHA="$BASE_SHA" \
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
    "final_ui_screenshot": os.environ["FINAL_UI_SCREENSHOT"],
    "final_ui_xcresult": os.environ["FINAL_UI_RESULT_BUNDLE"],
    "running_app_proof": os.environ["RUNNING_APP_PROOF"],
    "recorded_running_app_proof": os.environ["INITIAL_RUNNING_APP_PROOF"],
    "media_proof": os.environ["MEDIA_PROOF"],
    "protected_test_inventory": os.environ["TEST_INVENTORY"],
    "satisfaction_artifact": os.environ["SATISFACTION_ARTIFACT"],
    "live_swift_transcript": os.environ["LIVE_SWIFT_TRANSCRIPT"],
    "live_swift_artifact": os.environ["LIVE_SWIFT_ARTIFACT"],
    "live_swift_inventory": os.environ["LIVE_SWIFT_INVENTORY"],
    "accepted_graph_snapshot": os.environ["GRAPH_SNAPSHOT"],
    "live_service_identity": os.environ["LIVE_SERVICE_IDENTITY"],
    "live_service_identity_after": os.environ["LIVE_SERVICE_IDENTITY_AFTER"],
    "app_bundle": os.environ["APP_BUNDLE"],
    "app_identity": os.environ["APP_IDENTITY"],
}
manifest = {
    "schema_version": 1,
    "status": "PASS",
    "commit": os.environ["SHA"],
    "git_tree": os.popen("git rev-parse 'HEAD^{tree}'").read().strip(),
    "contract_digest": os.environ["CONTRACT_DIGEST"],
    "evidence_binding": os.environ["EVIDENCE_BINDING"],
    "pull_request_number": int(os.environ["PR_NUMBER"]),
    "base_sha": os.environ["BASE_SHA"],
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "requirement_verbatim": contract["requirement_verbatim"],
    "visible_surface": contract["visible_surface"],
    "expected_visible_result": contract["expected_visible_result"],
    "acceptance_test_identifier": contract["ui_test_identifier"],
    "ui_test_identifier": os.environ["ACTUAL_UI_TEST"],
    "binding_ui_test_identifier": os.environ["BINDING_TEST_IDENTIFIER"],
    "final_accessibility_identifier": os.environ["FINAL_ACCESSIBILITY_IDENTIFIER"],
    "observed_visible_result": observed,
    "app_bundle": os.environ["APP_BUNDLE"],
    "app_pid": int(os.environ["PID"]),
    "proposal_processes_terminated": True,
    "recording_window_id": int(os.environ["RECORDED_WINDOW_ID"]),
    "codesign_verified": True,
    "app_cdhash": os.environ["CDHASH"],
    "app_team_identifier": os.environ["TEAM_IDENTIFIER"],
    "working_tree_clean": True,
    "verifier": os.environ["VERIFIER"],
    "tests": [
        {"name": "macos-unit-tests", "status": "PASS"},
        {"name": "macos-ui-tests", "status": "PASS", "test_identifier": os.environ["ACTUAL_UI_TEST"]},
        {"name": "window-bound-ui-evidence", "status": "PASS", "test_identifier": os.environ["BINDING_TEST_IDENTIFIER"]},
        {"name": "final-relaunch-ui-test", "status": "PASS", "test_identifier": os.environ["FINAL_ATTACH_TEST"]},
        {"name": "live-satisfaction-swift-test", "status": "PASS"},
        {"name": "live-satisfaction-oracle", "status": "PASS"},
        {"name": "trusted-hosted-verification", "status": "PASS"},
    ],
    "sol_review": {"status": "PASS", "check_run_url": os.environ["SOL_URL"]},
    "hosted_verification": {"status": "PASS", "check_run_url": os.environ["HOSTED_URL"]},
    "artifacts": artifacts,
    "artifact_sha256": {name: sha256_path(Path(path)) for name, path in artifacts.items()},
}
path = Path(os.environ["OUTPUT_DIR"]) / "manifest.json"
path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print(path)
PY

python3 "$CONTROL_DIR/scripts/release_gate.py" validate --manifest "$OUTPUT_DIR/manifest.json"

FINAL_PR_JSON="$(gh api "repos/$REPO/pulls/$PR_NUMBER")"
FINAL_PR_HEAD="$(printf '%s' "$FINAL_PR_JSON" | jq -r .head.sha)"
CURRENT_DIGEST="$(python3 -c 'import json,sys;sys.path.insert(0,sys.argv[1]);import validate_acceptance_contract as v;print(v.contract_digest(json.load(open(sys.argv[2]))))' "$CONTROL_DIR/scripts" "$CONTRACT")"
[[ "$FINAL_PR_HEAD" == "$SHA" && "$CURRENT_DIGEST" == "$CONTRACT_DIGEST" ]] || {
  echo "Pull request or acceptance contract changed during handoff; stale evidence rejected." >&2
  exit 1
}

HANDOFF_COMMENT="$(jq -r '
  "## Signed Mac handoff — PASS\n\n" +
  "- Commit: `" + .commit + "`\n" +
  "- Git tree: `" + .git_tree + "`\n" +
  "- Exact UI test: `" + .acceptance_test_identifier + "`\n" +
  "- Final Accessibility identifier: `" + .final_accessibility_identifier + "`\n" +
  "- App team: `" + .app_team_identifier + "`\n" +
  "- App CDHash: `" + .app_cdhash + "`\n" +
  "- Evidence binding: `" + .evidence_binding + "`\n" +
  "- Manifest SHA-256: `" + .artifact_sha256.media_proof + "` (decoded media proof)\n\n" +
  "Observed visible result: " + .observed_visible_result
' "$OUTPUT_DIR/manifest.json")"
HANDOFF_URL="$(gh api -X POST "repos/$REPO/issues/$PR_NUMBER/comments" -f body="$HANDOFF_COMMENT" --jq .html_url)"
gh api -X POST "repos/$REPO/statuses/$SHA" \
  -f state=success \
  -f context='Signed Mac handoff' \
  -f description="Signed handoff PASS pr:$PR_NUMBER binding:${EVIDENCE_BINDING:0:24}" \
  -f target_url="$HANDOFF_URL" >/dev/null
echo "Published the Signed Mac handoff status for $SHA."
