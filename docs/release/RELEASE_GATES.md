# ShopMikey Release Gates

Last updated: 2026-02-26

## Local Gate Command
```bash
bash /Users/mikey/Documents/Shopmikey/scripts/ci_release_gate.sh
```

## Optional UI Smoke in Gate
```bash
RUN_UI_SMOKE=1 bash /Users/mikey/Documents/Shopmikey/scripts/ci_release_gate.sh
```

## Local Artifacts Output
- Gate artifacts are written to:
  - `/Users/mikey/Documents/Shopmikey/artifacts/release-gate/xcresult`
  - `/Users/mikey/Documents/Shopmikey/artifacts/release-gate/reports`
- Gate summary files:
  - Markdown: `/Users/mikey/Documents/Shopmikey/artifacts/release-gate/reports/release-gate-summary.md`
  - JSON: `/Users/mikey/Documents/Shopmikey/artifacts/release-gate/reports/release-gate-summary.json`
- Coverage files:
  - Text: `/Users/mikey/Documents/Shopmikey/artifacts/release-gate/reports/coverage/coverage-report.txt`
  - JSON: `/Users/mikey/Documents/Shopmikey/artifacts/release-gate/reports/coverage/coverage-report.json`

## Collect Reports Only (without rerunning tests)
```bash
bash /Users/mikey/Documents/Shopmikey/scripts/ci_collect_reports.sh
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

## CI Artifact Retrieval
- Workflow: `.github/workflows/ios-release-gate.yml`
- The workflow uploads `artifacts/release-gate` on every run (including failing runs) as `release-gate-artifacts-<run_id>`.
- Download from the GitHub Actions run page:
  1. Open the workflow run.
  2. Open the `Artifacts` section.
  3. Download `release-gate-artifacts-<run_id>`.

## Stop/Go Thresholds
- Stop release if any gate command exits non-zero.
- Stop release if launch smoke fails on any physical-device test run.
- Stop release if capability audit script reports any `FAIL`.

## Capability Audit Command
```bash
bash /Users/mikey/Documents/Shopmikey/scripts/audit_ios_capabilities.sh
```
