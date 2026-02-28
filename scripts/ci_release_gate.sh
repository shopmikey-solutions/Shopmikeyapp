#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Shopmikey.xcodeproj"
SCHEME_NAME="${SCHEME_NAME:-POScannerApp}"
RUN_UI_SMOKE="${RUN_UI_SMOKE:-0}"
RELEASE_DEVICE_BUILD="${RELEASE_DEVICE_BUILD:-${CI_DEVICE_BUILD:-0}}"
SNAPSHOT_RECORD="${SNAPSHOT_RECORD:-0}"
CI_ARTIFACTS_DIR="${CI_ARTIFACTS_DIR:-$ROOT_DIR/artifacts/release-gate}"
CI_XCRESULT_DIR="${CI_XCRESULT_DIR:-$CI_ARTIFACTS_DIR/xcresult}"
CI_REPORTS_DIR="${CI_REPORTS_DIR:-$CI_ARTIFACTS_DIR/reports}"
STAGE_STATUS_FILE="${CI_STAGE_STATUS_FILE:-$CI_ARTIFACTS_DIR/stage_status.tsv}"
BUILD_XCRESULT_PATH="$CI_XCRESULT_DIR/build.xcresult"
DEVICE_BUILD_XCRESULT_PATH="$CI_XCRESULT_DIR/device-build.xcresult"
TARGETED_TESTS_XCRESULT_PATH="$CI_XCRESULT_DIR/targeted-tests.xcresult"
UNIT_TESTS_XCRESULT_PATH="$CI_XCRESULT_DIR/unit-tests.xcresult"
SNAPSHOT_TESTS_XCRESULT_PATH="$CI_XCRESULT_DIR/snapshot-tests.xcresult"
UI_SMOKE_TESTS_XCRESULT_PATH="$CI_XCRESULT_DIR/ui-smoke-tests.xcresult"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "error: missing Xcode project at $PROJECT_PATH" >&2
  exit 1
fi

mkdir -p "$CI_ARTIFACTS_DIR"
rm -rf "$CI_XCRESULT_DIR" "$CI_REPORTS_DIR"
mkdir -p "$CI_XCRESULT_DIR" "$CI_REPORTS_DIR"
printf "stage\tstatus\tlabel\tresult_bundle\n" > "$STAGE_STATUS_FILE"

PARSER_METRICS_THRESHOLD_FILE="$CI_REPORTS_DIR/parser_metrics_min_f1.txt"
SNAPSHOT_RECORD_MARKER_PATH="$CI_REPORTS_DIR/snapshot_record_mode.txt"
if [[ -n "${PARSER_METRICS_MIN_F1:-}" ]]; then
  printf "%s\n" "$PARSER_METRICS_MIN_F1" > "$PARSER_METRICS_THRESHOLD_FILE"
  echo "Parser metrics threshold enabled: overall_f1 >= $PARSER_METRICS_MIN_F1"
else
  rm -f "$PARSER_METRICS_THRESHOLD_FILE"
fi

if [[ "$SNAPSHOT_RECORD" == "1" ]]; then
  printf "SNAPSHOT_RECORD=1\n" > "$SNAPSHOT_RECORD_MARKER_PATH"
  echo "Snapshot baseline recording enabled."
else
  rm -f "$SNAPSHOT_RECORD_MARKER_PATH"
fi

log_step() {
  echo
  echo "==> $1"
}

record_stage_status() {
  local stage="$1"
  local status="$2"
  local label="$3"
  local result_bundle="$4"
  printf "%s\t%s\t%s\t%s\n" "$stage" "$status" "$label" "$result_bundle" >> "$STAGE_STATUS_FILE"
}

run_gate_step() {
  local stage="$1"
  local label="$2"
  local result_bundle="$3"
  shift 3

  log_step "$label"
  rm -rf "$result_bundle"

  set +e
  "$@" -resultBundlePath "$result_bundle"
  local exit_code=$?
  set -e

  if [[ "$exit_code" -eq 0 ]]; then
    record_stage_status "$stage" "passed" "$label" "$result_bundle"
    return 0
  fi

  record_stage_status "$stage" "failed" "$label" "$result_bundle"
  echo "error: $label failed." >&2
  return "$exit_code"
}

finalize_release_gate() {
  local exit_code=$?
  set +e
  CI_ARTIFACTS_DIR="$CI_ARTIFACTS_DIR" \
  CI_XCRESULT_DIR="$CI_XCRESULT_DIR" \
  CI_REPORTS_DIR="$CI_REPORTS_DIR" \
  CI_STAGE_STATUS_FILE="$STAGE_STATUS_FILE" \
  CI_RELEASE_GATE_EXIT_CODE="$exit_code" \
  CI_RELEASE_GATE_RUN_UI_SMOKE="$RUN_UI_SMOKE" \
  bash "$ROOT_DIR/scripts/ci_collect_reports.sh"
  local collect_exit_code=$?
  set -e

  if [[ "$collect_exit_code" -ne 0 ]]; then
    echo "warning: failed to collect release gate reports (exit $collect_exit_code)." >&2
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    echo
    echo "Release gate failed."
  fi
}

