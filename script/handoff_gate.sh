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
PROPOSAL_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/harness-proposal.${SHA}.XXXXXX")"
PROPOSAL_REPO="$PROPOSAL_PARENT/repo"
PROPOSAL_HOME="$PROPOSAL_PARENT/home"
PROPOSAL_TMP="$PROPOSAL_PARENT/tmp"
ISOLATED_ONTOLOGY_ROOT="$PROPOSAL_PARENT/ontology"
LIVE_ONTOLOGY_ROOT="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Ontology"
PROCESS_REPORTS_DIR="$CANDIDATE_OUTPUT_DIR/process-reports"
PROPOSAL_PROCESS_REPORT="$CANDIDATE_OUTPUT_DIR/proposal-processes.json"
UI_STAGING_ROOT="$HOME/.local/share/harness-ui-testing/current"
READONLY_PROXY_READY="$PROPOSAL_PARENT/readonly-proxy.json"
READONLY_PROXY_PID=""
RECORDED_WRAPPER_PID=""
FINAL_WRAPPER_PID=""
OPERATOR_HOME="$HOME"
rm -rf "$UI_STAGING_ROOT"
mkdir -p "$PROPOSAL_HOME" "$PROPOSAL_TMP" "$ISOLATED_ONTOLOGY_ROOT" "$PROCESS_REPORTS_DIR" "$UI_STAGING_ROOT/tmp"
git worktree add --detach "$PROPOSAL_REPO" "$SHA" >/dev/null
for authority_directory in accepted candidates; do
  if [[ -d "$LIVE_ONTOLOGY_ROOT/$authority_directory" ]]; then
    /bin/cp -R "$LIVE_ONTOLOGY_ROOT/$authority_directory" "$ISOLATED_ONTOLOGY_ROOT/"
  else
    mkdir -p "$ISOLATED_ONTOLOGY_ROOT/$authority_directory"
  fi
done

