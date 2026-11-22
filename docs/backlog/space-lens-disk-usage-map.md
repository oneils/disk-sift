---
worth: yes
added: 2026-11-22
---
# Space Lens: map of where space goes in the home folder

A drill-down view (tree or treemap) of folder sizes under `~`, like CleanMyMac's Space Lens. The Large Files tab answers "which single files are big" but misses folders full of small files (`node_modules`, photo exports, old projects). Agreed while reviewing what else CleanMyMac offers after v0.2.0.

Builds on what exists: the `LargeFileScanner` walk and `LargeFilesScope` skip rules (aggregate sizes per folder instead of emitting files), `DirectorySizer` / `DirectoryChildren` for lazy sizing, and the junk tree UI. Removal, if any, should go through `RemovalRoots.largeFiles`, which only accepts files. Allowing whole folders to be trashed would need a scope decision, not a caller flag.
