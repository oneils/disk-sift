# disk-sift

A small native macOS app that uninstalls apps without leaving junk behind and cleans up caches you don't need.

> **Status:** v1 is feature complete. Download a build from [Releases](../../releases) or build it yourself. The design and implementation plan are in [`docs/plans/20261122-disk-sift-v1.md`](docs/plans/20261122-disk-sift-v1.md).

## What it does

**Uninstall apps completely.** Drag an app from `/Applications` or `~/Applications` into the window. DiskSift reads its bundle ID, Team ID and bundled helpers, then looks for what the app left in your Library:

- preferences, Application Support, caches, logs, saved state, HTTP storage, WebKit data, cookies
- sandbox containers and group containers
- launch agents and daemons that point into the app
- files installed by the app's `.pkg` installer (from `pkgutil` receipts)

Every finding shows its size and how sure DiskSift is that it belongs to the app. Matches by bundle ID are checked by default. Matches by app name only, and data the vendor's other apps share (for example Office's group container), are left unchecked for you to review. DiskSift unloads the app's launch agents, then moves the app and the checked leftovers to the Trash, so you can put anything back.

**Clean up junk.** One scan shows how much space these take:

- user caches and logs (`~/Library/Caches`, `~/Library/Logs`)
- developer junk: Xcode DerivedData, Archives, iOS DeviceSupport, simulator caches, Homebrew, npm, pip, cargo and Go caches

User caches and logs start unchecked: pick what you want to delete. Developer caches start checked, except Xcode Archives (they hold dSYMs). Caches are rebuilt by the apps that own them, so they are deleted permanently and the space is freed right away.

Sizes are allocated sizes on disk. Because of APFS clones and local Time Machine snapshots, the space actually freed can be smaller.

## Safety

- DiskSift only removes items inside a fixed list of folders: the Library folders it scans, `/Applications`, `~/Applications` and known developer cache folders, never those folders themselves. Anything else, such as iCloud Drive, cloud storage, Mail or Keychains, is refused, whatever the UI asks for.
- Paths are resolved before the check, so a symlink can't lead it outside those folders. Symlinks are removed as links; their targets are never touched.
- If the app itself can't be moved to the Trash, its leftovers are left alone.
- Apple's own apps and anything under `/System` can't be uninstalled.
- Items owned by root (for example in `/Library/LaunchDaemons`) are shown but not removed in v1. Apps installed as root are refused up front.
- If the app you drop is running, DiskSift asks to quit it first.

## Requirements

- macOS 14 Sonoma or later, Apple silicon or Intel
- **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access). Without it macOS hides app containers and some Library folders; DiskSift still works but shows a banner and skips those places.

## Build

Swift 6 and the Xcode Command Line Tools are enough; Xcode itself is not required.

```sh
make test         # swift test
make lint         # swift format lint
make app          # builds build/DiskSift.app (ad-hoc signed)
make check-app    # sanity-checks the bundle
UNIVERSAL=1 make app   # arm64 + x86_64
open build/DiskSift.app
```

macOS ties the Full Disk Access grant of an ad-hoc signed app to its exact build, so you have to grant it again after every rebuild. To avoid that, create a self-signed code-signing certificate in Keychain Access and build with `SIGN_IDENTITY="<certificate name>" make app`.

## Install from releases

Release builds (universal, arm64 + x86_64) are attached to [GitHub Releases](../../releases) as a zip with `checksums.txt`. They are ad-hoc signed, not notarized, so macOS blocks the first launch (right-click → **Open** no longer helps on macOS 15 and later). Either remove the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/DiskSift.app
```

or try to open the app once, then click **Open Anyway** in System Settings → Privacy & Security.

## Not in v1

Large and old file reports, system junk (Trash, installers, iOS backups, language files), removing root-owned items, a background agent that watches for deleted apps, and an App Store version (the App Store sandbox doesn't allow reading other apps' data).

## Tech

Pure Swift: SwiftUI app on top of a `SiftCore` library that does the scanning, matching, sizing and removal. Built with SwiftPM, tested with Swift Testing against real temporary file trees. Interface in English and Russian.

## License

[MIT](LICENSE)