set_artifact_paths() {
  local directory="$1"
  UNIT_TEST_TRANSCRIPT="$directory/HarnessUnitTests.log"
  SCREENSHOT="$directory/visible-result.png"
  FINAL_SCREENSHOT="$directory/final-relaunch-visible-result.png"
  UI_AUTOMATION_PROOF="$directory/ui-automation.json"
  FINAL_UI_AUTOMATION_PROOF="$directory/final-ui-automation.json"
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
CANDIDATE_DERIVED_DATA="$UI_STAGING_ROOT/DerivedData"
BUILT_APP_BUNDLE="$CANDIDATE_DERIVED_DATA/Build/Products/Debug/Harness.app"
APP_BUNDLE="$OUTPUT_DIR/Harness.app"
UNIT_DERIVED_DATA="$PROPOSAL_REPO/.build/HarnessUnitDerivedData"
PROPOSAL_LIVE_SWIFT_DIR="$PROPOSAL_TMP/live-satisfaction-swift"
GRAPH_SNAPSHOT="$OUTPUT_DIR/accepted-graph-before.json"
GRAPH_SNAPSHOT_AFTER="$OUTPUT_DIR/accepted-graph-after.json"
AUTHORITY_SNAPSHOT_BEFORE="$OUTPUT_DIR/authority-before.json"
AUTHORITY_SNAPSHOT_AFTER="$OUTPUT_DIR/authority-after.json"
LIVE_SWIFT_INVENTORY="$OUTPUT_DIR/live-satisfaction-swift-inventory.json"
LIVE_SERVICE_IDENTITY="$OUTPUT_DIR/live-service-identity.txt"
mkdir -p "$OUTPUT_DIR" "$CANDIDATE_OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
rm -rf "$SATISFACTION_DIR"
rm -f "$SCREENSHOT" "$FINAL_SCREENSHOT" "$UI_AUTOMATION_PROOF" "$FINAL_UI_AUTOMATION_PROOF" "$RUNNING_APP_PROOF" "$INITIAL_RUNNING_APP_PROOF" "$MEDIA_PROOF" "$TEST_INVENTORY" "$VIDEO"
mkdir -p "$SATISFACTION_DIR"

cleanup_handoff() {
  pkill -x Harness >/dev/null 2>&1 || true
  for wrapper in "$RECORDED_WRAPPER_PID" "$FINAL_WRAPPER_PID"; do
    [[ -z "$wrapper" ]] || wait "$wrapper" 2>/dev/null || true
  done
  if [[ -n "$READONLY_PROXY_PID" ]] && kill -0 "$READONLY_PROXY_PID" 2>/dev/null; then
    kill -TERM "$READONLY_PROXY_PID" 2>/dev/null || true
    wait "$READONLY_PROXY_PID" 2>/dev/null || true
  fi
  git -C "$ROOT_DIR" worktree remove --force "$PROPOSAL_REPO" >/dev/null 2>&1 || true
  rm -rf "$UI_STAGING_ROOT"
  rm -rf "$PROPOSAL_PARENT" "$CANDIDATE_OUTPUT_DIR"
}
trap cleanup_handoff EXIT

python3 "$CONTROL_DIR/scripts/readonly_sparql_proxy.py" \
  --ready-file "$READONLY_PROXY_READY" >"$PROPOSAL_PARENT/readonly-proxy.log" 2>&1 &
READONLY_PROXY_PID=$!
for _ in {1..40}; do
  [[ -s "$READONLY_PROXY_READY" ]] && break
  sleep 0.1
done
[[ -s "$READONLY_PROXY_READY" ]] || { echo "The protected read-only SPARQL proxy did not start." >&2; exit 1; }
READONLY_PROXY_PORT="$(jq -r .port "$READONLY_PROXY_READY")"
[[ "$READONLY_PROXY_PORT" =~ ^[0-9]+$ ]] || { echo "The protected query proxy returned an invalid port." >&2; exit 1; }

PROPOSAL_SANDBOX="(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip \"localhost:$READONLY_PROXY_PORT\"))(allow network-outbound (remote ip \"localhost:11434\"))(deny appleevent-send)(deny mach-lookup (global-name \"com.apple.pboard\"))(deny file-read* (subpath \"$HOME\") (subpath \"$LIVE_ONTOLOGY_ROOT\"))(allow file-read* (subpath \"$APP_BUNDLE\"))(deny file-write* (subpath \"$CONTROL_DIR\") (subpath \"$ROOT_DIR\") (subpath \"$OUTPUT_DIR\") (subpath \"$CANDIDATE_OUTPUT_DIR\") (subpath \"$PROCESS_REPORTS_DIR\") (subpath \"$UI_STAGING_ROOT\") (subpath \"$HOME/.local/bin\") (subpath \"$LIVE_ONTOLOGY_ROOT\") (literal \"$HOME/.codex/hooks.json\"))(deny process-exec (literal \"/usr/bin/security\") (literal \"/usr/bin/ssh\") (literal \"/usr/bin/osascript\") (literal \"/usr/bin/open\") (literal \"/usr/bin/automator\") (literal \"/usr/bin/shortcuts\") (literal \"/usr/sbin/screencapture\") (literal \"/usr/bin/pbcopy\") (literal \"/usr/bin/pbpaste\") (literal \"/opt/homebrew/bin/gh\") (literal \"/usr/local/bin/gh\"))"

proposal_exec() {
  local report label
  label="${PROPOSAL_LABEL:-foreground}"
  report="$(mktemp "$PROCESS_REPORTS_DIR/${label}.XXXXXX.json")"
  (
    cd "$PROPOSAL_REPO"
    python3 "$CONTROL_DIR/scripts/run_with_timeout.py" \
      --seconds "${PROPOSAL_TIMEOUT:-1200}" --label "$label" --process-report "$report" -- \
      /usr/bin/env -i HOME="$PROPOSAL_HOME" TMPDIR="$PROPOSAL_TMP" \
      PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      USER="${USER:-adamblair}" LOGNAME="${LOGNAME:-adamblair}" LANG="en_US.UTF-8" \
      HARNESS_REPO_ROOT="$PROPOSAL_REPO" HARNESS_ONTOLOGY_ROOT="$ISOLATED_ONTOLOGY_ROOT" \
      ONTOLOGY_ACCEPTED_DIR="$ISOLATED_ONTOLOGY_ROOT/accepted" \
      HARNESS_FUSEKI_SPARQL_ENDPOINT="http://localhost:$READONLY_PROXY_PORT/understood/query" \
      HARNESS_FUSEKI_DATA_ENDPOINT="http://localhost:$READONLY_PROXY_PORT/updates-denied" \
      HARNESS_EXPECTED_PID="${HARNESS_EXPECTED_PID:-}" \
      HARNESS_EXPECTED_WINDOW_BOUNDS="${HARNESS_EXPECTED_WINDOW_BOUNDS:-}" \
      HARNESS_FINAL_ACCESSIBILITY_IDENTIFIER="${HARNESS_FINAL_ACCESSIBILITY_IDENTIFIER:-}" \
      HARNESS_ATTACH_EXISTING_APP="${HARNESS_ATTACH_EXISTING_APP:-}" \
      HARNESS_REQUIRE_LIVE_SATISFACTION="${HARNESS_REQUIRE_LIVE_SATISFACTION:-}" \
      HARNESS_SATISFACTION_COMMIT="${HARNESS_SATISFACTION_COMMIT:-}" \
      HARNESS_SATISFACTION_OUTPUT_DIR="${HARNESS_SATISFACTION_OUTPUT_DIR:-}" \
      /usr/bin/sandbox-exec -p "$PROPOSAL_SANDBOX" -- "$@"
  )
}

# Xcode cannot run inside an outer sandbox because SwiftPM invokes its own
# nested sandbox. These commands are limited to compiler/signing orchestration
# over protected build inputs. Candidate application and unit-test code is only
# executed by proposal_exec or proposal_start. Signed UI actions are executed by
# the immutable installed accessibility driver, never by proposal test code.
trusted_exec() {
  local report label
  label="${TRUSTED_LABEL:-trusted-orchestrator}"
  report="$(mktemp "$PROCESS_REPORTS_DIR/${label}.XXXXXX.json")"
  (
    cd "$PROPOSAL_REPO"
    python3 "$CONTROL_DIR/scripts/run_with_timeout.py" \
      --seconds "${TRUSTED_TIMEOUT:-1200}" --label "$label" --process-report "$report" -- \
      /usr/bin/env -i HOME="$OPERATOR_HOME" TMPDIR="$UI_STAGING_ROOT/tmp" \
      PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      USER="${USER:-adamblair}" LOGNAME="${LOGNAME:-adamblair}" LANG="en_US.UTF-8" \
      HARNESS_REPO_ROOT="$PROPOSAL_REPO" HARNESS_ONTOLOGY_ROOT="$ISOLATED_ONTOLOGY_ROOT" \
      ONTOLOGY_ACCEPTED_DIR="$ISOLATED_ONTOLOGY_ROOT/accepted" \
      HARNESS_EXPECTED_PID="${HARNESS_EXPECTED_PID:-}" \
      HARNESS_EXPECTED_WINDOW_BOUNDS="${HARNESS_EXPECTED_WINDOW_BOUNDS:-}" \
      HARNESS_FINAL_ACCESSIBILITY_IDENTIFIER="${HARNESS_FINAL_ACCESSIBILITY_IDENTIFIER:-}" \
      HARNESS_ATTACH_EXISTING_APP="${HARNESS_ATTACH_EXISTING_APP:-}" \
      "$@"
  )
}

proposal_start() {
  local report ready
  report="$(mktemp "$PROCESS_REPORTS_DIR/background.XXXXXX.json")"
  ready="$(mktemp "$PROCESS_REPORTS_DIR/background-ready.XXXXXX.json")"
  (
    cd "$PROPOSAL_REPO"
    python3 "$CONTROL_DIR/scripts/run_with_timeout.py" \
      --seconds 600 --label background-app --termination-ok \
      --process-report "$report" --ready-file "$ready" -- \
      /usr/bin/env -i HOME="$PROPOSAL_HOME" TMPDIR="$PROPOSAL_TMP" \
      PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      USER="${USER:-adamblair}" LOGNAME="${LOGNAME:-adamblair}" LANG="en_US.UTF-8" \
      HARNESS_REPO_ROOT="$PROPOSAL_REPO" HARNESS_ONTOLOGY_ROOT="$ISOLATED_ONTOLOGY_ROOT" \
      ONTOLOGY_ACCEPTED_DIR="$ISOLATED_ONTOLOGY_ROOT/accepted" \
      HARNESS_FUSEKI_SPARQL_ENDPOINT="http://localhost:$READONLY_PROXY_PORT/understood/query" \
      HARNESS_FUSEKI_DATA_ENDPOINT="http://localhost:$READONLY_PROXY_PORT/updates-denied" \
      HARNESS_EXPECTED_PID="${HARNESS_EXPECTED_PID:-}" \
      HARNESS_EXPECTED_WINDOW_BOUNDS="${HARNESS_EXPECTED_WINDOW_BOUNDS:-}" \
      HARNESS_FINAL_ACCESSIBILITY_IDENTIFIER="${HARNESS_FINAL_ACCESSIBILITY_IDENTIFIER:-}" \
      HARNESS_ATTACH_EXISTING_APP="${HARNESS_ATTACH_EXISTING_APP:-}" \
      /usr/bin/sandbox-exec -p "$PROPOSAL_SANDBOX" -- "$@"
  )
}

terminate_proposal_processes() {
  pkill -x Harness >/dev/null 2>&1 || true
  for _ in {1..20}; do
    [[ -z "$(pgrep -x Harness || true)" ]] && break
    sleep 0.25
  done
  [[ -z "$(pgrep -x Harness || true)" ]] || {
    echo "A proposal Harness process survived final evidence capture." >&2
    return 1
  }
  for wrapper in "$RECORDED_WRAPPER_PID" "$FINAL_WRAPPER_PID"; do
    [[ -z "$wrapper" ]] || wait "$wrapper" 2>/dev/null || true
  done
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

FINAL_ACCESSIBILITY_IDENTIFIER="$(CONTRACT="$CONTRACT" /usr/bin/python3 - <<'PY'
import json, os
from pathlib import Path
print(json.loads(Path(os.environ["CONTRACT"]).read_text(encoding="utf-8"))["final_accessibility_identifier"])
PY
)"

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
python3 "$CONTROL_DIR/scripts/snapshot_authority_state.py" \
  --ontology-root "$LIVE_ONTOLOGY_ROOT" --output "$AUTHORITY_SNAPSHOT_BEFORE"
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

if PROPOSAL_LABEL=expected-denial proposal_exec /usr/bin/curl -fsS https://api.github.com >/dev/null 2>&1; then
  echo "The proposal sandbox unexpectedly reached the public network." >&2
  exit 1
fi
if PROPOSAL_LABEL=expected-denial proposal_exec /opt/homebrew/bin/gh auth status >/dev/null 2>&1; then
  echo "The proposal sandbox unexpectedly executed GitHub credential tooling." >&2
  exit 1
fi
if PROPOSAL_LABEL=expected-denial proposal_exec /usr/bin/security find-identity -v >/dev/null 2>&1; then
  echo "The proposal sandbox unexpectedly read the signing keychain." >&2
  exit 1
fi
if PROPOSAL_LABEL=expected-denial proposal_exec /bin/ls "$HOME/Documents" >/dev/null 2>&1; then
  echo "The proposal sandbox unexpectedly read Adam's operator home." >&2
  exit 1
fi
if PROPOSAL_LABEL=expected-denial proposal_exec /usr/bin/osascript -e 'return 1' >/dev/null 2>&1; then
  echo "The proposal sandbox unexpectedly acquired Apple Events control." >&2
  exit 1
fi
if PROPOSAL_LABEL=expected-denial proposal_exec /usr/bin/pbpaste >/dev/null 2>&1; then
  echo "The proposal sandbox unexpectedly read the operator clipboard." >&2
  exit 1
fi
if PROPOSAL_LABEL=expected-denial proposal_exec /usr/bin/curl -fsS \
  --data-urlencode 'query=ASK { ?s ?p ?o }' http://localhost:3030/understood/query >/dev/null 2>&1; then
  echo "The proposal sandbox unexpectedly bypassed the read-only query proxy." >&2
  exit 1
fi
if PROPOSAL_LABEL=expected-denial proposal_exec /usr/bin/touch "$LIVE_ONTOLOGY_ROOT/.proposal-write-probe" >/dev/null 2>&1; then
  rm -f "$LIVE_ONTOLOGY_ROOT/.proposal-write-probe"
  echo "The proposal sandbox unexpectedly wrote Adam's live ontology." >&2
  exit 1
fi
if PROPOSAL_LABEL=expected-denial proposal_exec /usr/bin/touch "$CONTROL_DIR/.proposal-write-probe" >/dev/null 2>&1; then
  rm -f "$CONTROL_DIR/.proposal-write-probe"
  echo "The proposal sandbox unexpectedly wrote an installed verifier path." >&2
  exit 1
fi
proposal_exec /usr/bin/curl -fsS --data-urlencode 'query=ASK { ?s ?p ?o }' \
  "http://localhost:$READONLY_PROXY_PORT/understood/query" >/dev/null
if PROPOSAL_LABEL=expected-denial proposal_exec /usr/bin/curl -fsS -X POST \
  --data-urlencode 'update=DELETE WHERE { ?s ?p ?o }' \
  "http://localhost:$READONLY_PROXY_PORT/updates-denied" >/dev/null 2>&1; then
  echo "The proposal sandbox unexpectedly acquired a SPARQL update route." >&2
  exit 1
fi

HARNESS_EXPECTED_PID=0 HARNESS_EXPECTED_WINDOW_BOUNDS=UNSET HARNESS_FINAL_ACCESSIBILITY_IDENTIFIER=UNSET HARNESS_ATTACH_EXISTING_APP=0 \
  TRUSTED_LABEL=trusted-project-generation trusted_exec xcodegen generate
TRUSTED_LABEL=trusted-app-build trusted_exec xcodebuild build \
  -project Harness.xcodeproj \
  -scheme Harness \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$CANDIDATE_DERIVED_DATA"
TRUSTED_LABEL=trusted-unit-build trusted_exec xcodebuild build-for-testing \
  -project Harness.xcodeproj \
  -scheme HarnessUnitVerification \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$UNIT_DERIVED_DATA"

[[ -d "$BUILT_APP_BUNDLE" ]] || { echo "The built Harness.app bundle is missing." >&2; exit 1; }
/bin/cp -R "$BUILT_APP_BUNDLE" "$APP_BUNDLE"
SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | awk -F '"' '/Apple Development: Adam Blair/{print $2; exit}')"
[[ -n "$SIGNING_IDENTITY" ]] || { echo "Adam's trusted Apple Development signing identity is unavailable." >&2; exit 1; }
python3 "$CONTROL_DIR/scripts/verify_app_identity.py" \
  --app "$APP_BUNDLE" --output "$APP_IDENTITY"
