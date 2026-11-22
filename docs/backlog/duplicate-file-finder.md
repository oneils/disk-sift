---
worth: yes
added: 2026-11-22
---
# Duplicate file finder

Find identical files in the home folder (Downloads, Documents, Pictures and so on) and let the user keep one copy. Agreed while reviewing what else CleanMyMac offers after v0.2.0.

Likely shape: group by size first, then by a partial hash, then a full hash, all within the `LargeFilesScope` skip rules and with a minimum size so the walk stays cheap. Nothing is preselected except extra copies the user picks. Removal goes only to the Trash through `RemovalRoots.largeFiles` (files only). Things to watch: APFS clones look like duplicates but share blocks, so trashing one frees nothing (show it, don't promise space). Hard links are one file, as the scanner already handles.
