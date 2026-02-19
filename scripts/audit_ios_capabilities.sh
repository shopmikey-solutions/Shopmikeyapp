#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_INFO_PLIST="$ROOT_DIR/POScannerApp/Resources/Info.plist"
EXT_INFO_PLIST="$ROOT_DIR/ShopMikey Scanner/Info.plist"
PROJECT_PBXPROJ="$ROOT_DIR/Shopmikey.xcodeproj/project.pbxproj"

if [[ ! -f "$APP_INFO_PLIST" || ! -f "$EXT_INFO_PLIST" || ! -f "$PROJECT_PBXPROJ" ]]; then
  echo "error: expected project files are missing" >&2
  exit 1
fi

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $1"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  echo "WARN: $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL: $1"
}

read_plist_key() {
  local key="$1"
  local plist="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

require_nonempty_key() {
  local key="$1"
  local plist="$2"
  local label="$3"
  local value
  value="$(read_plist_key "$key" "$plist")"
  if [[ -n "$value" ]]; then
    pass "$label"
  else
    fail "$label"
  fi
}

echo "ShopMikey iOS capability audit"
echo "Workspace: $ROOT_DIR"
echo

require_nonempty_key "NSCameraUsageDescription" "$APP_INFO_PLIST" "App has NSCameraUsageDescription"
require_nonempty_key "NSPhotoLibraryUsageDescription" "$APP_INFO_PLIST" "App has NSPhotoLibraryUsageDescription"
require_nonempty_key "NSFaceIDUsageDescription" "$APP_INFO_PLIST" "App has NSFaceIDUsageDescription"

supports_live_activities="$(read_plist_key "NSSupportsLiveActivities" "$APP_INFO_PLIST")"
if [[ "$supports_live_activities" == "true" ]]; then
  pass "App declares NSSupportsLiveActivities=true"
else
  fail "App declares NSSupportsLiveActivities=true"
fi

app_group_app="$(read_plist_key "AppGroupIdentifier" "$APP_INFO_PLIST")"
app_group_ext="$(read_plist_key "AppGroupIdentifier" "$EXT_INFO_PLIST")"
if [[ -n "$app_group_app" && -n "$app_group_ext" && "$app_group_app" == "$app_group_ext" ]]; then
  pass "App and extension AppGroupIdentifier match ($app_group_app)"
else
  fail "App and extension AppGroupIdentifier are missing or mismatched"
fi

if grep -q "CODE_SIGN_ENTITLEMENTS" "$PROJECT_PBXPROJ"; then
  pass "Project defines CODE_SIGN_ENTITLEMENTS build setting"
else
  warn "Project has no CODE_SIGN_ENTITLEMENTS build setting (verify required capabilities in Signing & Capabilities)"
fi

if grep -q "com\\.apple\\.security\\.application-groups" "$PROJECT_PBXPROJ"; then
  pass "Project references app-group entitlements"
else
  warn "No app-group entitlement key found in project file (verify App Groups capability manually)"
fi

echo
echo "Summary: PASS=$PASS_COUNT WARN=$WARN_COUNT FAIL=$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
