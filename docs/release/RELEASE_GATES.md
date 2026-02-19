# ShopMikey Release Gates

Last updated: 2026-02-19

## Local Gate Command
```bash
bash /Users/mikey/Documents/Shopmikey/scripts/ci_release_gate.sh
```

## Optional UI Smoke in Gate
```bash
RUN_UI_SMOKE=1 bash /Users/mikey/Documents/Shopmikey/scripts/ci_release_gate.sh
```

## What the Gate Enforces
1. Device-targeted build:
```bash
xcodebuild -project Shopmikey.xcodeproj -scheme POScannerApp -configuration Debug -destination 'generic/platform=iOS' build
```
2. Targeted stability tests:
- `POScannerAppTests/ReviewViewModelTests`
- `POScannerAppTests/APIClientRetryAfterTests`
- `POScannerAppTests/SandboxInvariantTests`
3. Full unit test bundle:
- `POScannerAppTests`
4. Optional UI smoke tests:
- `POScannerAppUITests/testTabNavigationAndSettingsControls`
- `POScannerAppUITests/testSmokeFlowLaunchToReviewFixtureAndHistory`

## Stop/Go Thresholds
- Stop release if any gate command exits non-zero.
- Stop release if launch smoke fails on any physical-device test run.
- Stop release if capability audit script reports any `FAIL`.

## Capability Audit Command
```bash
bash /Users/mikey/Documents/Shopmikey/scripts/audit_ios_capabilities.sh
```
