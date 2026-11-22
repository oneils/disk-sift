---
worth: yes
where: Sources/DiskSift/Junk/JunkModel.swift
added: 2026-11-22
status: completed
---
# Removal progress and stopping

Original problem: `JunkModel.delete` ran `Remover.remove(items, policy: .delete)` as one detached call and only updated the UI when the whole batch is done. Deleting tens of GB (Go module cache, npm cache, DerivedData) takes a while, and the window shows nothing until the report appears. Same for the uninstall path (`Uninstaller.uninstall`, `Sources/SiftCore/Removal/Uninstaller.swift:15`), though trashing is usually fast.

Wanted: per-item progress (current item, completed/total items, size of successfully processed items) and a Stop button between items. `Remover.remove` is synchronous over the whole list (`Sources/SiftCore/Removal/Remover.swift:14`), so it needs a per-item callback or an `AsyncStream` like `JunkScanner`'s progress. Raised by the user after the first manual run.

Priority: P1. Part of the [UI/UX improvements](ui-ux-improvements.md).

## Acceptance criteria

- Both cleanup and uninstall show an explicit busy state and the current item while removal runs; conflicting actions are disabled.
- Show completed/total items and an activity indicator. Use determinate byte progress only if the removal implementation provides reliable measurements; do not simulate progress inside a single directory removal.
- Label processed bytes as the size of deleted or trashed items, never as measured free space gained. APFS snapshots/clones and moving items to Trash make those different quantities.
- Offer “Stop after current item”: stop scheduling further items, allow the current operation to finish, and show a partial report. Stopping does not undo completed removals.
- Preserve uninstall ordering and safety: leftovers are not removed if the app itself was not successfully trashed. Distinguish unprocessed items after stopping from failures.
- Verify progress, stopping, partial failures, and uninstall ordering with focused tests when implementing.

## Implemented

- Awaited per-item callbacks update both views in order, without blocking the main actor or allowing delayed updates to overwrite a completed report.
- Both workflows show the current item, completed/total count, and processed size. The app bundle is sized before uninstall; displayed sizes describe processed items, not free space gained.
- “Stop after current item” switches to a disabled stopping state. Reports list unprocessed items separately from failures and explain that completed operations are not undone.
- Cancellation is checked before launch-agent operations and between removals. A cancellation during the final item still reports completion if nothing remains.
- Tests cover progress, partial failures, early cancellation, stopping after the app and during leftovers, app-size accounting, and model state/duplicate-action guards.
