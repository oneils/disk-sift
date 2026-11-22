# disk-sift

Native macOS app (SwiftUI) that uninstalls apps with their leftovers and cleans junk. SwiftPM only, no Xcode project.

## Commands

- `make test` - `swift test` (adds the Swift Testing macro plugin path on CLT-only machines)
- `make lint` / `make format` - swift-format over `Package.swift Sources Tests`
- `make app [VERSION=x.y.z] [UNIVERSAL=1] [SIGN_IDENTITY=...]`, `make check-app` - assemble and verify `build/DiskSift.app`
- Build products: `swift build --show-bin-path` (never hardcode `.build/...`)
- Release: push a `v*` tag; `.github/workflows/release.yml` builds, zips, checksums, uses `scripts/changelog.sh`

## Layout

- `Sources/SiftCore` - UI-free library: `SiftPaths`, `App` (AppInfo, signing, validation), `Leftovers` (sources + merger, `OrphanScanner` for leftovers of removed apps), `Removal` (`Remover`, `RemovalRoots`), `Junk`, `LargeFiles` (scope, scanner, Spotlight last-used lookup), `SpaceLens` (`SpaceScanner` one-pass fts walk, `SpaceTree`), `NeuralDSP` (locations, scanner, remover, `PrivilegedRunner` via osascript), `FS`, `Model`
- `Sources/DiskSift` - SwiftUI app: `Uninstall`, `Junk`, `LargeFiles`, `SpaceLens`, `Plugins`, `Shared` (components, report sheet, `ReportContext`), FDA banner, `.lproj` localization (en, ru)
- `Tests/SiftCoreTests`, `Tests/DiskSiftTests` - Swift Testing

## Conventions

- All locations come from an injected `SiftPaths`; tests point it at temp dirs. No filesystem mocks: tests use real temporary file trees. System calls go through `CommandRunner` / `SystemLookups` fakes.
- Safety rules live in `Remover` / `RemovalRoots`: only items strictly inside the allowed roots, never a root itself, paths canonicalized first, symlinks removed as links and never followed, root-owned items skipped. Do not weaken these; extend tests when touching them.
- The one root exception is `NeuralDSPRemover`. It applies only to parts that re-validate as a real directory directly inside their kind's canonical root (a symlinked root refuses), named after the plugin, and with a `com.neuraldsp.` bundle ID for bundles (the plug-in folders are shared with every vendor). It runs the root step first, then trashes through `Remover`. `OSAScriptPrivilegedRunner` passes paths only as osascript argv with `quoted form of` and pins each parent with `cd -P` plus a `pwd -P` check before `rm -rf`. Accepted remaining risk: the last component swapped for a symlink between `cd` and `rm`, which `rm` removes as a link. Never route other removals through it.
- Three removal scopes: `RemovalRoots.make` (uninstall and junk: Library scan dirs, Applications folders, dev cache parents), `RemovalRoots.largeFiles` (Large Files and the installers junk category: home minus the `LargeFilesScope` deny list, same volume only, files only) and `RemovalRoots.spaceLens` (the same deny list, files and folders, Trash only). The scope carries its own rules (`filesOnly`, `trashOnly`) and `Remover` enforces them; never add a caller-side flag for that.
- Uninstall order: unload launch items, move the app to the Trash, and only if that succeeds, remove leftovers. App failure leaves leftovers alone.
- Localization via `.lproj` strings; a parity test keeps en and ru keys identical. Add both when adding a string.

## CLT-only constraints (no Xcode)

- Swift Testing's macro plugin lives in a CLT subdirectory the default backend doesn't search; `make test` passes `-Xswiftc -plugin-path` for it when `xcode-select -p` is CommandLineTools. Run tests via `make test`, not bare `swift test`.
- SwiftUI macros such as `@State` are unavailable without Xcode's plugins; view state lives in `@Observable` model classes instead.
- `.swift-format` may only use keys supported by swift-format 6.1 (CI toolchain); newer keys break CI lint.
- CI runs on `macos-15` with Xcode 16.4 (Swift 6.1), pinned in both workflows. Code must compile with Swift 6.1 even though local toolchain is newer.
