#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFTLINT_CONFIG_PATH="${SWIFTLINT_CONFIG_PATH:-$ROOT_DIR/.swiftlint.yml}"
LINT_SCOPE="${LINT_SCOPE:-changed}"
LINT_BASE_REF="${LINT_BASE_REF:-origin/main}"
RECOMMENDED_SWIFTLINT_VERSION="${RECOMMENDED_SWIFTLINT_VERSION:-0.56.2}"

cd "$ROOT_DIR"

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "error: swiftlint is not installed." >&2
  echo "Install SwiftLint (recommended version ${RECOMMENDED_SWIFTLINT_VERSION}) and rerun this script." >&2
  echo "Example install command: brew install swiftlint" >&2
  exit 127
fi

if [[ ! -f "$SWIFTLINT_CONFIG_PATH" ]]; then
  echo "error: missing SwiftLint config at $SWIFTLINT_CONFIG_PATH" >&2
  exit 1
fi

lint_all_files() {
  echo "Running SwiftLint on all included files."
  swiftlint lint --strict --config "$SWIFTLINT_CONFIG_PATH"
}

lint_changed_files() {
  local diff_base="$LINT_BASE_REF"
  local -a files=()
  local -a existing_files=()

  if ! git rev-parse --verify "$diff_base" >/dev/null 2>&1; then
    if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
      diff_base="HEAD~1"
      echo "warning: base ref '$LINT_BASE_REF' not found; falling back to $diff_base."
    else
      echo "warning: no usable base ref found; linting all tracked Swift files."
      while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        files+=("$file")
      done < <(git ls-files '*.swift')
      diff_base=""
    fi
  else
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      files+=("$file")
    done < <(git diff --name-only --diff-filter=ACMRTUXB "$diff_base"...HEAD -- '*.swift')
  fi

  if [[ -z "$diff_base" && "${#files[@]}" -eq 0 ]]; then
    echo "No Swift files found to lint."
    return 0
  fi

  for file in "${files[@]}"; do
    if [[ -f "$ROOT_DIR/$file" ]]; then
      existing_files+=("$file")
    fi
  done

  if [[ "${#existing_files[@]}" -eq 0 ]]; then
    echo "No changed Swift files to lint."
    return 0
  fi

  if [[ -n "$diff_base" ]]; then
    echo "Running SwiftLint on ${#existing_files[@]} changed file(s) against $diff_base."
  else
    echo "Running SwiftLint on ${#existing_files[@]} tracked Swift file(s)."
  fi

  local failed=0
  for file in "${existing_files[@]}"; do
    echo "Linting $file"
    if ! swiftlint lint --strict --config "$SWIFTLINT_CONFIG_PATH" --path "$file"; then
      failed=1
    fi
  done

  return "$failed"
}

case "$LINT_SCOPE" in
  all)
    lint_all_files
    ;;
  changed)
    lint_changed_files
    ;;
  *)
    echo "error: invalid LINT_SCOPE '$LINT_SCOPE'. Use 'changed' or 'all'." >&2
    exit 2
    ;;
esac
