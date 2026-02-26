# ShopMikey Release Gates

Last updated: 2026-02-26

## Local Gate Command
```bash
bash /Users/mikey/Documents/Shopmikey/scripts/ci_release_gate.sh
```

## Local Gate Behavior
- Default local behavior is simulator-first and provisioning-safe.
- By default, the gate runs:
  - simulator Debug build
  - targeted stability tests
  - full unit test suite
  - optional UI smoke tests when `RUN_UI_SMOKE=1`
- Device/archive build path is opt-in and strict:
```bash
RELEASE_DEVICE_BUILD=1 bash /Users/mikey/Documents/Shopmikey/scripts/ci_release_gate.sh
```
- Equivalent CI opt-in flag is also supported:
```bash
CI_DEVICE_BUILD=1 bash /Users/mikey/Documents/Shopmikey/scripts/ci_release_gate.sh
```
- When device build is not enabled, the gate prints:
  - `Skipping device/archive build (RELEASE_DEVICE_BUILD not set)`

## Optional UI Smoke in Gate
```bash
RUN_UI_SMOKE=1 bash /Users/mikey/Documents/Shopmikey/scripts/ci_release_gate.sh
```

## Local Lint Command
```bash
bash /Users/mikey/Documents/Shopmikey/scripts/lint.sh
```

## Lint Scope Controls
- Default scope: changed Swift files only (relative to `LINT_BASE_REF`, default `origin/main`).
- Full lint run:
```bash
LINT_SCOPE=all bash /Users/mikey/Documents/Shopmikey/scripts/lint.sh
```
- Override base ref for changed-file lint:
```bash
LINT_BASE_REF=origin/main bash /Users/mikey/Documents/Shopmikey/scripts/lint.sh
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
1. SwiftLint on changed Swift files (PR base branch diff).
2. Simulator-targeted Debug build:
```bash
xcodebuild -project Shopmikey.xcodeproj -scheme POScannerApp -configuration Debug -destination '<resolved iOS Simulator>' build
```
3. Optional strict device/archive build when explicitly enabled:
```bash
RELEASE_DEVICE_BUILD=1 bash /Users/mikey/Documents/Shopmikey/scripts/ci_release_gate.sh
```
4. Targeted stability tests:
- `POScannerAppTests/ReviewViewModelTests`
- `POScannerAppTests/APIClientRetryAfterTests`
- `POScannerAppTests/SandboxInvariantTests`
5. Full unit test bundle:
- `POScannerAppTests`
6. Optional UI smoke tests:
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
