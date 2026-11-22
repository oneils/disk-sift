# Neural DSP Plugin Removal

## Overview
- New sidebar section "Plugins" that lists installed Neural DSP plugins (and leftovers of removed ones) and removes only the plugins the user selects, never all of them at once.
- Neural DSP has no uninstaller; its support page says to delete the files by hand in each folder (https://support.neuraldsp.com/help/plugin-file-location). One plugin spreads over up to eight folders plus package receipts, most of them owned by root.
- Root-owned parts are removed with one macOS administrator password prompt (`osascript ... with administrator privileges`). It's a narrow exception: the general `Remover` keeps skipping root-owned items.
- Closes `docs/backlog/remove-selected-neural-dsp-plugins.md` (added by PR #14; delete it in the final commit if #14 is merged first, otherwise drop it from #14).

## Context (from discovery)
- Real install checked on the user's Mac: 7 installed plugins plus leftovers of Archetype Gojira X, Archetype Rabea X and Fortin Cali Suite (manual, settings, receipts only).
- Locations of plugin `<Name>`:
  - AU `/Library/Audio/Plug-Ins/Components/<Name>.component` (dir `root:wheel` 755)
  - VST2 `/Library/Audio/Plug-Ins/VST/<Name>.vst`
  - VST3 `/Library/Audio/Plug-Ins/VST3/<Name>.vst3`
  - AAX `/Library/Application Support/Avid/Audio/Plug-Ins/<Name>.aaxplugin`
  - app `/Applications/Neural DSP/<Name>.app` (dir `root:admin` 775)
  - presets `/Library/Audio/Presets/Neural DSP/<Name>/` (the folder is 777, but its contents (`Artists/`, artist folders, `.xml`) are `root:wheel` 755 trees; it contains `User/` with the user's own presets)
  - manual `/Library/Application Support/Neural DSP/<Name>/` (a PDF; folder 777 for some plugins, 775 `root:admin` for others)
  - settings `~/Library/Application Support/Neural DSP/<Name>/` (`<Name>.settings`, `plugin.settings`, `MIDI`)
  - receipts `com.neuraldsp.<NameWithoutSpaces>(AU|VST|VST3|AAX|App|Presets|Manual).pkg` in `pkgutil --pkgs`
- Code to reuse:
  - `SiftPaths` (`systemLibrary`, `applications`, `library`) for every root, so tests run on temp trees
  - `CommandRunner` / `FakeCommandRunner`, `Trasher`, `Writability.canRemove`, `CanonicalPath`, `DirectorySizer`, `RunningApps`
  - `ReportSheet` with `removedByPolicy`, `ReportContext`, `TriStateCheckBox`, `EmptyStateView`, `SizeText`, `RevealMenu`
- Sidebar: `Section` enum and `ShellModel` in `Sources/DiskSift/ContentView.swift`.
- Permission facts that shape the design: `/Library/Audio/Presets` is world-writable without the sticky bit, and `/Applications` and `/Applications/Neural DSP` are writable by the admin group. So a local account can swap a parent folder between validation and a root `rm`, unlike `~/Library`, where `Remover` accepts that window.
- Out of scope: plugins whose files are all gone and only receipts remain. Grouping starts from files on disk, and the user has none of these.

## Development Approach
- **testing approach**: Regular (code first, then tests)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change (`make test`, `make lint`)
- maintain backward compatibility

## Testing Strategy
- **unit tests**: Swift Testing, real temporary file trees via `Fixture` (no filesystem mocks); system calls through fakes (`FakeCommandRunner`, fake privileged runner, fake trasher, fake running apps).
- **e2e tests**: the project has none; the real `osascript` path is verified manually (Post-Completion).

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- **SiftCore `NeuralDSP` folder**: `NeuralDSPLocations` (the eight roots derived from `SiftPaths`), `NeuralDSPScanner` (finds parts, groups them by name, sizes them, attaches receipts), `NeuralDSPRemover` (re-validates, root step, Trash step, verification).
- **Root step first**: if the user cancels the password prompt, nothing is removed at all, not even the user-writable parts. Then user-writable parts go to the Trash.
- **Root or not is decided at removal time** by a deep check (`Writability.canTrashDeep`): the part passes `Writability.canRemove(.trash)`, and every directory inside it (fts, `FTS_PHYSICAL`, symlinks not followed) is writable and searchable by the user. A sticky directory also requires owning each entry. Parts that pass go to the Trash (recoverable) through the existing `Remover`. The rest is deleted permanently in the root step. The scanner uses the same check for the `needsAdmin` hint, and the remover recomputes it (the flag isn't trusted, like `Finding.requiresRoot`).
- **Safety**:
  - Every path is re-validated before removal: canonical, a direct child of its own root, extension matching the root, never a root.
  - Symlinks are ignored by the scanner and refused by the remover. Neural DSP never installs any.
  - A kind root that is itself a symlink, or whose canonical path differs from the standardized `SiftPaths`-derived path, makes every part under it refused.
  - Receipts must match the exact pattern for a selected plugin and part.
  - Paths reach the shell only through `osascript` argv and AppleScript `quoted form of`, never string interpolation.
  - The root script pins the parent before deleting: `cd -P -- <parent> && [ "$(pwd -P)" = <parent> ] && /bin/rm -rf -- <name>`, so swapping a parent folder after validation has no effect.
  - Accepted remaining risk: the last component itself being swapped for a symlink between `cd` and `rm`. `rm` deletes a symlink as a link, so that is harmless.
- **App side**: `PluginsModel` (`@Observable @MainActor`) + `PluginsView`; reuses `ReportSheet` with a new `ReportContext.plugins`.

## Technical Details
- `enum PluginPartKind: au, vst, vst3, aax, app, presets, manual, settings`. Each kind knows its root and extension (`component`, `vst`, `vst3`, `aaxplugin`, `app`, none for directory kinds) and its receipt suffix (`AU`, `VST`, `VST3`, `AAX`, `App`, `Presets`, `Manual`; settings has none).
- `struct PluginPart { kind, url, size, inaccessible, containsUserPresets, needsAdmin }`.
- `struct NeuralDSPPlugin: Identifiable { name, parts, receipts: [String] }`, plus `totalSize` and `hasPluginBundles` (any of au/vst/vst3/aax/app). It's "leftovers" when there are no bundles.
- Part name = file name minus the kind's extension (bundle kinds) or the folder name (directory kinds). Entries with the wrong extension, hidden names, symlinks, anything that isn't a real directory (every kind is a directory or bundle), and the `Neural DSP` roots themselves are ignored.
- `containsUserPresets`: the presets folder has a `User` subfolder with at least one non-hidden entry.
- Receipt match: `^com\.neuraldsp\.<NameWithoutSpaces, regex-escaped>(AU|VST|VST3|AAX|App|Presets|Manual)\.pkg$`. A receipt is forgotten only when its part kind is selected, or that part is already absent from disk.
- Receipts and the outcome:
  - For a root part: `rm ... && /usr/sbin/pkgutil --forget <receipt>`, so a receipt survives a failed `rm`.
  - For Trash parts and absent parts: `pkgutil --forget` runs on its own. If the later Trash step fails, a stray receipt is left. That's harmless, documented and accepted.
  - The script ends with `; true`, so a `--forget` on an already-gone receipt doesn't turn a successful run into `failed`. Only `-128` and launch errors decide the outcome. Verification decides the rest.
- `protocol PrivilegedRunner: Sendable { func run(removing paths: [String], forgetting receipts: [String]) async -> PrivilegedOutcome }` with `enum PrivilegedOutcome { case finished, cancelled, failed(String) }`.
  - Live: `/usr/bin/osascript -e <script> <parent, name, receipt-or-empty triples...> receipts: <receipts...>`. Parent and name are split in Swift (canonical parent). The `receipts:` marker has no leading dash (getopt) and can't equal a parent, which is always absolute. Keep it in argv and never interpolate.
  - The script runs `on run argv` and builds the pinned `cd -P … && rm` line per path (each value passed through `quoted form of`, each removal in its own subshell) plus the `--forget` parts. A builder handler returns `cmd`. Production ends with `do shell script cmd with administrator privileges`; a test variant ends with `return cmd`.
  - Exit status 0 is `finished`; stderr containing `-128` is `cancelled`; anything else is `failed`.
  - Paths containing NUL or newline are refused before this point.
- Removal flow in `NeuralDSPRemover.remove(_ selection: [PluginSelection]) async -> PluginRemovalResult`, where the result is `.cancelled` or `.finished(RemovalReport, [RemovalPolicy: [RemovedItem]])` (the same tuple `JunkModel.run` returns and `ReportSheet.removedByPolicy` expects):
  1. Re-validate; refused parts become skipped `.outsideRoots`. Skip the whole plugin (every part, `.inUse`) when its standalone app is running, comparing canonical paths of `RunningApp.bundleURL` and the app part.
  2. Split into `trashable` (deep check) and `root`.
  3. If `root` or receipts are non-empty, run the privileged step.
     - `cancelled`: return `.cancelled` before any Trash call. No report is shown; the model goes back to the list with the selection kept.
     - `failed` (wrong password, launch error): skip the Trash step as well. Survivors are reported as `.adminStepFailed`.
  4. Trash the `trashable` parts through `Remover(roots: RemovalRoots(roots: <canonical plugin roots>), trasher:)` with `.trash`. That reuses canonicalization, the root-owned skip and the `SkipReason` mapping.
  5. `lstat` every root-step path. Gone means removed under `.delete`; still there means skipped `.adminStepFailed`. Trash results come from `Remover`'s report. Then run `pkgutil --pkgs` again and log receipts that weren't forgotten (not in the report; the rescan shows them).
- New `SkipReason.adminStepFailed` with an en and ru title and hint ("Removing with administrator rights failed", "Try again; check the administrator password").
- `ReportContext.plugins` (policy `.delete` with the per-policy split) gets its own titles: "Plugins removed", "Plugins partly removed", "Removing plugins stopped", "Plugin removal failed".

## What Goes Where
- **Implementation Steps**: SiftCore scanner/remover, app model/view, strings, docs, tests.
- **Post-Completion**: manual run with a real password prompt on the user's Mac.

## Implementation Steps

### Task 1: Neural DSP locations, part model and deep writability

**Files:**
- Create: `Sources/SiftCore/NeuralDSP/NeuralDSPLocations.swift`
- Create: `Tests/SiftCoreTests/NeuralDSPLocationsTests.swift`
- Modify: `Sources/SiftCore/FS/Writability.swift`
- Modify: `Tests/SiftCoreTests/WritabilityTests.swift`

- [x] `Writability.canTrashDeep(_:)`: `canRemove(.trash)` plus every directory inside writable and searchable (fts, `FTS_PHYSICAL`), owned entries in sticky directories
- [x] write tests for `canTrashDeep`: user tree passes; a 777 folder with a 0555 subfolder fails; a sticky dir with a foreign-owned entry fails (if a fixture can produce one, else documented); symlinks inside are not followed
- [x] `PluginPartKind` with root (from `SiftPaths`), extension and receipt suffix per kind; `canonicalRoot(paths)` returns nil when the root is a symlink or its canonical path differs from the standardized one
- [x] `PluginPart`, `NeuralDSPPlugin` (`totalSize`, `hasPluginBundles`)
- [x] `NeuralDSPLocations.partName(of:kind:)` and `receiptPattern(for:)`
- [x] write tests: roots under a `SiftPaths(root:)` fixture, names stripped per kind, wrong extension rejected, a symlinked kind root gives nil
- [x] write tests: receipt pattern matches all seven suffixes, rejects other vendors, other plugin names and prefixes (`ArchetypeNollyXII...`)
- [x] run tests - must pass before next task

### Task 2: NeuralDSPScanner

**Files:**
- Create: `Sources/SiftCore/NeuralDSP/NeuralDSPScanner.swift`
- Create: `Tests/SiftCoreTests/NeuralDSPScannerTests.swift`

- [x] list each root (missing roots give nothing), build parts, group by name, sort plugins by size
- [x] size parts with `DirectorySizer`; ignore symlinks and anything that isn't a real directory
- [x] set `containsUserPresets` and `needsAdmin` (deep check, Task 1); attach receipts from `pkgutil --pkgs` through `CommandRunner` (failure gives no receipts)
- [x] write tests: full plugin across all eight roots plus receipts; leftovers-only plugin (manual + settings); two plugins not mixed
- [x] write tests: wrong extensions, hidden entries, files in directory roots and symlinks are ignored; user presets detected; `needsAdmin` for a 777 folder with a 0555 subfolder; pkgutil failure
- [x] run tests - must pass before next task

### Task 3: Privileged runner (osascript)

**Files:**
- Create: `Sources/SiftCore/NeuralDSP/PrivilegedRunner.swift`
- Create: `Tests/SiftCoreTests/PrivilegedRunnerTests.swift`

- [x] `PrivilegedRunner` protocol, `PrivilegedOutcome`, `OSAScriptPrivilegedRunner(runner: CommandRunner)`
- [x] AppleScript source: a builder handler (pinned `cd -P … && rm -rf -- <name>` per path, `&& pkgutil --forget` for root-part receipts, plain `--forget` for the others, trailing `; true`) plus a production tail (`do shell script … with administrator privileges`) and a test tail (`return cmd`)
- [x] argv is paths, then `--receipts`, then receipt IDs; map the outcome from status and stderr (`-128` is cancelled)
- [x] write tests with `FakeCommandRunner`: exact argv for paths with spaces, quotes, `$`, `;`; nothing interpolated into the script source
- [x] write tests that run the real `/usr/bin/osascript` with the test tail on hostile names (`'`, `"`, `$()`, `;`, backtick, spaces, a name starting with `-`), then run the returned command with `/bin/sh` inside a `Fixture` tree without root: exactly the intended entries are gone and decoy siblings remain
- [x] write tests: status 0 is finished, `-128` is cancelled, other failure is failed, launch failure is failed
- [x] run tests - must pass before next task

### Task 4: NeuralDSPRemover

**Files:**
- Create: `Sources/SiftCore/NeuralDSP/NeuralDSPRemover.swift`
- Create: `Tests/SiftCoreTests/NeuralDSPRemoverTests.swift`

- [x] `PluginSelection` (plugin name and selected parts), `PluginRemovalResult` (`.cancelled` / `.finished(report, byPolicy)`); `SkipReason.adminStepFailed` (+ en/ru title and hint)
- [x] validation: canonical path, direct child of the kind's canonical root (nil root refuses), matching extension, not a root, symlinks refused
- [x] split trash and root by `Writability.canTrashDeep`; receipts for selected or already-absent parts only
- [x] privileged step first: `cancelled` returns before any Trash call, `failed` skips the Trash step; Trash step through `Remover` with plugin roots; lstat verification of root paths; `pkgutil --pkgs` re-check logged
- [x] skip the whole plugin (`.inUse`) when its standalone app is running (canonical path compare)
- [x] the fake `PrivilegedRunner` really deletes the given paths in the temp tree, so verification is exercised
- [x] write tests: trash-only selection never calls the privileged runner; mixed selection calls it once with exactly the root paths and matching receipts; a user-owned settings folder goes to the Trash; a part under a 0555 parent goes to root; a 777 folder with a 0555 subfolder goes to root
- [x] write tests: cancel means no Trash calls and `.cancelled`; failure means no Trash calls and survivors `.adminStepFailed`; outside, nested, root, wrong-extension and symlink paths are refused; a symlinked kind root refuses its parts; running app skips every part of that plugin; an absent part's receipt is forgotten and an unselected present part's receipt is kept; only selected parts are touched
- [x] run tests - must pass before next task

### Task 5: PluginsModel

**Files:**
- Create: `Sources/DiskSift/Plugins/PluginsModel.swift`
- Create: `Tests/DiskSiftTests/PluginsModelTests.swift`

- [x] phases idle, scanning, ready, removing, report; scan through a protocol seam
- [x] selection: nothing checked by default; checking a plugin checks its parts except presets with user presets; tri-state per plugin; selected total
- [x] remove: confirmation, run remover off the main actor; `.cancelled` goes back to ready with the selection kept; `.finished` keeps the report and policy split; rescan after closing the report
- [x] write tests: default selection, plugin check skips user presets, part toggles and tri-state, totals
- [x] write tests: removal passes only the selection; cancel returns to ready with the same selection and no report; rescan after the report
- [x] run tests - must pass before next task

### Task 6: PluginsView, sidebar and report context

**Files:**
- Create: `Sources/DiskSift/Plugins/PluginsView.swift`
- Modify: `Sources/DiskSift/ContentView.swift`
- Modify: `Sources/DiskSift/Shared/ReportOutcome.swift` (`ReportContext.plugins`, `SkipReason.adminStepFailed` title/hint keys)
- Modify: `Resources/en.lproj/Localizable.strings`, `Resources/ru.lproj/Localizable.strings`
- Modify: `Tests/DiskSiftTests/ReportOutcomeTests.swift`

- [x] `Section.plugins` ("Plugins", `pianokeys`) and `ShellModel.plugins`
- [x] view: empty state with Scan; plugin rows (checkbox, name, part badges or "Leftovers: ...", size) expanding to part rows (checkbox, path, size, "Needs administrator password", "Contains your presets"); footer with Selected and "Remove…"
- [x] confirmation dialog text (permanent for root parts after the password, the Trash for the rest, quit your DAW first); `ReportSheet` with `.plugins` and `removedByPolicy`
- [x] `ReportContext.plugins` titles; `.adminStepFailed` title and hint; en and ru strings (parity test)
- [x] write tests: `ReportContext.plugins` titles and policy; `.adminStepFailed` keys; the strings parity test passes
- [x] run tests - must pass before next task

➕ **Found while probing the real install**: the AU/VST/VST3/AAX folders are shared by every vendor, so the first scan listed Kontakt, Ozone and Apple's `AppleAES3Audio` as "plugins". Bundle kinds now count only with a `CFBundleIdentifier` starting with `com.neuraldsp.` (Neural DSP writes `com.NeuralDSP.`), checked in both the scanner and the remover's validation, with tests for foreign bundles.
➕ `SkipReason.adminStepFailed` strings landed with Task 4 (the exhaustive switch needed them), not Task 6.

### Task 7: Verify acceptance criteria
- [x] only selected plugins and parts are removed; the shared `Neural DSP` folders stay
- [x] cancelling the password prompt removes nothing
- [x] the general `Remover` root rule is unchanged (existing tests untouched and passing)
- [x] run full test suite: `make test`
- [x] run linter: `make lint`

### Task 8: [Final] Update documentation
- [x] README: Plugins section (what is removed, the password prompt, user presets)
- [x] CLAUDE.md: layout (`NeuralDSP`, `Plugins`), the narrow root exception (only `NeuralDSPRemover`, validated paths, osascript argv, pinned `cd -P` parent, symlinks refused, the accepted remaining risk)
- [x] remove `docs/backlog/remove-selected-neural-dsp-plugins.md` if present on main
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- remove the Archetype Gojira X leftovers (manual and receipts; it has no settings folder): its manual folder is 775 `root:admin`, so for an admin user it goes to the Trash, and the password prompt is only for the receipts; `pkgutil --pkgs | grep GojiraX` is empty afterwards
- remove the Archetype Rabea X leftovers: manual, settings (to the Trash) and receipts
- cancel the password prompt on another plugin: nothing changes and the selection stays
- remove one installed plugin with presets that contain `User` presets left unchecked: the DAW no longer lists it, the user presets folder remains
