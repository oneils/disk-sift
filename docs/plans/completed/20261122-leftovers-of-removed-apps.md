# Leftovers of removed apps

## Overview
- Find what apps that are no longer installed left in the user's Library: preferences, caches, Application Support, containers, saved state, logs, web data, and launch agents whose program is gone.
- Today DiskSift only finds leftovers for an app the user drops in. Apps removed by dragging to the Trash leave everything behind, and nothing finds it.
- Lives in the Uninstall tab as a second entry point: a secondary button on the start screen opens a separate "leftovers" flow. Detection is conservative, nothing is preselected, and removal goes to the Trash through the existing `RemovalRoots.make`, so no new safety scope is needed.
- One PR.

## Context (from discovery)
- Matching and scan locations: `Sources/SiftCore/Leftovers/ScanLocations.swift` (`userLibrarySubdirs`, `launchDirs`, `groupContainersDir`), `LibraryPathsSource.swift` (name stripping, `knownExtensions`), `LaunchItemsSource.swift` (plist `Label`/`Program`/`ProgramArguments`), `LocationKind.swift`.
- App facts: `Sources/SiftCore/App/AppInfo.swift` (`nestedDirs`, nested bundle IDs).
- System lookups: `Sources/SiftCore/SystemLookups.swift` (`InstalledApps`, `RunningApps`), live versions in `Sources/DiskSift/SystemLookupsLive.swift`; `CommandRunner` for `launchctl` (as in `Uninstaller`).
- Removal: `Remover(roots: .make(paths))` with `.trash`; `Uninstaller` already runs `launchctl bootout gui/<uid>/<label>` for user agents.
- UI to reuse: `UninstallView` (`GroupHeader`, `FindingRow`, `evidenceKeys`, `LocationKind.titleKey`), `Shared/Components.swift` (`TriStateCheckBox`, `SizeText`, `RevealMenu`, `EmptyStateView`, `ReportSheet`), `ReportOutcome.swift` (`ReportContext`).
- Conventions (CLAUDE.md): Swift 6.1 / macOS 14, no SwiftUI macros (`@Observable` models), injected `SiftPaths`, real temp trees in tests, system calls behind fakes, en + ru strings with parity test, `make test`, `make lint`.

## Development Approach
- **testing approach**: Regular (code first, then tests)
- complete each task fully before moving to the next; small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task (success and error cases)
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run `make test` after each change, `make lint` before committing
- do not change `RemovalRoots` / `Remover` rules; uninstall, junk and large files behave as before

