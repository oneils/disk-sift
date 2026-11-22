# Large files report and system junk

## Overview
- Add a **Large Files** tab: a flat list of files ≥ a threshold anywhere in the home folder, which can be moved to the Trash.
- Add three **system junk** categories to the Junk tab: installers, iOS device backups, Mail downloads.
- Both features reach outside today's removal roots (the Library folders), so they rest on a new, separate safety scope. Today's rules for uninstall and junk stay unchanged.
- Delivered as three PRs in order: safety foundation → Large Files tab → system junk.

## Context (from discovery)
- Removal safety: `Sources/SiftCore/Removal/RemovalRoots.swift` (`make(paths)`, `allows`), `Sources/SiftCore/Removal/Remover.swift` (re-validates every item before acting: canonical path, roots, `Writability`).
- Sizing/listing: `Sources/SiftCore/FS/DirectorySizer.swift` (allocated size, hard links once, symlinks not followed), `DirectoryChildren.swift`.
- Junk: `Sources/SiftCore/Junk/JunkCategory.swift` (protocol already has `policy`), `JunkScanner.swift` (AsyncStream progress, cancellation), `UserCachesCategory.swift`, `DevJunkCategory.swift`; app side `Sources/DiskSift/Junk/JunkModel.swift` (one `FindingRemoving`, always `.delete`), `JunkView.swift`.
- Shared UI from the UI/UX work: `Sources/DiskSift/Shared/Components.swift` (`TriStateCheckBox`, `SizeText`, `RevealMenu`, `EmptyStateView`, `ReportSheet`), `FileRevealing.swift` (`ResultSort`), `ReportOutcome.swift`.
- Shell: `Sources/DiskSift/ContentView.swift` (`Section` enum, `ShellModel`), `FDABanner.swift`.
- Conventions (CLAUDE.md): SwiftPM only; must compile with Swift 6.1 / macOS 14; no SwiftUI macros (state lives in `@Observable` models); every location from injected `SiftPaths`; tests use real temporary file trees, system calls behind fakes; en + ru strings with a key-parity test; `make test`, `make lint`.

## Development Approach
- **testing approach**: Regular (code first, then tests)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - write unit tests for new and modified functions/methods
  - cover success and error scenarios
  - update existing tests when behavior changes
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run `make test` after each change, `make lint` before each commit
- do not weaken existing `Remover` / `RemovalRoots` rules; uninstall and junk behavior stays as is except where this plan says otherwise

## Testing Strategy
- **unit tests**: required in every task, Swift Testing, real temp trees via `Fixture` (`Tests/SiftCoreTests/Fixture.swift`), `SiftPaths(root:)`.
- system lookups (Spotlight dates, running apps) go through small protocols with fakes, like `CommandRunner` / `SystemLookups`.
- no UI e2e suite in the project; UI is verified manually (see Post-Completion).

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- keep plan in sync with actual work done

## Solution Overview
- **Separate scope, single authority.** `RemovalRoots.make(paths)` keeps governing uninstall and junk. A new `RemovalRoots.largeFiles(paths)` allows paths strictly inside `~` minus a deny list and on the same volume as `~`. Files-only and Trash-only are properties of that scope itself, not caller flags: any `Remover` built on it refuses directories, symlinks and `.delete`, with no extra arguments to forget. Scanners use the same deny list to skip subtrees, but `Remover` remains the only place that decides what may be removed.
- **Large Files** is its own tab with its own scanner and model, reusing the shared components. It is not a Junk category: Junk means "safe to delete", large files are user data.
- **System junk** fits the existing `JunkCategory` protocol. `JunkModel` starts honoring per-category policy: the selection is split into a permanent-delete batch and a trash batch. Installers are trashed through the large-files scope, so `~/Downloads` and `~/Desktop` never become junk roots and nothing in them can be deleted permanently.
- Excluded on purpose: emptying the Trash, removing language files from app bundles (breaks code signatures).

## Technical Details

**Deny list (large-files scope)**, all relative to `paths.home`, case-insensitive like the rest of the code:
- `~/Library` (covers iCloud Drive `Mobile Documents` and `CloudStorage`), `~/.Trash`, `~/Applications`
- any path with a package ancestor: a directory with `isPackageKey` true or a known package extension. The explicit list matters because `isPackageKey` depends on Launch Services and stops working when the owning app is gone (a VM bundle would then expose its disk files): `app`, `photoslibrary`, `musiclibrary`, `fcpbundle`, `imovielibrary`, `tvlibrary`, `bundle`, `framework`, `pvm`, `vmwarevm`, `utm`, `sparsebundle`, `logicx`, `aplibrary`, `dtbase2`
- anything on another volume than `~` (`st_dev` differs): network shares, sshfs/SMB mounts, external disks or disk images mounted inside the home folder. Same convention as `FTS_XDEV` in `Remover.makeWritable`
- any path with a `.git` directory ancestor
- `home` itself is never allowed

