#!/usr/bin/env bash
# Verify the structure of build/DiskSift.app produced by make-app.sh.
# usage: scripts/check-app.sh [APP]   (UNIVERSAL=1 also checks for arm64 + x86_64 slices)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/build/DiskSift.app}"
plist="$app/Contents/Info.plist"
fail=0

err() {
    echo "FAIL: $*" >&2
    fail=1
}

value() {
    plutil -extract "$1" raw -o - "$plist" 2>/dev/null || true
}

[[ -d "$app" ]] || { echo "FAIL: $app not found" >&2; exit 1; }

[[ "$(value CFBundleIdentifier)" == "dev.disksift.DiskSift" ]] || err "CFBundleIdentifier is '$(value CFBundleIdentifier)'"
[[ "$(value LSMinimumSystemVersion)" == "14.0" ]] || err "LSMinimumSystemVersion is '$(value LSMinimumSystemVersion)'"
version="$(value CFBundleShortVersionString)"
if [[ -z "$version" || "$version" == "__VERSION__" ]]; then
    err "CFBundleShortVersionString is '$version'"
fi
[[ "$(value CFBundleVersion)" == "$version" ]] || err "CFBundleVersion '$(value CFBundleVersion)' != '$version'"
[[ "$(value CFBundleIconFile)" == "AppIcon.icns" ]] || err "CFBundleIconFile is '$(value CFBundleIconFile)'"
[[ -s "$app/Contents/Resources/AppIcon.icns" ]] || err "AppIcon.icns missing or empty"

for lang in en ru; do
    [[ -f "$app/Contents/Resources/$lang.lproj/Localizable.strings" ]] || err "$lang.lproj/Localizable.strings missing"
    [[ -f "$app/Contents/Resources/$lang.lproj/Localizable.stringsdict" ]] || err "$lang.lproj/Localizable.stringsdict missing"
done

exe="$app/Contents/MacOS/DiskSift"
[[ -x "$exe" ]] || err "$exe missing or not executable"

codesign -v --strict "$app" || err "codesign verification failed"

if [[ "${UNIVERSAL:-}" == "1" ]]; then
    archs="$(lipo -archs "$exe" 2>/dev/null || true)"
    for arch in arm64 x86_64; do
        [[ " $archs " == *" $arch "* ]] || err "arch $arch missing (got '$archs')"
    done
fi

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi
echo "ok: $app ($version)"