TEAM_IDENTIFIER="$(jq -r .team_identifier "$APP_IDENTITY")"
CDHASH="$(jq -r .cdhash "$APP_IDENTITY")"

UNIT_HOST_APP="$UNIT_DERIVED_DATA/Build/Products/Debug/Harness.app"
UNIT_TEST_BUNDLE="$UNIT_HOST_APP/Contents/PlugIns/HarnessTests.xctest"
UNIT_TEST_BINARY="$UNIT_TEST_BUNDLE/Contents/MacOS/HarnessTests"
[[ -x "$UNIT_TEST_BINARY" ]] || { echo "The direct Harness unit test executable is missing." >&2; exit 1; }
UNIT_OTOOL_OUTPUT="$(/usr/bin/otool -l "$UNIT_TEST_BINARY")"
for unit_rpath in '@loader_path/../../../../MacOS' '@loader_path/../../../../Frameworks'; do
  if ! grep -Fq "path $unit_rpath " <<<"$UNIT_OTOOL_OUTPUT"; then
    TRUSTED_LABEL=trusted-unit-linkage trusted_exec /usr/bin/install_name_tool -add_rpath "$unit_rpath" "$UNIT_TEST_BINARY"
  fi
done
TRUSTED_LABEL=trusted-unit-signing trusted_exec /usr/bin/codesign --force --deep \
  --sign "$SIGNING_IDENTITY" "$UNIT_TEST_BUNDLE"
