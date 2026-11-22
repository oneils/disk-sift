# disk-sift

A small native macOS app that uninstalls apps without leaving junk behind and cleans up caches you don't need.

> **Status:** early development. Nothing to download yet; the v1 design and implementation plan are in [`docs/plans/20261122-disk-sift-v1.md`](docs/plans/20261122-disk-sift-v1.md).

## What it does

**Uninstall apps completely.** Drag an app from `/Applications` into the window. DiskSift reads its bundle ID, Team ID and bundled helpers, then looks for what the app left in your Library:

- preferences, Application Support, caches, logs, saved state, HTTP storage, WebKit data, cookies
- sandbox containers and group containers
- launch agents and daemons that point into the app
- files installed by the app's `.pkg` installer (from `pkgutil` receipts)

Every finding shows its size and how sure DiskSift is that it belongs to the app. Matches by bundle ID are checked by default; matches by app name only are left unchecked for you to review. The app and the checked leftovers go to the Trash, so you can put anything back.

**Clean up junk.** One scan shows how much space these take:

- user caches and logs (`~/Library/Caches`, `~/Library/Logs`)
- developer junk: Xcode DerivedData, Archives, iOS DeviceSupport, simulator caches, Homebrew, npm, pip, cargo and Go caches

Uncheck what you want to keep and delete the rest. Caches are rebuilt by the apps that own them, so they are deleted permanently and the space is freed right away.

## Safety

- DiskSift only removes items inside a fixed list of locations (your Library, `/Library`, `/Applications` and known developer cache folders). Anything else is refused, whatever the UI asks for.
- Symlinks are removed as links; their targets are never touched.
- Apple's own apps and anything under `/System` can't be uninstalled.
- Items owned by root (for example in `/Library/LaunchDaemons`) are shown but not removed in v1.
- If the app you drop is running, DiskSift asks to quit it first.

## Requirements

- macOS 14 Sonoma or later, Apple silicon or Intel
- **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access). Without it macOS hides containers and some Library folders; DiskSift still works but shows a banner and marks those places as inaccessible.

## Build

Swift 6 and the Xcode Command Line Tools are enough; Xcode itself is not required.

```sh
make test         # swift test
make lint         # swift format lint
make app          # builds build/DiskSift.app (ad-hoc signed)
open build/DiskSift.app
```

## Install from releases

Release builds will be attached to [GitHub Releases](../../releases) as a zip with `checksums.txt`. They are ad-hoc signed, not notarized, so macOS blocks the first launch. Either right-click the app and choose **Open**, or run:

```sh
xattr -d com.apple.quarantine /Applications/DiskSift.app
```

## Not in v1

Large and old file reports, system junk (Trash, installers, iOS backups, language files), removing root-owned items, a background agent that watches for deleted apps, and an App Store version (the App Store sandbox doesn't allow reading other apps' data).

## Tech

Pure Swift: SwiftUI app on top of a `SiftCore` library that does the scanning, matching, sizing and removal. Built with SwiftPM, tested with Swift Testing against real temporary file trees. Interface in English and Russian.

## License

[MIT](LICENSE)
