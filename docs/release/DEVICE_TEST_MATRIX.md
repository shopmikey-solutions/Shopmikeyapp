# ShopMikey Physical Device Test Matrix

Last updated: 2026-02-19

## Scope
- Device-first validation for launch/runtime stability after startup hardening.
- Focus path: launch -> scan -> OCR review -> submission -> history.

## Test Matrix
| Area | Scenario | Steps | Pass Criteria | Fail Criteria |
|---|---|---|---|---|
| Launch | Cold launch | Force-quit app, relaunch from Home Screen | App reaches `ShopMikey` scan UI within 3 seconds and remains responsive | Stuck splash, watchdog kill, or frozen first frame |
| Launch | Warm launch | Background app for 15 seconds, reopen | Returns to prior tab without crash | Relaunch loop, blank content, crash |
| Launch | Repeated launch cycle | Repeat cold launch 10 times | 10/10 successful launches | Any freeze, kill, or fatal error |
| Scan | Camera open/close | Tap `scan.scanButton`, open source sheet, cancel/close repeatedly | No crash, no UI lock, no ghost overlays | Stuck modal, frozen camera sheet, crash |
| Scan | OCR pipeline start | Start invoice capture and wait for OCR review | Processing banner appears and resolves to review | Hangs in processing or exits unexpectedly |
| OCR Review | Continue flow | From OCR review, continue to parts intake review | `Parts Intake Review` appears with editable fields | Missing destination, blank review, crash |
| Submission | Submit path | Fill required fields and submit | Success alert appears or actionable error appears | Silent failure, duplicate submit loop, app freeze |
| History | Data visibility | Open History tab after scan flow | Draft/submission reflected correctly in history sections | Missing item, stale status, crash on history open |
| Deep Links | Scan/history/settings | Trigger app deep links (`shopmikey://scan`, `shopmikey://history`, `shopmikey://settings`) | Correct tab opens consistently | Wrong tab, ignored deep link, crash |
| Live Activity | Foreground startup gate | Launch app and start processing quickly | Live Activity updates only after app is active and startup gate delay passes | Premature churn at launch, repeated noisy updates |

## Logging Checks During Matrix
- Confirm no repeated launch-time timeout errors from `Startup.CoreData`.
- Confirm no repeated foreground-gate churn from `Startup.LiveActivity`.
- Confirm no runaway cancellation loops from `Startup.Scan`, `Startup.Review`, or `Startup.History`.

## Required Build/OS Coverage
- Latest iOS production hardware (primary).
- Previous iOS major (if supported).
- At least one device with Dynamic Island for Live Activity UX.