**Scope kind in `RemovalRoots`**: `RemovalRoots` gains `kind: Kind` (`.library` for `make(paths)`, `.largeFiles(LargeFilesScope)` for `largeFiles(paths)`). `LargeFilesScope` is a Sendable value (canonical home, home `st_dev`, deny rules), so no closure is stored. `allows` dispatches on `kind`; `.library` behavior is byte-for-byte unchanged. The scope exposes `filesOnly == true` and `trashOnly == true`.

**Remover enforcement**: `Remover.removeOne` reads the rules from `roots`, with no init flag. For a files-only scope it requires `S_IFREG` after `lstat` (otherwise skip with new `SkipReason.notAFile`). For a trash-only scope, `remove(_:policy: .delete)` refuses up front: every item is skipped with new `SkipReason.policyNotAllowed`, nothing is touched.

**LargeFileScanner** (`Sources/SiftCore/LargeFiles/LargeFileScanner.swift`):
- `scan(minimumSize: Int64 = 100 MB) -> AsyncStream<LargeFileProgress>`
- events: `.found(LargeFile)`, `.progress(scanned: Int, directory: URL)` (throttled, e.g. every 500 entries), `.unreadable(URL)`, `.finished`
- `LargeFile { url, size (allocated), modified: Date }`; converted to `Finding` with new `FindingSource.largeFile` for `FindingRemoving` (never `.junk`)
- walk: `FileManager.enumerator(at: home, includingPropertiesForKeys: [.volumeIdentifierKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey], options: [.skipsPackageDescendants])`, `skipDescendants()` for denied directories and directories on another volume (`.volumeIdentifierKey` differs from home's), symlinks never followed, files counted once per `fileResourceIdentifier` (hard links), error handler records unreadable directories and continues.

**Last opened**: protocol `LastUsedLookup { func lastUsed(_ url: URL) -> Date? }`, live via `MDItemCreateWithURL` + `kMDItemLastUsedDate`; called only for found files. Injected into `LargeFilesModel` (not the scanner), which looks dates up off the main actor once per found file. Fallback is the modification date, labelled "Modified". DiskSiftTests define their own fake (they can't see `SiftCoreTests/Fakes.swift`).

**LargeFilesModel** (`Sources/DiskSift/LargeFiles/LargeFilesModel.swift`): phases `idle / scanning / ready / trashing / report(RemovalReport)`; `scanStopped`; `files` (≥ 100 MB), `threshold` (100 MB / 500 MB / 1 GB / 5 GB, default 500 MB) with `visibleFiles` filtering locally; `checked: Set<String>` (empty by default; hidden-by-threshold items are excluded from the selection); `sort: LargeFileSort` (`size / name / date`, local to this tab; `ResultSort` stays `size / name` so the Junk and Uninstall pickers don't get a meaningless "Date"); `unreadable: [URL]`; reveal + `missingItem`; trashing with progress and "stop after current item" like `JunkModel`.

**Report context (PR 2)**: `ReportOutcome.titleKey(policy:)` maps `.trash` to "Uninstall …", which is wrong for Large Files. Replace the policy argument with `ReportContext` (`.uninstall`, `.cleanup`, `.largeFiles`), each with en + ru titles for success/partial/stopped/failed. `ReportSheet` takes the context; amount lines still follow the policy. `SkipReason.outsideRoots.hintKey` becomes neutral ("DiskSift only removes items in locations it allows for this action."). Hints for the new `.notAFile` / `.policyNotAllowed` reasons are added.

**System junk categories** (`Sources/SiftCore/Junk/`):

| Category | Location | Policy | Default checked | Notes |
|---|---|---|---|---|
| `InstallersCategory` | regular files `*.dmg`, `*.pkg`, `*.mpkg`, `*.xip` directly in `~/Downloads`, `~/Desktop` | `.trash` via large-files scope | modification date older than 30 days | `now` injected for tests; not expandable |
| `IOSBackupsCategory` | children of `~/Library/Application Support/MobileSync/Backup` | `.trash` | no | display name + date from `Info.plist` (`Device Name`, `Last Backup Date`); not expandable; needs FDA |
| `MailDownloadsCategory` | children of `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` | `.delete` | yes, unless Mail (`com.apple.mail`) is running | needs FDA |

- `Finding` gets an optional `displayName: String?` (backup device name/date) used by the junk row instead of the last path component.
- `JunkCategory` gains `var expandable: Bool { get }` and `var removalScope: JunkRemovalScope { get }` (`.library` / `.largeFiles`), both with defaults via extension (`true`, `.library`). Only `InstallersCategory` uses `.largeFiles`.
- "No access": a category throws `JunkCategoryError.unreadable` from `scan` when its directory exists but can't be listed. `JunkScanner` maps it to `JunkProgress.categoryUnreadable(id:)` and does **not** emit `.categoryFinished` afterwards (or `JunkModel.apply` ignores `.categoryFinished` for a `.noAccess` row; pick one and test the ordering). `JunkModel.CategoryState` gains `.noAccess`, shown as "No access" instead of a size.
- `JunkSupport.finding` computes `requiresRoot` with the category's policy (`Writability.canRemove(url, policy: category.policy)`), so a backup that can't be trashed is not offered as removable.
- `JunkModel` takes two removers: `library` (`Remover(roots: .make(paths))`, called with `.delete` or `.trash`) and `largeFiles` (`Remover(roots: .largeFiles(paths))`, always `.trash`). The selection is grouped by the `.junk(categoryID:)` source in each `Finding` (child findings from `selection(of:)` already carry it) and routed by the owning category's `removalScope` and `policy`, never by special-casing a category ID; batches run in sequence (delete, then trash) with one combined progress and one combined `RemovalReport`; stop applies across batches. `Phase.deleting`, `delete()` and `requestDelete()` are renamed to `removing` / `remove()` / `requestRemove()` with neutral progress text ("Removing: …"), since part of the selection may go to the Trash.
- Report for junk: lines for "Deleted files totaling …" and "Moved to Trash: …" (each only when non-zero); `ReportOutcome` computed over the combined report; `ReportSheet` takes the per-policy totals instead of a single policy.
- Confirmation: "Delete %@ permanently and move %@ to the Trash?" / only-delete / only-trash variants.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests, README/CLAUDE.md updates in this repo.
- **Post-Completion** (no checkboxes): manual UI checks, TCC/FDA behavior on a real Mac.

## Implementation Steps

### PR 1: safety foundation

### Task 1: Large-files removal scope in `RemovalRoots`

**Files:**
- Modify: `Sources/SiftCore/Removal/RemovalRoots.swift`
- Create: `Sources/SiftCore/LargeFiles/LargeFilesScope.swift`
- Create: `Tests/SiftCoreTests/LargeFilesScopeTests.swift`

- [x] add `LargeFilesScope` (Sendable value: canonical home, home `st_dev`, deny rules incl. VM/library package extensions) with `isDenied(_ canonical: CanonicalPath) -> Bool` (includes the volume check) and `shouldSkip(directory:isPackage:volume:)` for the scanner
- [x] add `RemovalRoots.Kind` and `RemovalRoots.largeFiles(paths)` whose `allows` is: strictly inside canonical home, not home itself, not denied, same volume; expose `filesOnly` / `trashOnly`; keep `make(paths)` and its `allows` behavior unchanged
- [x] write tests: allowed file in `~/Downloads`, `~/Movies`, `~/.ollama`; denied `~/Library/...`, `~/.Trash/...`, `~/Applications/...`, file inside `X.app`, inside `Photos Library.photoslibrary`, inside `repo/.git/objects`; home itself; path outside home
- [x] write tests: case-insensitive matching; a symlinked directory inside home pointing to `~/Library` is resolved and refused; a file inside `VM.utm` is refused even without Launch Services knowing the type
- [x] write tests: different volume refused (unit test `isDenied` with an injected/foreign `st_dev`; a real mounted disk image is a Post-Completion check)
- [x] run `make test` - must pass before task 2

### Task 2: `Remover` enforces the scope's files-only and Trash-only rules

**Files:**
- Modify: `Sources/SiftCore/Removal/Remover.swift`
- Modify: `Sources/SiftCore/Model/Finding.swift`
- Modify: `Sources/DiskSift/Shared/ReportOutcome.swift`
- Modify: `Tests/SiftCoreTests/RemoverTests.swift`

- [x] `removeOne` reads `roots.filesOnly`: require `S_IFREG` after `lstat`, otherwise skip with new `SkipReason.notAFile`
- [x] `remove(_:policy:)` (sync and async) with `.delete` on a `trashOnly` scope skips every item with new `SkipReason.policyNotAllowed`, touching nothing
- [x] add `titleKey` / `hintKey` for `.notAFile` and `.policyNotAllowed` in `ReportOutcome.swift` with en + ru strings
- [x] write tests (real temp tree, fake trasher): `Remover(roots: .largeFiles(paths))` with no extra arguments trashes a file in `~/Downloads`, refuses a directory and denied paths with the right reasons, and refuses `.delete` for everything
- [x] write tests: a symlink in `~/Downloads` is skipped with `.notAFile` and its target is untouched; a hard link in `~/Downloads` to a file under `~/Library` is allowed and only the link is trashed (documented on purpose)
- [x] ➕ added `FindingSource.largeFile` here (needed by the tests), moved from Task 6
- [x] write tests: existing `Remover` tests unchanged and green (`.library` scope)
- [x] run `make test` - must pass before task 3

### Task 3: Document the new scope

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [x] add a Safety paragraph in `README.md`: the large-files scope, its deny list, files only, Trash only
- [x] note in `CLAUDE.md` Conventions that there are two removal scopes and which features use which
- [x] run `make test` and `make lint`

### PR 2: Large Files tab

### Task 4: `LargeFileScanner`

**Files:**
- Create: `Sources/SiftCore/LargeFiles/LargeFileScanner.swift`
- Create: `Tests/SiftCoreTests/LargeFileScannerTests.swift`

- [ ] implement the enumerator walk per Technical Details: min size, skip denied subtrees, package descendants and other volumes, no symlink following, hard links once, allocated size
- [ ] emit `.found`, throttled `.progress`, `.unreadable`, `.finished`; stop on task cancellation
- [ ] write tests: files above/below the minimum (use sparse-safe real files, e.g. `truncate` + write to allocate, or a small minimum for tests); files in denied dirs and inside packages not reported; symlink to a big file not reported; hard link reported once
- [ ] write tests: unreadable directory (chmod 000) reported via `.unreadable` and scan continues; cancellation ends the stream
- [ ] run `make test` - must pass before task 5

### Task 5: Last-used date lookup

**Files:**
- Create: `Sources/SiftCore/LargeFiles/LastUsedLookup.swift`
- Create: `Tests/SiftCoreTests/LastUsedLookupTests.swift`

- [ ] add `LastUsedLookup` protocol and `SpotlightLastUsedLookup` (`MDItemCreateWithURL`, `kMDItemLastUsedDate`)
- [ ] add a fake for tests in `Tests/SiftCoreTests/Fakes.swift`
- [ ] write tests: live lookup on a fresh temp file doesn't crash and returns a `Date` or nil (no assertion on which, indexing state varies); fake returns configured dates
- [ ] run `make test` - must pass before task 6

### Task 6: `LargeFilesModel`

**Files:**
- Create: `Sources/DiskSift/LargeFiles/LargeFilesModel.swift`
- Modify: `Sources/SiftCore/Model/Finding.swift` (`FindingSource.largeFile`)
- Modify: `Sources/DiskSift/Shared/ReportOutcome.swift`
- Modify: `Sources/DiskSift/Shared/Components.swift`
- Modify: `Sources/DiskSift/Uninstall/UninstallView.swift`
- Modify: `Sources/DiskSift/Junk/JunkView.swift`
- Create: `Tests/DiskSiftTests/LargeFilesModelTests.swift`
- Modify: `Tests/DiskSiftTests/ReportOutcomeTests.swift`

- [ ] implement phases, `files`, `threshold` + `visibleFiles`, `checked`, `sort: LargeFileSort`, `unreadable`, `scanStopped`, reveal/`missingItem`; inject `LastUsedLookup` and fill "Opened" dates off the main actor after each found file, falling back to modification date
- [ ] `LargeFile` → `Finding` with `FindingSource.largeFile` (case added in Task 2)
- [ ] introduce `ReportContext` (`.uninstall` / `.cleanup` / `.largeFiles`) in `ReportOutcome`/`ReportSheet`, update the two existing call sites (`UninstallView.swift`, `JunkView.swift`), neutral `outsideRoots` hint; en + ru strings
- [ ] implement trashing via injected `FindingRemoving` (live: `Remover(roots: .largeFiles(paths), filesOnly: true)`), progress, stop after current item, report; remove trashed files from the list
- [ ] write tests: start state; scan collects files; threshold filters without rescanning and hidden items leave the selection; nothing selected by default; sort keeps selection
- [ ] write tests: stop during scan marks results incomplete; trash passes only selected visible files with `.trash`; partial report removes only removed files; missing item on reveal; "Opened" uses the fake lookup and falls back to "Modified" when it returns nil
- [ ] write tests: `ReportContext.largeFiles` titles ("Large files moved to Trash" family, never "Uninstall"); existing uninstall/cleanup titles unchanged
- [ ] run `make test` - must pass before task 7

### Task 7: Large Files view and sidebar entry

**Files:**
- Create: `Sources/DiskSift/LargeFiles/LargeFilesView.swift`
- Modify: `Sources/DiskSift/ContentView.swift`
- Modify: `Resources/en.lproj/Localizable.strings`
- Modify: `Resources/ru.lproj/Localizable.strings`

- [ ] add `Section.largeFiles` with symbol, `ShellModel.largeFiles`, detail switch
- [ ] start screen (`EmptyStateView`): what is scanned, what is skipped, threshold picker, Start Scan; scanning header with count, current folder and Stop
- [ ] results: summary (found count/total at threshold, incomplete warning, unreadable folders note), threshold + sort pickers, rows (checkbox, `NSWorkspace` icon, name, `~` path, "Opened …"/"Modified …", `SizeText`), context menu, footer "Selected: X" + Move to Trash, trashing header, `ReportSheet`
- [ ] add en + ru strings (parity test covers keys)
- [ ] run `make test` and `make lint` - must pass before task 8

### PR 3: system junk

### Task 8: Category extensions in the Junk protocol and model state

**Files:**
- Modify: `Sources/SiftCore/Junk/JunkCategory.swift`
- Modify: `Sources/SiftCore/Junk/JunkScanner.swift`
- Modify: `Sources/SiftCore/Model/Finding.swift`
- Modify: `Sources/DiskSift/Junk/JunkModel.swift`
- Modify: `Tests/SiftCoreTests/JunkScannerTests.swift`
- Modify: `Tests/DiskSiftTests/JunkModelTests.swift`

- [ ] add `expandable` and `removalScope` with defaults, `Finding.displayName`, `JunkCategoryError.unreadable`, `JunkProgress.categoryUnreadable(id:)`; scanner maps the error and keeps `.noAccess` from being overwritten by `.categoryFinished`
- [ ] `JunkSupport.finding` takes the category policy for `requiresRoot`
- [ ] `JunkModel`: `CategoryState.noAccess`; `canExpand` honors the category; rows use `displayName` when present
- [ ] write tests: scanner emits `categoryUnreadable` and the stream still finishes; model shows `.noAccess` after the full event sequence (never `.done`, never a zero size); non-expandable category rows don't expand; `requiresRoot` follows the category policy
- [ ] run `make test` - must pass before task 9

### Task 9: `InstallersCategory`

**Files:**
- Create: `Sources/SiftCore/Junk/InstallersCategory.swift`
- Modify: `Sources/SiftCore/SiftPaths.swift` (add `downloads`, `desktop` if not derivable)
- Create: `Tests/SiftCoreTests/InstallersCategoryTests.swift`

- [ ] list regular files with installer extensions directly in Downloads/Desktop (no recursion, no directories, no symlinks), `policy: .trash`, not expandable, `checkedByDefault` = older than 30 days with injected `now`
- [ ] `removalScope: .largeFiles`; unreadable Downloads or Desktop (TCC denied) throws `JunkCategoryError.unreadable` → "No access"
- [ ] write tests: `.dmg`/`.pkg`/`.mpkg`/`.xip` found; nested and non-installer files ignored; a directory named `X.pkg` ignored; old vs fresh default selection; unreadable Downloads (chmod 000) → `.unreadable`
- [ ] run `make test` - must pass before task 10

### Task 10: `IOSBackupsCategory`

**Files:**
- Create: `Sources/SiftCore/Junk/IOSBackupsCategory.swift`
- Create: `Tests/SiftCoreTests/IOSBackupsCategoryTests.swift`

- [ ] one finding per backup dir, `displayName` from `Info.plist` (`Device Name` + `Last Backup Date`), fallback to the folder name; `policy: .trash`, unchecked, not expandable; `requiresRoot` computed for `.trash`; unreadable parent → `JunkCategoryError.unreadable`
- [ ] confirm `RemovalRoots.make` already allows `Application Support/MobileSync/Backup/<id>` (strictly inside `Application Support`); add a test
- [ ] write tests: backup with and without `Info.plist`, corrupt plist, missing Backup dir (no findings), unreadable dir
- [ ] run `make test` - must pass before task 11

### Task 11: `MailDownloadsCategory`

**Files:**
- Create: `Sources/SiftCore/Junk/MailDownloadsCategory.swift`
- Create: `Tests/SiftCoreTests/MailDownloadsCategoryTests.swift`

- [ ] children of Mail Downloads, `policy: .delete`, checked unless `com.apple.mail` is in `running`; unreadable container → `categoryUnreadable`
- [ ] write tests: findings listed; default checked off when Mail runs; missing dir gives no findings
- [ ] run `make test` - must pass before task 12

### Task 12: Mixed-policy removal in `JunkModel`

**Files:**
- Modify: `Sources/DiskSift/Junk/JunkModel.swift`
- Modify: `Tests/DiskSiftTests/JunkModelTests.swift`

- [ ] inject two removers (`library`, `largeFiles`); group `selectedFindings` by the `.junk(categoryID:)` source and route by the category's `removalScope` + `policy`; run batches in sequence with combined progress, stop across batches, one combined report
- [ ] rename `Phase.deleting` / `delete()` / `requestDelete()` to `removing` / `remove()` / `requestRemove()` and update `JunkView` and tests
- [ ] expose `selectedDeleteTotal` / `selectedTrashTotal` for the confirmation dialog
- [ ] register the new categories in `JunkModel.live`
- [ ] write tests: each batch goes to the right remover with the right policy; installers never reach the delete remover; combined report and progress; stop during the first batch leaves the second unprocessed
- [ ] run `make test` - must pass before task 13

### Task 13: Junk UI for new categories and combined reports

**Files:**
- Modify: `Sources/DiskSift/Junk/JunkView.swift`
- Modify: `Sources/DiskSift/Shared/Components.swift`
- Modify: `Sources/DiskSift/Shared/ReportOutcome.swift`
- Modify: `Sources/DiskSift/Uninstall/UninstallView.swift` (`ReportSheet(` call site)
- Modify: `Resources/en.lproj/Localizable.strings`
- Modify: `Resources/ru.lproj/Localizable.strings`
- Modify: `Tests/DiskSiftTests/ReportOutcomeTests.swift`

- [ ] start screen lists the new locations; category symbols and notes (installers: moved to Trash; backups: may be the only copy of a device; Mail: re-downloaded on demand); "No access" state
- [ ] confirmation dialog variants (delete only / trash only / both); `ReportSheet` (context from PR 2) adds per-policy amount lines from the combined report; outcome over the whole operation; neutral "Removing: …" progress text
- [ ] add en + ru strings
- [ ] write tests: `ReportOutcome` and per-policy totals for a mixed report
- [ ] run `make test` and `make lint` - must pass before task 14

### Task 14: Verify acceptance criteria
- [ ] large-files scope refuses everything in the deny list, other volumes, directories, symlinks and `.delete`, with no caller flags; uninstall/junk scope unchanged (existing tests green)
- [ ] Large Files tab: threshold filters instantly, nothing preselected, stop/partial states, Trash only
- [ ] Junk: three new categories with the agreed defaults; installers only ever trashed; "No access" instead of 0 KB
- [ ] run full test suite: `make test`
- [ ] run `make lint`, `make app`, `make check-app`

### Task 15: [Final] Update documentation
- [ ] update `README.md` "What it does" (Large Files, new junk categories) and "Not in v1" (drop what shipped)
- [ ] update `CLAUDE.md` Layout with `LargeFiles` in SiftCore and DiskSift
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- run a Large Files scan on a real home folder: duration, progress, Stop, threshold switching, "Opened"/"Modified" dates, Show in Finder, Move to Trash and Put Back
- without Full Disk Access: TCC prompts for Desktop/Documents/Downloads from both the Large Files scan and the Junk scan (installers category); unreadable folders reported as not scanned; installers, iOS backups and Mail downloads show "No access" when denied
- mount a disk image and an SMB share inside `~`: not scanned, not removable
- with an iPhone backup present: readable device name/date, nothing preselected, moved to Trash
- EN/RU layouts, keyboard and VoiceOver on the new tab and rows