TRUSTED_LABEL=trusted-unit-host-signing trusted_exec /usr/bin/codesign --force --deep \
  --sign "$SIGNING_IDENTITY" --preserve-metadata=entitlements,requirements,flags,runtime "$UNIT_HOST_APP"

pkill -x Harness >/dev/null 2>&1 || true
for _ in {1..20}; do
  [[ -z "$(pgrep -x Harness || true)" ]] && break
  sleep 0.25
done
[[ -z "$(pgrep -x Harness || true)" ]] || {
  echo "A stale Harness process survived termination; refusing ambiguous app evidence." >&2
  exit 1
}

XCTEST_BINARY="$(xcrun --find xctest)"
set +e
PROPOSAL_LABEL=isolated-unit-tests proposal_exec "$XCTEST_BINARY" "$UNIT_TEST_BUNDLE" \
  2>&1 | tee "$UNIT_TEST_TRANSCRIPT"
UNIT_TEST_STATUS="${PIPESTATUS[0]}"
set -e
[[ "$UNIT_TEST_STATUS" == "0" ]] || { echo "The isolated Harness unit tests failed." >&2; exit 1; }
python3 "$CONTROL_DIR/scripts/validate_xctest_transcript.py" \
  --expected "$TEST_INVENTORY" --transcript "$UNIT_TEST_TRANSCRIPT"

