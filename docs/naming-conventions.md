# ShopMikey Naming Conventions

## Target and Folder Naming
- App target source root: `POScannerApp/`
- Test targets: `POScannerAppTests/`, `POScannerAppUITests/`
- Widget/Live Activity extension source root: `ShopMikey Scanner/`
- Extension target name: `ShopMikey ScannerExtension`

## Swift Type Naming
- Use `UpperCamelCase` with no underscores.
- Include clear suffixes for surface area:
  - `...View`, `...ViewModel`, `...Service`, `...Bridge`, `...Store`, `...Manager`
  - Widget extension types should include `Widget` or `LiveActivity` when applicable.
- Keep abbreviations readable and consistent: prefer `API`, `OCR`, `PO`, `UI` over mixed forms.

## File Naming
- File name should match the primary type in that file.
- Avoid generic names like `Provider` and `SimpleEntry`; prefer contextual names like `PartsIntakeWidgetProvider`.
- Keep file names `UpperCamelCase` plus role suffixes when applicable (`ReviewView`, `ScanViewModel`).

## Accessibility Identifier Naming
- Use lower-case dotted names by feature scope.
- Pattern: `<feature>.<screenOrGroup>.<element>`
- Examples: `scan.scanButton`, `review.submitButton`, `history.scopePicker`, `keyboard.doneButton`

## Logging Categories
- Use subsystem `com.mikey.POScannerApp`.
- Category pattern: `<Area>.<Component>` or `<Lifecycle>.<Component>`.
- Keep categories stable for easy filtering in Console and log exports.

## SwiftLint Policy
- Lint config: `.swiftlint.yml`.
- Local command: `bash scripts/lint.sh`.
- CI lint scope: changed Swift files compared to the PR base branch.
- Lint failures block CI when changed files introduce violations.
- Naming and complexity rules enforced by SwiftLint:
  - `identifier_name` for lower camel case identifiers and bounded lengths.
  - `type_name` for consistent type naming and bounded lengths.
  - `cyclomatic_complexity` to keep new logic branches manageable.
- `unused_import` is configured as an analyzer rule for advanced analyze runs with compiler logs.
