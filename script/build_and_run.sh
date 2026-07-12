#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Harness"
BUNDLE_ID="com.adamblair.Harness"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/HarnessDerivedData"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
PROJECT_PATH="$ROOT_DIR/Harness.xcodeproj"

if [[ ! -d "$PROJECT_PATH" ]]; then
  command -v xcodegen >/dev/null 2>&1 || {
    echo "XcodeGen is required to create Harness.xcodeproj from project.yml." >&2
    exit 1
  }
  xcodegen generate --project "$ROOT_DIR" --spec "$ROOT_DIR/project.yml"
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Built Harness.app was not found at $APP_BUNDLE" >&2
  exit 1
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