pkill -x Harness >/dev/null 2>&1 || true
proposal_start "$APP_BUNDLE/Contents/MacOS/Harness" >"$CANDIDATE_OUTPUT_DIR/recorded-app.log" 2>&1 &
RECORDED_WRAPPER_PID=$!
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
INITIAL_ACCESSIBILITY_IDENTIFIER="$(jq -r '.ui_automation[0].identifier' "$CONTRACT")"
[[ -n "$INITIAL_ACCESSIBILITY_IDENTIFIER" && "$INITIAL_ACCESSIBILITY_IDENTIFIER" != null ]] || {
  echo "The committed UI automation lacks its required initial wait identifier." >&2
  exit 1
}
TRUSTED_TIMEOUT=40 TRUSTED_LABEL=trusted-recorded-ui-prepare trusted_exec xcrun swift "$CONTROL_DIR/scripts/run_accessibility_contract.swift" \
  --pid "$RECORDED_PID" \
  --executable "$APP_BUNDLE/Contents/MacOS/Harness" \
  --bundle-identifier com.adamblair.Harness \
  --contract "$CONTRACT" \
  --prepare-only
PREPARE_RUNNING_APP_PROOF="$PROPOSAL_TMP/recording-window.json"
TRUSTED_TIMEOUT=40 TRUSTED_LABEL=trusted-recording-window-binding trusted_exec xcrun swift "$CONTROL_DIR/scripts/verify_running_app.swift" \
  --pid "$RECORDED_PID" \
  --executable "$APP_BUNDLE/Contents/MacOS/Harness" \
  --identifier "$INITIAL_ACCESSIBILITY_IDENTIFIER" \
  --output "$PREPARE_RUNNING_APP_PROOF"
