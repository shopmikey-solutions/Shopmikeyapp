#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Shopmikey.xcodeproj"
SCHEME_NAME="${SCHEME_NAME:-POScannerApp}"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "error: missing Xcode project at $PROJECT_PATH" >&2
  exit 1
fi

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
    echo "error: no iOS Simulator destination found. Set SIM_DESTINATION manually." >&2
    exit 1
  fi

  echo "id=$destination_id"
}

SIM_DESTINATION_RESOLVED="$(resolve_sim_destination)"

echo "Updating parser goldens via ParserGoldenTests on $SIM_DESTINATION_RESOLVED"
UPDATE_PARSER_GOLDENS=1 PROJECT_ROOT="$ROOT_DIR" \
  xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -destination "$SIM_DESTINATION_RESOLVED" \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  "OTHER_SWIFT_FLAGS=\$(inherited) -DUPDATE_PARSER_GOLDENS" \
  -only-testing:POScannerAppTests/ParserGoldenTests \
  test

echo
echo "Updated parser golden files (git status):"
git -C "$ROOT_DIR" status --short -- Fixtures/ParserCorpus/expected
