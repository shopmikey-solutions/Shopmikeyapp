#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Shopmikey.xcodeproj"
SCHEME_NAME="${SCHEME_NAME:-POScannerApp}"
RUN_UI_SMOKE="${RUN_UI_SMOKE:-0}"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "error: missing Xcode project at $PROJECT_PATH" >&2
  exit 1
fi

log_step() {
  echo
  echo "==> $1"
}

resolve_sim_destination() {
  if [[ -n "${SIM_DESTINATION:-}" ]]; then
    echo "$SIM_DESTINATION"
    return 0
  fi

  local destinations
  destinations="$(xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -showdestinations \
    | grep "platform:iOS Simulator" \
    | grep -Ev "Any iOS Simulator Device|dvtdevice-")"

  local destination_id
  destination_id="$(printf '%s\n' "$destinations" \
    | grep "name:iPhone" \
    | sed -n 's/.*platform:iOS Simulator[^}]*id:\([^,}]*\).*/\1/p' \
    | head -n 1)"

  if [[ -z "$destination_id" ]]; then
    destination_id="$(printf '%s\n' "$destinations" \
      | sed -n 's/.*platform:iOS Simulator[^}]*id:\([^,}]*\).*/\1/p' \
      | head -n 1)"
  fi

  if [[ -z "$destination_id" ]]; then
    echo "error: no iOS Simulator destination found. Set SIM_DESTINATION manually." >&2
    exit 1
  fi

  echo "id=$destination_id"
}

SIM_DESTINATION_RESOLVED="$(resolve_sim_destination)"
TEST_PARALLEL_FLAGS=(-parallel-testing-enabled NO -maximum-parallel-testing-workers 1)

log_step "Release gate: build iOS app"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  build

log_step "Release gate: targeted stability tests"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -destination "$SIM_DESTINATION_RESOLVED" \
  "${TEST_PARALLEL_FLAGS[@]}" \
  -only-testing:POScannerAppTests/ReviewViewModelTests \
  -only-testing:POScannerAppTests/APIClientRetryAfterTests \
  -only-testing:POScannerAppTests/SandboxInvariantTests \
  test

log_step "Release gate: full unit test suite"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -destination "$SIM_DESTINATION_RESOLVED" \
  "${TEST_PARALLEL_FLAGS[@]}" \
  -only-testing:POScannerAppTests \
  test

if [[ "$RUN_UI_SMOKE" == "1" ]]; then
  log_step "Release gate: UI smoke tests"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -destination "$SIM_DESTINATION_RESOLVED" \
    "${TEST_PARALLEL_FLAGS[@]}" \
    -only-testing:POScannerAppUITests/POScannerAppUITests/testTabNavigationAndSettingsControls \
    -only-testing:POScannerAppUITests/POScannerAppUITests/testSmokeFlowLaunchToReviewFixtureAndHistory \
    test
fi

echo
echo "Release gate passed."