RECORDED_WINDOW_ID="$(jq -r .window_id "$PREPARE_RUNNING_APP_PROOF")"
[[ "$RECORDED_WINDOW_ID" =~ ^[0-9]+$ ]] || { echo "Recorded candidate window lacks a CGWindowID." >&2; exit 1; }
/usr/sbin/screencapture -v -l"$RECORDED_WINDOW_ID" -x -k "$VIDEO" &
VIDEO_PID=$!
video_cleanup() {
  if kill -0 "$VIDEO_PID" 2>/dev/null; then
    kill -TERM "$VIDEO_PID" 2>/dev/null || true
  fi
  wait "$VIDEO_PID" 2>/dev/null || true
}
trap 'video_cleanup; cleanup_handoff' EXIT
sleep 0.5
TRUSTED_TIMEOUT=90 TRUSTED_LABEL=trusted-recorded-ui-actions trusted_exec xcrun swift "$CONTROL_DIR/scripts/run_accessibility_contract.swift" \
  --pid "$RECORDED_PID" \
  --executable "$APP_BUNDLE/Contents/MacOS/Harness" \
  --bundle-identifier com.adamblair.Harness \
  --contract "$CONTRACT" \
  --output "$UI_AUTOMATION_PROOF"
TRUSTED_TIMEOUT=40 TRUSTED_LABEL=trusted-recorded-result-binding trusted_exec xcrun swift "$CONTROL_DIR/scripts/verify_running_app.swift" \
  --pid "$RECORDED_PID" \
  --executable "$APP_BUNDLE/Contents/MacOS/Harness" \
  --identifier "$FINAL_ACCESSIBILITY_IDENTIFIER" \
  --output "$INITIAL_RUNNING_APP_PROOF"
[[ "$(jq -r .window_id "$INITIAL_RUNNING_APP_PROOF")" == "$RECORDED_WINDOW_ID" ]] || {
  echo "The committed UI actions ended outside the exact recorded candidate window." >&2
  exit 1
}
/usr/sbin/screencapture -x -l "$RECORDED_WINDOW_ID" "$SCREENSHOT"
sleep 1.5
kill -0 "$VIDEO_PID" 2>/dev/null || {
  echo "The video recording ended before the committed UI actions completed." >&2
  exit 1
}
kill -INT "$VIDEO_PID" 2>/dev/null || true
wait "$VIDEO_PID" 2>/dev/null || true
trap cleanup_handoff EXIT
[[ -s "$VIDEO" && -s "$SCREENSHOT" ]] || {
  echo "The exact visible requirement did not produce both video and screenshot evidence." >&2
  exit 1
}

pkill -x Harness >/dev/null 2>&1 || true
wait "$RECORDED_WRAPPER_PID" 2>/dev/null || true
for _ in {1..20}; do
  [[ -z "$(pgrep -x Harness || true)" ]] && break
  sleep 0.25
done
[[ -z "$(pgrep -x Harness || true)" ]] || {
  echo "A stale Harness process survived before the final normal relaunch." >&2
  exit 1
}
proposal_start "$APP_BUNDLE/Contents/MacOS/Harness" >"$CANDIDATE_OUTPUT_DIR/final-app.log" 2>&1 &
FINAL_WRAPPER_PID=$!
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

TRUSTED_TIMEOUT=40 TRUSTED_LABEL=trusted-final-ui-prepare trusted_exec xcrun swift "$CONTROL_DIR/scripts/run_accessibility_contract.swift" \
  --pid "$PID" \
  --executable "$APP_BUNDLE/Contents/MacOS/Harness" \
  --bundle-identifier com.adamblair.Harness \
  --contract "$CONTRACT" \
  --prepare-only
TRUSTED_TIMEOUT=90 TRUSTED_LABEL=trusted-final-ui-actions trusted_exec xcrun swift "$CONTROL_DIR/scripts/run_accessibility_contract.swift" \
  --pid "$PID" \
  --executable "$APP_BUNDLE/Contents/MacOS/Harness" \
  --bundle-identifier com.adamblair.Harness \
  --contract "$CONTRACT" \
  --output "$FINAL_UI_AUTOMATION_PROOF"
TRUSTED_TIMEOUT=40 TRUSTED_LABEL=trusted-final-result-binding trusted_exec xcrun swift "$CONTROL_DIR/scripts/verify_running_app.swift" \
  --pid "$PID" \
  --executable "$APP_BUNDLE/Contents/MacOS/Harness" \
  --identifier "$FINAL_ACCESSIBILITY_IDENTIFIER" \
  --output "$RUNNING_APP_PROOF"
kill -0 "$PID" 2>/dev/null || { echo "The normal relaunched Harness PID exited during final verification." >&2; exit 1; }
PROCESS_COMMAND="$(ps -p "$PID" -o command=)"
[[ "$PROCESS_COMMAND" == "$APP_BUNDLE/Contents/MacOS/Harness"* ]] || {
  echo "Final verified Harness process is not the signed and UI-tested app bundle." >&2
  exit 1
}
TRUSTED_TIMEOUT=40 TRUSTED_LABEL=trusted-final-result-recheck trusted_exec xcrun swift "$CONTROL_DIR/scripts/verify_running_app.swift" \
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
  --png "$FINAL_SCREENSHOT" \
  --video "$VIDEO" \
  --output "$MEDIA_PROOF"

