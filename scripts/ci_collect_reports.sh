#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_ARTIFACTS_DIR="${CI_ARTIFACTS_DIR:-$ROOT_DIR/artifacts/release-gate}"
CI_XCRESULT_DIR="${CI_XCRESULT_DIR:-$CI_ARTIFACTS_DIR/xcresult}"
CI_REPORTS_DIR="${CI_REPORTS_DIR:-$CI_ARTIFACTS_DIR/reports}"
CI_RAW_DIR="${CI_RAW_DIR:-$CI_REPORTS_DIR/raw}"
CI_COVERAGE_DIR="${CI_COVERAGE_DIR:-$CI_REPORTS_DIR/coverage}"
CI_STAGE_STATUS_FILE="${CI_STAGE_STATUS_FILE:-$CI_ARTIFACTS_DIR/stage_status.tsv}"
CI_SUMMARY_PATH="${CI_SUMMARY_PATH:-$CI_REPORTS_DIR/release-gate-summary.md}"
CI_JSON_SUMMARY_PATH="${CI_JSON_SUMMARY_PATH:-$CI_REPORTS_DIR/release-gate-summary.json}"
CI_COVERAGE_JSON_PATH="$CI_COVERAGE_DIR/coverage-report.json"
CI_COVERAGE_TEXT_PATH="$CI_COVERAGE_DIR/coverage-report.txt"
CI_RELEASE_GATE_EXIT_CODE="${CI_RELEASE_GATE_EXIT_CODE:-0}"
CI_RELEASE_GATE_RUN_UI_SMOKE="${CI_RELEASE_GATE_RUN_UI_SMOKE:-0}"

export CI_ARTIFACTS_DIR
export CI_XCRESULT_DIR
export CI_REPORTS_DIR
export CI_RAW_DIR
export CI_COVERAGE_DIR
export CI_STAGE_STATUS_FILE
export CI_SUMMARY_PATH
export CI_JSON_SUMMARY_PATH
export CI_COVERAGE_JSON_PATH
export CI_COVERAGE_TEXT_PATH
export CI_RELEASE_GATE_EXIT_CODE
export CI_RELEASE_GATE_RUN_UI_SMOKE

mkdir -p "$CI_XCRESULT_DIR" "$CI_REPORTS_DIR" "$CI_RAW_DIR" "$CI_COVERAGE_DIR"
if [[ ! -f "$CI_STAGE_STATUS_FILE" ]]; then
  printf "stage\tstatus\tlabel\tresult_bundle\n" > "$CI_STAGE_STATUS_FILE"
fi

collect_stage_raw_data() {
  while IFS=$'\t' read -r stage _status _label result_bundle; do
    if [[ "$stage" == "stage" || -z "$stage" ]]; then
      continue
    fi
    if [[ ! -d "$result_bundle" ]]; then
      continue
    fi

    xcrun xcresulttool get content-availability --path "$result_bundle" --compact > "$CI_RAW_DIR/${stage}-content-availability.json" 2>/dev/null || true
    xcrun xcresulttool get build-results --path "$result_bundle" --compact > "$CI_RAW_DIR/${stage}-build-results.json" 2>/dev/null || true
    xcrun xcresulttool get test-results summary --path "$result_bundle" --compact > "$CI_RAW_DIR/${stage}-test-summary.json" 2>/dev/null || true
  done < "$CI_STAGE_STATUS_FILE"
}

