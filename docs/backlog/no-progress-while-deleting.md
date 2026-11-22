---
worth: yes
where: Sources/DiskSift/Junk/JunkModel.swift:174
added: 2026-11-22
---
# no progress shown while deleting files

`JunkModel.delete` runs `Remover.remove(items, policy: .delete)` as one detached call and only updates the UI when the whole batch is done. Deleting tens of GB (Go module cache, npm cache, DerivedData) takes a while, and the window shows nothing until the report appears. Same for the uninstall path (`Uninstaller.uninstall`, `Sources/SiftCore/Removal/Uninstaller.swift:15`), though trashing is usually fast.

Wanted: per-item progress (current item, done/total, bytes freed so far) and ideally a Stop button between items. `Remover.remove` is synchronous over the whole list (`Sources/SiftCore/Removal/Remover.swift:14`), so it needs a per-item callback or an `AsyncStream` like `JunkScanner`'s progress. Raised by the user after the first manual run.