# The reserved full-pipeline Swift test is the only protected OntologyKit test
# omitted by hosted CI. It must pass here with live dependencies required.
LIVE_SWIFT_TEST="OntologyKitTests.satisfactionGateAdamRealQuestionGetsCompleteAnswer"
rm -rf "$PROPOSAL_LIVE_SWIFT_DIR"
mkdir -p "$PROPOSAL_LIVE_SWIFT_DIR"
set +e
PROPOSAL_TIMEOUT=600 \
  HARNESS_REQUIRE_LIVE_SATISFACTION=1 \
  HARNESS_SATISFACTION_COMMIT="$SHA" \
  HARNESS_SATISFACTION_OUTPUT_DIR="$PROPOSAL_LIVE_SWIFT_DIR" \
  proposal_exec /usr/bin/xcrun swift test \
      --disable-sandbox \
      --package-path "$PROPOSAL_REPO/Packages/OntologyKit" \
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
LIVE_SWIFT_COUNT="$(find "$PROPOSAL_LIVE_SWIFT_DIR" -type f -name 'gate-*.md' | wc -l | tr -d ' ')"
[[ "$LIVE_SWIFT_COUNT" == "1" ]] || {
  echo "The reserved live satisfaction Swift test did not produce exactly one proof artifact." >&2
  exit 1
}

# No proposal process may remain alive while protected controls promote and
# generate the final evidence bundle.
terminate_proposal_processes
rm -rf "$LIVE_SWIFT_DIR"
mkdir -p "$LIVE_SWIFT_DIR"
/bin/cp -R "$PROPOSAL_LIVE_SWIFT_DIR"/. "$LIVE_SWIFT_DIR"/
python3 "$CONTROL_DIR/scripts/snapshot_authority_state.py" \
  --ontology-root "$LIVE_ONTOLOGY_ROOT" --output "$AUTHORITY_SNAPSHOT_AFTER"
cmp -s "$AUTHORITY_SNAPSHOT_BEFORE" "$AUTHORITY_SNAPSHOT_AFTER" || {
  echo "Adam's live accepted or candidate authority changed during proposal execution." >&2
  exit 1
}
python3 "$CONTROL_DIR/scripts/live_satisfaction_oracle.py" \
  --snapshot-output "$GRAPH_SNAPSHOT_AFTER"
[[ "$(jq -r .sha256 "$GRAPH_SNAPSHOT_AFTER")" == "$GRAPH_DIGEST" ]] || {
  echo "The live Fuseki accepted graph changed during proposal execution." >&2
  exit 1
}
PROCESS_REPORTS_DIR="$PROCESS_REPORTS_DIR" PROPOSAL_PROCESS_REPORT="$PROPOSAL_PROCESS_REPORT" /usr/bin/python3 - <<'PY'
import json
import os
from pathlib import Path

directory = Path(os.environ["PROCESS_REPORTS_DIR"])
reports = []
errors = []
for path in sorted(directory.glob("*.json")):
    if path.name.startswith("background-ready."):
        continue
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"unreadable process report {path.name}: {error}")
        continue
    reports.append(report)
    if report.get("retained_pids") != [] or report.get("timed_out") is not False:
        errors.append(f"process group was not clean: {path.name}")
    if report.get("label") == "expected-denial":
        if report.get("returncode") in (None, 0):
            errors.append(f"adversarial isolation probe unexpectedly passed: {path.name}")
    elif report.get("status") != "PASS":
        errors.append(f"proposal process failed or retained descendants: {path.name}")
payload = {
    "schema_version": 1,
    "status": "PASS" if reports and not errors else "FAIL",
    "commands": reports,
    "retained_pids": [pid for report in reports for pid in report.get("retained_pids", [])],
    "errors": errors,
}
Path(os.environ["PROPOSAL_PROCESS_REPORT"]).write_text(
    json.dumps(payload, indent=2) + "\n", encoding="utf-8"
)
if errors or not reports:
    raise SystemExit("; ".join(errors) if errors else "no proposal process reports were produced")
