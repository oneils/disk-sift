---
worth: yes
added: 2026-11-22
---
# Show Time Machine local snapshots

APFS local snapshots keep deleted files' blocks alive, which is why the space freed after a cleanup can show up late or not at all. Both DiskSift's confirmation and its report already warn about this. Listing the snapshots (`tmutil listlocalsnapshots /`, with dates) would explain the gap instead of just mentioning it. Agreed while reviewing what else CleanMyMac offers after v0.2.0.

Listing works without admin rights and fits behind the existing `CommandRunner` fake. Removing snapshots (`tmutil deletelocalsnapshots` / `thinlocalsnapshots`) needs administrator rights, so it waits for the privileged helper from the v1 plan's "Later" list. Until then, show the snapshots and explain that macOS removes them on its own when space runs low.
