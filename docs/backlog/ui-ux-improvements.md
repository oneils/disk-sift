---
worth: yes
where: Sources/DiskSift
added: 2026-11-22
---
# UI/UX improvements

Agreed direction after reviewing the running app and view code: keep the native, focused macOS interface; improve clarity, feedback, and confidence before adding visual decoration. This is a backlog, not a record of implemented changes.

## P1 — Clear starting states and feedback

### Junk: initial state and scan results

- Before the first scan, show a centered symbol, a short explanation of the scan scope, and a prominent “Start scan” button instead of zero-size result rows.
- Describe only supported locations: user caches/logs and selected developer caches (Xcode, npm, Go, Homebrew, etc.). Do not promise a system-wide cache scan.
- Distinguish not scanned, scanning, stopped/partial, no findings, results, and deletion states. Unscanned or inaccessible locations must not appear as verified zero-size results.
- After scanning, show category totals, selected size, and a clear next action. Keep rescan available without competing with the primary action.

Acceptance: a first-time user can tell whether a scan has run, what it covers, and what to do next; cancellation and incomplete coverage are visible.

### Uninstall: choose an application

- Add “Choose application…” using a native file picker alongside drag and drop.
- Route both entry methods through the same validation and running-app handling; retain current allowed-location restrictions.
- Provide useful validation errors and keep a straightforward way to choose another application.

Acceptance: the complete selection flow works without Finder drag and drop, including keyboard use and picker cancellation.

### Removal progress and stopping

Completed: [removal progress and stopping](no-progress-while-deleting.md), including truthful per-item progress, stopping between items, and a partial report. Further report polish remains in P2.

## P2 — Understandable results and decisions

### Uninstall summary and grouping

- Show the application's native icon, name, optional version, application size, related-file size, and selected total without double counting.
- Put Bundle ID and Team ID in optional details, not the primary header.
- Use readable group names such as Application Support, Caches, Logs, and Login Services. Keep exact paths available as secondary text or details; abbreviate the home directory with `~` where appropriate.
- Explain confidence with evidence and consequences, rather than only “High / Medium / Low”. Make shared data and uncertain matches explicit; preserve conservative default selection.

Acceptance: users can identify the app, understand why files were matched, and distinguish shared data before choosing what to remove.

### Inspect and compare findings

- Add “Show in Finder” to result context menus, with a clear response if an item no longer exists.
- Provide full paths on demand and sorting by size for comparable siblings/categories without breaking the tree or changing selection.
- Explain consequences by category: caches will be recreated and initial launches may be slower; Xcode archives can contain valuable debugging data.
- Consider Quick Look for supported files after Finder reveal is implemented; do not treat preview as necessary for every cache directory.

Acceptance: a user can inspect a finding and understand its purpose without leaving the workflow to manually reconstruct its path.

### Accurate completion reports

- Emphasize the amount processed and distinguish complete success, partial success, stopped operations, and failure.
- Cleanup wording: “Deleted files totaling …”; uninstall wording: “Moved to Trash: …”. Never claim that the same amount of disk space has been freed.
- Give skipped/failed items readable reasons and useful next steps, with full paths available.
- Use a success symbol only for full success; keep animation optional and respect reduced-motion preferences.

Acceptance: reports accurately describe the operation and its partial outcomes, including the difference between deletion and moving to Trash.

## P2 — Accessibility, layout, and localization

- Prefer native tri-state checkbox behavior; if a custom control remains, expose an accessible name, role, and on/off/mixed value. Check mixed state at category level as well as nested rows.
- Verify keyboard focus, visible focus indication, Space activation, and VoiceOver announcements. Current category accessibility descriptions emphasize size instead of the category name.
- Add clear section titles, consistent spacing, aligned size columns, and restrained category symbols. Use one primary accent and pair warning colors with explanatory text.
- Evaluate an initial window size around 900 × 620 while retaining resizing and usable minimum dimensions.
- Verify EN/RU layouts with long names and paths, narrow windows, light/dark appearance, and increased contrast. Existing localization support is not proof that all layouts fit.

Acceptance: both workflows are usable by keyboard and VoiceOver; labels and key actions remain legible across the tested layouts and appearances.

## P3 — Space visualization

- After readable totals and size sorting, add one segmented bar showing the distribution of scanned findings with a legend and exact values.
- Clearly label the denominator: this is found data, not the entire disk or guaranteed reclaimable space. Indicate incomplete scans and distinguish found totals from selected totals.
- Avoid double counting nested folders and children. Do not rely on color alone.
- Consider proportional bars for top-level categories only if they improve comparison; avoid adding them to every nested row.

Acceptance: users can quickly identify the largest categories, and chart totals agree with the list for the same scan scope.

## Suggested implementation order

1. Initial states and application picker.
2. Removal feedback, stopping, and accurate partial reports.
3. App summary, readable grouping, explanations, and Finder reveal.
4. Accessibility and layout verification (also required for each new control).
5. Space distribution visualization and optional visual polish.