trap finalize_release_gate EXIT

resolve_sim_destination() {
  if [[ -n "${SIM_DESTINATION:-}" ]]; then
    echo "$SIM_DESTINATION"
    return 0
  fi

  echo "Auto-detecting iOS Simulator destination..." >&2

  local destinations
  destinations="$(xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -showdestinations \
    | grep "platform:iOS Simulator" \
    | grep -Ev "Any iOS Simulator Device|dvtdevice-")"

  local preferred_id
  preferred_id="$(printf '%s\n' "$destinations" \
    | grep "name:iPhone 15" \
    | sed -n 's/.*platform:iOS Simulator[^}]*id:\([^,}]*\).*/\1/p' \
    | head -n 1)"

  if [[ -n "$preferred_id" ]]; then
    echo "id=$preferred_id"
    return 0
  fi

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
    destination_id="$(xcrun simctl list devices available \
      | awk -F '[()]' '/iPhone/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F-]{36}$/) { print $i; exit } }')"
  fi

  if [[ -z "$destination_id" ]]; then
    echo "No available iOS Simulator devices found." >&2
    exit 1
  fi

  echo "Using simulator ID: $destination_id" >&2
  xcrun simctl boot "$destination_id" >/dev/null 2>&1 || true

  echo "id=$destination_id"
}

TEST_PARALLEL_FLAGS=(-parallel-testing-enabled NO -maximum-parallel-testing-workers 1)
SIM_DESTINATION_RESOLVED="$(resolve_sim_destination)"

run_gate_step \
  "build" \
  "Release gate: build iOS app (Simulator)" \
  "$BUILD_XCRESULT_PATH" \
  xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Debug \
  -destination "$SIM_DESTINATION_RESOLVED" \
  build

if [[ "$RELEASE_DEVICE_BUILD" == "1" ]]; then
  run_gate_step \
    "device-build" \
    "Release gate: optional device/archive build" \
    "$DEVICE_BUILD_XCRESULT_PATH" \
    xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration Debug \
    -destination "generic/platform=iOS" \
    build
else
  log_step "Release gate: optional device/archive build"
  echo "Skipping device/archive build (RELEASE_DEVICE_BUILD not set)"
  record_stage_status "device-build" "skipped" "Release gate: optional device/archive build" "-"
fi

run_gate_step \
  "targeted-tests" \
  "Release gate: targeted stability tests" \
  "$TARGETED_TESTS_XCRESULT_PATH" \
  xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -destination "$SIM_DESTINATION_RESOLVED" \
  -enableCodeCoverage YES \
  "${TEST_PARALLEL_FLAGS[@]}" \
  -only-testing:POScannerAppTests/ReviewViewModelTests \
  -only-testing:POScannerAppTests/APIClientRetryAfterTests \
  -only-testing:POScannerAppTests/SandboxInvariantTests \
  test

run_gate_step \
  "unit-tests" \
  "Release gate: full unit test suite" \
  "$UNIT_TESTS_XCRESULT_PATH" \
  xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -destination "$SIM_DESTINATION_RESOLVED" \
  -enableCodeCoverage YES \
  "${TEST_PARALLEL_FLAGS[@]}" \
  -only-testing:POScannerAppTests \
  test

run_gate_step \
  "snapshot-tests" \
  "Release gate: snapshot tests" \
  "$SNAPSHOT_TESTS_XCRESULT_PATH" \
  xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -destination "$SIM_DESTINATION_RESOLVED" \
  -enableCodeCoverage YES \
  "${TEST_PARALLEL_FLAGS[@]}" \
  -only-testing:POScannerAppTests/OCRReviewSnapshotTests \
  -only-testing:POScannerAppTests/ReviewModesSnapshotTests \
  test

if [[ "$RUN_UI_SMOKE" == "1" ]]; then
  run_gate_step \
    "ui-smoke-tests" \
    "Release gate: UI smoke tests" \
    "$UI_SMOKE_TESTS_XCRESULT_PATH" \
    xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -destination "$SIM_DESTINATION_RESOLVED" \
    -enableCodeCoverage YES \
    "${TEST_PARALLEL_FLAGS[@]}" \
    -only-testing:POScannerAppUITests/POScannerAppUITests/testTabNavigationAndSettingsControls \
    -only-testing:POScannerAppUITests/POScannerAppUITests/testSmokeFlowLaunchToReviewFixtureAndHistory \
    test
fi

echo
echo "Release gate passed."
