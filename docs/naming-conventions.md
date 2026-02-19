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

## File Naming
- File name should match the primary type in that file.
- Avoid generic names like `Provider` and `SimpleEntry`; prefer contextual names like `PartsIntakeWidgetProvider`.

## Accessibility Identifier Naming
- Use lower-case dotted names by feature scope.
- Pattern: `<feature>.<screenOrGroup>.<element>`
- Examples: `scan.scanButton`, `review.submitButton`, `history.scopePicker`, `keyboard.doneButton`

## Logging Categories
- Use subsystem `com.mikey.POScannerApp`.
- Category pattern: `<Area>.<Component>` or `<Lifecycle>.<Component>`.
- Keep categories stable for easy filtering in Console and log exports.
