#!/usr/bin/env bash
# Build DiskSift and assemble build/DiskSift.app.
# usage: scripts/make-app.sh VERSION
#   UNIVERSAL=1      build arm64 + x86_64
#   SIGN_IDENTITY=…  codesign identity (default "-", ad-hoc)
set -euo pipefail

version="${1:?usage: make-app.sh VERSION}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

build_args=(-c release)
if [[ "${UNIVERSAL:-}" == "1" ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi

swift build "${build_args[@]}"
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"

app="build/DiskSift.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin_dir/DiskSift" "$app/Contents/MacOS/DiskSift"
sed "s/__VERSION__/${version}/g" Resources/Info.plist >"$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"
for lproj in Resources/*.lproj; do
    cp -R "$lproj" "$app/Contents/Resources/"
done
printf 'APPL????' >"$app/Contents/PkgInfo"

codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none "$app"
echo "built $app ($version)"