## Testing Strategy
- **unit tests**: Swift Testing, real temp trees via `Fixture` / `SiftPaths(root:)`, fakes for Launch Services, installed apps, running apps and `CommandRunner`.
- no UI e2e suite; UI is verified manually (Post-Completion).

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview
- **Reverse scan by bundle ID (conservative).** Read names in the user Library scan dirs, turn each into a candidate bundle ID, and keep only candidates no installed or running app owns. No confidence tiers: everything found is shown unselected with its evidence.
- **Ownership is generous, so detection stays conservative.** Any of these makes a candidate "alive": Launch Services knows an app with the ID outside the Trash; it equals, extends or is an ancestor of an installed bundle ID (apps and every bundle nested in them); a running process has it; a live launch agent (program still exists) has it as label.
- **Scope kept small.** Only `~/Library` (items in `/Library` are root-owned and can't be removed anyway). Group Containers are skipped: they hold data shared by a developer's apps, and deciding they're orphaned needs all of that developer's apps. Launch agents are handled by program path, not by name.
- **Separate flow and model.** `OrphansModel` sits next to `UninstallModel` (owned by `ShellModel`), so the uninstall flow doesn't grow a second state machine. `UninstallView` switches flows.

## Technical Details

**Candidate extraction** (`OrphanScanner.candidateID(fromName:inByHost:) -> String?`):
- strip `.plist`, `.savedState`, `.binarycookies` (same list as `LibraryPathsSource.knownExtensions`)
- in `Preferences/ByHost`, also strip a trailing hardware-UUID component (`com.foo.app.<UUID>` → `com.foo.app`; the UUID matches `[0-9A-F]{8}-[0-9A-F]{4}-...` or a 12-hex legacy MAC form)
- must have ≥ 3 dot-separated components, each non-empty, characters `[A-Za-z0-9-_]`
- not `com.apple.*` (case-insensitive)
- first component is not a Team ID (10 uppercase alphanumerics, e.g. `ABCDE12345.com.foo.shared`): that is app-group data, skipped for the same reason as Group Containers
- not in `OrphanScanner.excludedPrefixes`, a short documented list of shared vendor components and non-app owners (for example `com.microsoft.office`, `com.microsoft.shared`, `com.microsoft.autoupdate`, `com.adobe.`, `com.google.keystone`, `org.python.`). Matched as prefixes, case-insensitive.
- the `ByHost` folder itself (seen while listing `Preferences`) is never a candidate
- candidate IDs are lowercased; all comparisons and group IDs use the lowercase form (`com.Foo.App` and `com.foo.app` land in one group), the display keeps the first spelling seen

**Ownership**:
- Launch Services: add `func isKnownOutsideTrash(bundleID: String) -> Bool` to the existing `InstalledApps` protocol (`SystemLookups.swift`) rather than a new protocol. Live (`LiveInstalledApps`): `NSWorkspace.shared.urlsForApplications(withBundleIdentifier:)` contains a URL that is not inside `~/.Trash` or a `/.Trashes` folder. An app still sitting in the Trash must not count, or the main case (dragged to the Trash, not emptied) finds nothing. `FakeInstalledApps` gains a `knownOutsideTrash` set.
- installed bundle IDs: plain SiftCore function `InstalledBundleIDs.collect(paths:) -> Set<String>` (lowercased). For each `.app` in `paths.applications` / `paths.userApplications` (top level plus one subfolder level, like `/Applications/Utilities`), walk `Contents` recursively, depth-bounded (e.g. 6), symlinks not followed, and collect every `CFBundleIdentifier` from `Info.plist` / `Contents/Info.plist` of nested bundles (`.app`, `.appex`, `.xpc`, `.framework`, `.bundle`, `.systemextension`, `.plugin`, `.qlgenerator`, `.mdimporter`). This covers Sparkle and Electron helpers in `Frameworks`, system extensions, Quick Look and Spotlight plugins, and `.appex` inside `PlugIns`. `AppInfo` is left unchanged.
- running: `RunningApps.running()` bundle IDs
- live launch agents: labels of `~/Library/LaunchAgents` plists whose program still exists
- a candidate `c` is alive when `isKnownOutsideTrash(c)`, or there is an ID `i` (installed, running, or live agent label) with `c == i`, `c.hasPrefix(i + ".")` (extends it) or `i.hasPrefix(c + ".")` (ancestor of an installed ID, e.g. `com.foo.app` data shared with installed `com.foo.app.pro`); all lowercase
- Full Disk Access: `OrphanScanner` takes `hasFullDiskAccess: @Sendable (SiftPaths) -> Bool` (default `FullDiskAccess.isGranted`), like `LibraryPathsSource`, and skips `ScanLocations.protectedDirs` (Containers) without it, so the scan never triggers TCC prompts for other apps' containers

**Launch agents**: for each plist in `~/Library/LaunchAgents`, read `Label` and `Program` / `ProgramArguments[0]`. An orphan is a plist whose program path is inside `paths.applications` or `paths.userApplications` and no longer exists (`lstat` fails), **and** whose label passes the same ownership filter (an update may have renamed the binary inside a still-installed app). The program is missing, so `realpath` can't resolve it: resolve its nearest existing ancestor with `RemovalRoots.canonicalRoot` (internal to SiftCore) before the prefix check, otherwise temp roots (`/var` → `/private/var`) and symlinked folders break the comparison. Group ID = lowercased label. Evidence `.launchProgramMissing`. Unreadable plists are skipped and logged. Agents whose program exists contribute their label to the live set above.

**Grouping**: sort candidate IDs; each joins the group of its shortest orphan prefix (`com.foo.app.helper` → `com.foo.app` when both are orphans; otherwise its own group). A launch agent joins a group when its label equals or extends the group ID, else it forms its own group.

**Model types** (SiftCore):
- `MatchEvidence` gains `.appNotInstalled` and `.launchProgramMissing` (strongest first in `allCases` order after the existing ones; not `isShared`)
- `FindingSource` gains `.orphan(groupID: String)`; launch agents also keep `.launchItem(label:domain: .user)` so the removal can find labels to unload
- `public struct OrphanGroup: Identifiable, Equatable, Sendable { id: String (bundle ID); findings: [Finding]; totalSize: Int64 }`
- `OrphanScanner(paths:installed:runningApps:hasFullDiskAccess:)`, `func scan() async throws -> [OrphanGroup]`; findings are sized in the scanner with `DirectorySizer` (like `LeftoverScanner`), cancellable (`Task.checkCancellation` between dirs and items); `requiresRoot` via `Writability.canRemove(_, .trash)`
- `OrphanRemover` (SiftCore): unloads user agents then trashes. Extract the existing label collection + `launchctl bootout gui/<uid>/<label>` loop from `Uninstaller.swift` into a shared internal helper (`LaunchAgentUnloader`) used by both `Uninstaller` (behavior and tests unchanged) and `OrphanRemover`; then `Remover(roots: .make(paths)).remove(_, policy: .trash, onProgress:)`. Tested in `SiftCoreTests` with `FakeCommandRunner`.

**OrphansModel** (`Sources/DiskSift/Uninstall/OrphansModel.swift`):
- protocol seams like `UninstallModel`: `OrphanScanning` (`scan() async throws -> [OrphanGroup]`) and `OrphanRemoving` (`remove(_:onProgress:) async -> RemovalReport`), with `extension OrphanScanner: OrphanScanning`, `extension OrphanRemover: OrphanRemoving`; `static func live(paths:)`; tested with private fakes in `DiskSiftTests` (they can't see `SiftCoreTests` fakes)
- phases `idle / scanning / results / removing / report(RemovalReport)`; `groups`; `checked: Set<String>` (empty by default); `requiresRoot` findings are shown but not selectable (as in uninstall); `sort: ResultSort` (groups by total size or ID); group tri-state (`.on / .mixed / .off`, ignoring root-only findings) and set-group
- `remove()`: `remover.remove(selected, onProgress:)` on a detached task; stop after current item; prune removed findings and empty groups; `report`
- reveal + `missingItem`; `fdaGranted` passed in for the empty-state note

**UI**:
- `UninstallView` chooser gets a secondary button "Find Leftovers of Removed Apps…" (bordered, under "Choose Application…"). `ShellModel` holds `orphans` (`init(..., orphans: OrphansModel = .live())` in `ContentView.swift`). While `orphans.phase != .idle`, the Uninstall detail shows `OrphansView` with a Back button that resets it to idle.
- `OrphansView`: scanning progress + Stop; results header (count/total, sort, Scan Again, Back); a `List` with a `Section` per group (header: `TriStateCheckBox`, ID, item count, `SizeText` total), rows (checkbox, name, `LocationKind` title, `~` path, evidence text, `SizeText`, `RevealMenu`); footer "Selected: X" + "Move to Trash"; empty state "No leftovers of removed apps found." (+ "Containers were not checked without Full Disk Access." when not granted); `ReportSheet(context: .leftovers)`.
- `ReportContext.leftovers` titles: "Leftovers moved to Trash" / "Some leftovers moved to Trash" / "Moving leftovers to Trash stopped" / "Leftovers were not moved to Trash".

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests, README/CLAUDE.md in this repo.
- **Post-Completion** (no checkboxes): manual checks on a real Mac.

## Implementation Steps

### Task 1: Candidate extraction and exclusions

**Files:**
- Create: `Sources/SiftCore/Leftovers/OrphanScanner.swift`
- Create: `Tests/SiftCoreTests/OrphanScannerTests.swift`

- [x] add `OrphanScanner.candidateID(fromName:inByHost:)` with extension stripping, ByHost UUID stripping, shape check, lowercasing, `com.apple`, Team-ID-prefix and `excludedPrefixes` filters
- [x] write tests: `com.foo.app.plist` → `com.foo.app`; `com.foo.app.savedState`; ByHost `com.foo.app.0A1B2C3D-....plist` and legacy MAC suffix; the `ByHost` folder name itself rejected; two-component and space/odd-character names rejected; `com.apple.*`, `ABCDE12345.com.foo.shared` and excluded prefixes rejected (case-insensitive); `com.Foo.App` → `com.foo.app`
- [x] run `make test` - must pass before task 2

### Task 2: Ownership lookups

**Files:**
- Modify: `Sources/SiftCore/SystemLookups.swift`
- Create: `Sources/SiftCore/Leftovers/InstalledBundleIDs.swift`
- Modify: `Sources/DiskSift/SystemLookupsLive.swift`
- Modify: `Tests/SiftCoreTests/Fakes.swift`
- Create: `Tests/SiftCoreTests/InstalledBundleIDsTests.swift`
- Modify: any other `InstalledApps` conformers / fakes (e.g. `Tests/DiskSiftTests`) so they compile

- [x] add `isKnownOutsideTrash(bundleID:)` to `InstalledApps`; live version ignores URLs inside `~/.Trash` and `/.Trashes`; extract the Trash check into a pure function so it is unit-testable
- [x] add `InstalledBundleIDs.collect(paths:)`: apps in Applications and user Applications (plus one subfolder level); recursive, depth-bounded walk of each `Contents`, symlinks not followed, every nested bundle's `CFBundleIdentifier`, lowercased; unreadable or broken bundles skipped
- [x] ➕ depth bound is 8 (Electron helpers sit ~5 levels into `Contents`); a symlinked `.app` at the Applications top level is followed and counted as installed (conservative), symlinks inside bundles are not
- [x] update `FakeInstalledApps` with a `knownOutsideTrash` set
- [x] write tests: apps at top level and in a subfolder; nested IDs from `Contents/Frameworks/X.framework/.../Helper.app`, `Contents/Library/SystemExtensions/x.systemextension`, `Contents/PlugIns/A.appex/Contents/PlugIns/B.appex` included, including IDs that don't extend the app's; app without a bundle ID or with a broken plist skipped; symlinked bundle not followed; missing folders give an empty set
- [x] write tests: Trash check: `~/.Trash/Foo.app` and `/Volumes/X/.Trashes/501/Foo.app` are in the Trash, `/Applications/Foo.app` is not
- [x] run `make test` - must pass before task 3

### Task 3: Library scan, launch agents and grouping

**Files:**
- Modify: `Sources/SiftCore/Leftovers/OrphanScanner.swift`
- Modify: `Sources/SiftCore/Model/Finding.swift`
- Modify: `Sources/DiskSift/Uninstall/UninstallView.swift` (`MatchEvidence.explanationKey` is an exhaustive switch; the app target must keep compiling)
- Modify: `Resources/en.lproj/Localizable.strings`, `Resources/ru.lproj/Localizable.strings` (the two evidence strings)
- Modify: `Tests/SiftCoreTests/OrphanScannerTests.swift`

- [x] add `MatchEvidence.appNotInstalled`, `.launchProgramMissing` with their `explanationKey` cases and en + ru strings, `FindingSource.orphan(groupID:)`, `OrphanGroup`
- [x] implement `scan()`: user Library subdirs (minus Group Containers, LaunchAgents, and Containers without FDA) → candidates → ownership filter (Launch Services outside Trash, installed/running/live-agent IDs with equal, extends and ancestor rules) → findings with `requiresRoot` via `Writability.canRemove(.trash)`; launch agents with missing programs inside the Applications folders whose label is not alive; grouping by shortest orphan prefix (lowercase); sizing; cancellation
- [x] write tests (temp tree + fakes): orphan prefs/caches/support/saved state of `com.gone.app` grouped together with `com.gone.app.helper` and differently cased `com.Gone.App`; installed app's and nested helper's data ignored (incl. a non-prefixed `.appex` container); extension of an installed ID ignored; ancestor of an installed ID (`com.foo.app` with `com.foo.app.pro` installed) ignored; ID known only as an app in the Trash **is** reported; Launch Services–known ID ignored; running ID ignored; a live agent's label protects its Application Support folder; `/Library` and Group Containers not scanned; Containers skipped without FDA and scanned with it
- [x] write tests: agent with missing program inside Applications → orphan with `.launchProgramMissing` and `.launchItem(label:, .user)`, also when the temp root goes through a symlink; agent whose program exists or is outside Applications → ignored; missing-program agent whose label belongs to an installed app → ignored; unreadable plist skipped; agent joins the matching group
- [x] write tests: every orphan finding is allowed by `RemovalRoots.make`; cancellation stops the scan
- [x] run `make test` - must pass before task 4

### Task 4: `OrphanRemover` and shared agent unloading

**Files:**
- Create: `Sources/SiftCore/Removal/LaunchAgentUnloader.swift`
- Create: `Sources/SiftCore/Removal/OrphanRemover.swift`
- Modify: `Sources/SiftCore/Removal/Uninstaller.swift`
- Create: `Tests/SiftCoreTests/OrphanRemoverTests.swift`

- [x] extract label collection + `launchctl bootout gui/<uid>/<label>` from `Uninstaller` into `LaunchAgentUnloader` (internal), keep `Uninstaller` behavior identical
- [x] add `OrphanRemover(remover:runner:uid:)`: unload labels of selected `.launchItem(_, .user)` findings (failures logged, not fatal; cancellation checked), then `.trash` removal with progress
- [x] write tests (`FakeCommandRunner`, fake trasher, temp tree): bootout runs once per label before any item is trashed; a failing bootout doesn't block removal; only `.trash` is used; stop before and during removal
- [x] existing `UninstallerTests` pass unchanged
- [x] run `make test` - must pass before task 5

### Task 5: `OrphansModel`

**Files:**
- Create: `Sources/DiskSift/Uninstall/OrphansModel.swift`
- Modify: `Sources/DiskSift/Shared/ReportOutcome.swift` (`ReportContext.leftovers`)
- Create: `Tests/DiskSiftTests/OrphansModelTests.swift`
- Modify: `Tests/DiskSiftTests/ReportOutcomeTests.swift`

- [x] implement `OrphanScanning` / `OrphanRemoving` seams and conformances, `live(paths:)`, phases, `groups`, empty default selection, root-only findings not selectable, per-finding and per-group selection with tri-state, `ResultSort` over groups, `selectedTotal`, reveal/`missingItem`, scan with stop
- [x] implement `remove()` through `OrphanRemoving` with progress, stop after current item, prune and report
- [x] add `ReportContext.leftovers` titles
- [x] write tests (private fakes): nothing selected after scan; root-only finding can't be selected and doesn't affect group tri-state; group tri-state on/mixed/off; sort keeps selection; only selected findings reach the remover
- [x] write tests: stop during scan and after the current item; report prunes removed findings and empty groups; missing item; `.leftovers` titles never say "Uninstall"
- [x] run `make test` - must pass before task 6

### Task 6: Orphans view and entry point in the Uninstall tab

**Files:**
- Create: `Sources/DiskSift/Uninstall/OrphansView.swift`
- Modify: `Sources/DiskSift/Uninstall/UninstallView.swift`
- Modify: `Sources/DiskSift/ContentView.swift`
- Modify: `Resources/en.lproj/Localizable.strings`, `Localizable.stringsdict`
- Modify: `Resources/ru.lproj/Localizable.strings`, `Localizable.stringsdict`

- [x] `ShellModel.orphans`; Uninstall detail shows `OrphansView` while `orphans.phase != .idle`
- [x] chooser: secondary "Find Leftovers of Removed Apps…" button
- [x] `OrphansView`: scanning header with Stop; results header (count/total, sort, Scan Again, Back); grouped list with tri-state group headers and finding rows; footer with Move to Trash; removal progress; empty state with the FDA note; `ReportSheet(context: .leftovers)`
- [x] all new en + ru strings; counts reuse the existing `%lld items` stringsdict entry (Russian one/few/many/other already there), so no new stringsdict keys were needed
- [x] ➕ checked the start screen and results by rendering them from a temporary demo tree (hook not committed)
- [x] run `make test` and `make lint` - must pass before task 7

### Task 7: Verify acceptance criteria
- [x] orphans are found only in `~/Library` (no `/Library`, no Group Containers, no Containers without FDA); installed (incl. deeply nested), ancestor, Launch Services–known (outside Trash), running and live-agent IDs are never reported; apps sitting in the Trash don't hide their leftovers
- [x] nothing is preselected, root-only items are not selectable; removal is Trash only via `RemovalRoots.make`; agents are unloaded first
- [x] run full test suite: `make test`
- [x] run `make lint`, `make app`, `make check-app`

### Task 8: [Final] Update documentation
- [x] README "What it does": leftovers of removed apps under the Uninstall section
- [x] CLAUDE.md layout if new files warrant it
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- on a real Mac: remove a test app by dragging it to the Trash, then find its leftovers and move them to the Trash, then Put Back
- review a real `~/Library` result list for false positives (CLI tools, updaters, runtimes, shared vendor components) and extend `excludedPrefixes` where needed
- drag a test app to the Trash without emptying it: its leftovers must be found
- with and without Full Disk Access (containers checked vs note shown)
- EN/RU layout, keyboard and VoiceOver on the new flow