collect_coverage_report() {
  local coverage_bundle=""
  local coverage_candidates=(
    "$CI_XCRESULT_DIR/unit-tests.xcresult"
    "$CI_XCRESULT_DIR/targeted-tests.xcresult"
    "$CI_XCRESULT_DIR/ui-smoke-tests.xcresult"
  )

  for candidate in "${coverage_candidates[@]}"; do
    if [[ ! -d "$candidate" ]]; then
      continue
    fi

    if xcrun xccov view --report --json "$candidate" > "$CI_COVERAGE_JSON_PATH" 2> "$CI_COVERAGE_DIR/coverage.stderr"; then
      xcrun xccov view --report "$candidate" > "$CI_COVERAGE_TEXT_PATH" 2>/dev/null || true
      coverage_bundle="$candidate"
      break
    fi
  done

  if [[ -z "$coverage_bundle" ]]; then
    printf '{"note":"Coverage data unavailable for this run."}\n' > "$CI_COVERAGE_JSON_PATH"
    echo "Coverage data unavailable for this run." > "$CI_COVERAGE_TEXT_PATH"
  fi

  echo "$coverage_bundle" > "$CI_COVERAGE_DIR/coverage-source.txt"
}

write_summary_files() {
  python3 - <<'PY'
import csv
import datetime
import json
import os
from pathlib import Path

artifacts_dir = Path(os.environ["CI_ARTIFACTS_DIR"])
stage_status_file = Path(os.environ["CI_STAGE_STATUS_FILE"])
raw_dir = Path(os.environ["CI_RAW_DIR"])
summary_path = Path(os.environ["CI_SUMMARY_PATH"])
json_summary_path = Path(os.environ["CI_JSON_SUMMARY_PATH"])
coverage_json_path = Path(os.environ["CI_COVERAGE_JSON_PATH"])
coverage_source_path = Path(os.environ["CI_COVERAGE_DIR"]) / "coverage-source.txt"
exit_code = int(os.environ.get("CI_RELEASE_GATE_EXIT_CODE", "0"))
ui_smoke = os.environ.get("CI_RELEASE_GATE_RUN_UI_SMOKE", "0")

def load_json_if_exists(path: Path):
    if not path.exists() or path.stat().st_size == 0:
        return None
    try:
        return json.loads(path.read_text())
    except Exception:
        return None

def as_failures(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return [value]
    return []

stage_rows = []
if stage_status_file.exists():
    with stage_status_file.open(newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            stage = row.get("stage", "").strip()
            if not stage:
                continue
            status = row.get("status", "").strip() or "unknown"
            label = row.get("label", "").strip() or stage
            bundle = row.get("result_bundle", "").strip()
            stage_info = {
                "stage": stage,
                "status": status,
                "label": label,
                "result_bundle": bundle,
                "test_summary": None,
                "test_failures": [],
                "build_errors": [],
            }

            test_summary = load_json_if_exists(raw_dir / f"{stage}-test-summary.json")
            if test_summary:
                stage_info["test_summary"] = {
                    "result": test_summary.get("result"),
                    "total_test_count": test_summary.get("totalTestCount"),
                    "passed_tests": test_summary.get("passedTests"),
                    "failed_tests": test_summary.get("failedTests"),
                    "skipped_tests": test_summary.get("skippedTests"),
                    "expected_failures": test_summary.get("expectedFailures"),
                }
                stage_info["test_failures"] = as_failures(test_summary.get("testFailures"))

            build_results = load_json_if_exists(raw_dir / f"{stage}-build-results.json")
            if build_results:
                stage_info["build_errors"] = build_results.get("errors") or []
                stage_info["build_warnings"] = build_results.get("warnings") or []
            else:
                stage_info["build_warnings"] = []

            stage_rows.append(stage_info)

coverage_payload = load_json_if_exists(coverage_json_path)
coverage_source = ""
if coverage_source_path.exists():
    coverage_source = coverage_source_path.read_text().strip()

coverage_targets = []
if isinstance(coverage_payload, dict):
    targets = coverage_payload.get("targets", [])
elif isinstance(coverage_payload, list):
    targets = coverage_payload
else:
    targets = []

for target in targets:
    if not isinstance(target, dict):
        continue
    name = target.get("name")
    line_coverage = target.get("lineCoverage")
    if name is None or line_coverage is None:
        continue
    coverage_targets.append(
        {
            "name": name,
            "line_coverage": line_coverage,
        }
    )

coverage_targets.sort(key=lambda item: item["line_coverage"], reverse=True)

summary_data = {
    "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "exit_code": exit_code,
    "ui_smoke_enabled": ui_smoke == "1",
    "artifacts_dir": str(artifacts_dir),
    "stages": stage_rows,
    "coverage_source_bundle": coverage_source or None,
    "coverage_targets": coverage_targets,
}
json_summary_path.write_text(json.dumps(summary_data, indent=2, sort_keys=True))

lines = []
lines.append("# iOS Release Gate Summary")
lines.append("")
lines.append(f"- Generated (UTC): {summary_data['generated_at_utc']}")
lines.append(f"- Gate exit code: `{exit_code}`")
lines.append(f"- UI smoke enabled: `{'yes' if summary_data['ui_smoke_enabled'] else 'no'}`")
lines.append(f"- Artifacts directory: `{artifacts_dir}`")
lines.append("")
lines.append("## Stage Results")
lines.append("")
lines.append("| Stage | Status | Tests (pass/fail/skip) | Result Bundle |")
lines.append("|---|---|---|---|")

for stage in stage_rows:
    test_summary = stage.get("test_summary")
    if test_summary:
        test_counts = f"{test_summary.get('passed_tests', 'n/a')}/{test_summary.get('failed_tests', 'n/a')}/{test_summary.get('skipped_tests', 'n/a')}"
    else:
        test_counts = "n/a"
    bundle_name = Path(stage["result_bundle"]).name if stage.get("result_bundle") else "n/a"
    lines.append(f"| {stage['label']} | {stage['status']} | {test_counts} | `{bundle_name}` |")

failure_lines = []
for stage in stage_rows:
    for failure in stage.get("test_failures", []):
        if not isinstance(failure, dict):
            continue
        name = failure.get("testName") or failure.get("testIdentifierString") or "Unknown test"
        target = failure.get("targetName") or "Unknown target"
        message = (failure.get("failureText") or "No failure text.").strip().replace("\n", " ")
        failure_lines.append((stage["label"], target, name, message))

if failure_lines:
    lines.append("")
    lines.append("## Test Failures")
    lines.append("")
    for stage_label, target, name, message in failure_lines[:30]:
        lines.append(f"- **{stage_label}** `{target}/{name}`: {message}")

build_error_lines = []
for stage in stage_rows:
    for error in stage.get("build_errors", []):
        if not isinstance(error, dict):
            continue
        message = (error.get("message") or "No error message.").strip().replace("\n", " ")
        build_error_lines.append((stage["label"], message))

if build_error_lines:
    lines.append("")
    lines.append("## Build Errors")
    lines.append("")
    for stage_label, message in build_error_lines[:20]:
        lines.append(f"- **{stage_label}**: {message}")

lines.append("")
lines.append("## Coverage")
lines.append("")
if coverage_source:
    lines.append(f"- Coverage source bundle: `{Path(coverage_source).name}`")
else:
    lines.append("- Coverage source bundle: `none`")

if coverage_targets:
    lines.append("")
    lines.append("| Target | Line Coverage |")
    lines.append("|---|---|")
    for target in coverage_targets[:12]:
        lines.append(f"| {target['name']} | {target['line_coverage']:.2%} |")
else:
    lines.append("- Coverage data unavailable for this run.")

summary_path.write_text("\n".join(lines) + "\n")
PY
}

collect_stage_raw_data
collect_coverage_report
write_summary_files

if [[ -n "${GITHUB_STEP_SUMMARY:-}" && -f "$CI_SUMMARY_PATH" ]]; then
  {
    echo ""
    cat "$CI_SUMMARY_PATH"
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "Release gate reports generated:"
echo "- Markdown summary: $CI_SUMMARY_PATH"
echo "- JSON summary: $CI_JSON_SUMMARY_PATH"
echo "- Coverage report: $CI_COVERAGE_TEXT_PATH"