PY
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
PROPOSAL_PROCESS_REPORT="$OUTPUT_DIR/proposal-processes.json"
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
VERIFIER="$VERIFIER" SHA="$SHA" OUTPUT_DIR="$OUTPUT_DIR" UNIT_TEST_TRANSCRIPT="$UNIT_TEST_TRANSCRIPT" \
FINAL_SCREENSHOT="$FINAL_SCREENSHOT" SATISFACTION_ARTIFACT="$SATISFACTION_ARTIFACT" \
UI_AUTOMATION_PROOF="$UI_AUTOMATION_PROOF" FINAL_UI_AUTOMATION_PROOF="$FINAL_UI_AUTOMATION_PROOF" \
RUNNING_APP_PROOF="$RUNNING_APP_PROOF" \
INITIAL_RUNNING_APP_PROOF="$INITIAL_RUNNING_APP_PROOF" RECORDED_WINDOW_ID="$RECORDED_WINDOW_ID" \
RECORDED_PID="$RECORDED_PID" \
MEDIA_PROOF="$MEDIA_PROOF" \
TEST_INVENTORY="$TEST_INVENTORY" \
LIVE_SWIFT_TRANSCRIPT="$LIVE_SWIFT_TRANSCRIPT" LIVE_SWIFT_ARTIFACT="$LIVE_SWIFT_ARTIFACT" \
LIVE_SWIFT_INVENTORY="$LIVE_SWIFT_INVENTORY" GRAPH_SNAPSHOT="$GRAPH_SNAPSHOT" \
GRAPH_SNAPSHOT_AFTER="$GRAPH_SNAPSHOT_AFTER" \
AUTHORITY_SNAPSHOT_BEFORE="$AUTHORITY_SNAPSHOT_BEFORE" AUTHORITY_SNAPSHOT_AFTER="$AUTHORITY_SNAPSHOT_AFTER" \
PROPOSAL_PROCESS_REPORT="$PROPOSAL_PROCESS_REPORT" \
LIVE_SERVICE_IDENTITY="$LIVE_SERVICE_IDENTITY" LIVE_SERVICE_IDENTITY_AFTER="$LIVE_SERVICE_IDENTITY_AFTER" \
APP_BUNDLE="$APP_BUNDLE" PID="$PID" SOL_URL="$SOL_URL" HOSTED_URL="$HOSTED_URL" FINAL_ACCESSIBILITY_IDENTIFIER="$FINAL_ACCESSIBILITY_IDENTIFIER" \
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
    "unit_test_transcript": os.environ["UNIT_TEST_TRANSCRIPT"],
    "ui_automation_proof": os.environ["UI_AUTOMATION_PROOF"],
    "final_screenshot": os.environ["FINAL_SCREENSHOT"],
    "final_ui_automation_proof": os.environ["FINAL_UI_AUTOMATION_PROOF"],
    "running_app_proof": os.environ["RUNNING_APP_PROOF"],
    "recorded_running_app_proof": os.environ["INITIAL_RUNNING_APP_PROOF"],
    "media_proof": os.environ["MEDIA_PROOF"],
    "protected_test_inventory": os.environ["TEST_INVENTORY"],
    "satisfaction_artifact": os.environ["SATISFACTION_ARTIFACT"],
    "live_swift_transcript": os.environ["LIVE_SWIFT_TRANSCRIPT"],
    "live_swift_artifact": os.environ["LIVE_SWIFT_ARTIFACT"],
    "live_swift_inventory": os.environ["LIVE_SWIFT_INVENTORY"],
    "accepted_graph_snapshot": os.environ["GRAPH_SNAPSHOT"],
    "accepted_graph_snapshot_after": os.environ["GRAPH_SNAPSHOT_AFTER"],
    "authority_snapshot_before": os.environ["AUTHORITY_SNAPSHOT_BEFORE"],
    "authority_snapshot_after": os.environ["AUTHORITY_SNAPSHOT_AFTER"],
    "proposal_process_report": os.environ["PROPOSAL_PROCESS_REPORT"],
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
    "ui_automation": contract["ui_automation"],
    "final_accessibility_identifier": os.environ["FINAL_ACCESSIBILITY_IDENTIFIER"],
    "observed_visible_result": observed,
    "app_bundle": os.environ["APP_BUNDLE"],
    "app_pid": int(os.environ["PID"]),
    "recorded_app_pid": int(os.environ["RECORDED_PID"]),
    "proposal_processes_terminated": True,
    "recording_window_id": int(os.environ["RECORDED_WINDOW_ID"]),
    "codesign_verified": True,
    "app_cdhash": os.environ["CDHASH"],
    "app_team_identifier": os.environ["TEAM_IDENTIFIER"],
    "working_tree_clean": True,
    "verifier": os.environ["VERIFIER"],
    "tests": [
        {"name": "macos-unit-tests", "status": "PASS"},
        {"name": "signed-mac-ui-automation", "status": "PASS"},
        {"name": "window-bound-ui-evidence", "status": "PASS"},
        {"name": "final-relaunch-ui-automation", "status": "PASS"},
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

python3 "$CONTROL_DIR/scripts/release_gate.py" validate --pre-publication --manifest "$OUTPUT_DIR/manifest.json"

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
python3 "$CONTROL_DIR/scripts/release_gate.py" validate --manifest "$OUTPUT_DIR/manifest.json"
echo "Published the Signed Mac handoff status for $SHA."
