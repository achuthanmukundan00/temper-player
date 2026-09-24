#!/bin/bash
# Build a native macOS app and DMG. Ad-hoc signing is not notarization.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
out=${1:-"$root/releases"}
zig=${ZIG:-zig}
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/packaging/Info.plist")
case "$(uname -m)" in
    arm64) target=aarch64-macos.14.0 ;;
    x86_64) target=x86_64-macos.14.0 ;;
    *) echo 'Unsupported macOS architecture' >&2; exit 1 ;;
esac
if [[ "$("$zig" version)" != 0.16.0 ]]; then
    echo 'Packaging requires Zig 0.16.0 (set ZIG to its executable path).' >&2
    exit 1
fi
mkdir -p "$out"
out=$(cd "$out" && pwd -P)
dmg="TemperPlayer-v$version.dmg"
if [[ -e "$out/$dmg" || -e "$out/SHA256SUMS" ]]; then
    echo 'Output already exists; choose a fresh output directory.' >&2
    exit 1
fi

# Baseline CPU and macOS 14 deployment target, not this build machine's CPU/OS.
(cd "$root/zig-core" && "$zig" build -Dtarget="$target" -Dcpu=baseline --release=fast)
(cd "$root/TemperPlayer" && swift build -c release)
bin=$(cd "$root/TemperPlayer" && swift build -c release --show-bin-path)
stage=$(mktemp -d "$out/.package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/TemperPlayer.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp "$bin/TemperPlayer" "$app/Contents/MacOS/TemperPlayer"
cp "$root/zig-core/zig-out/lib/libtemperplayer.dylib" "$app/Contents/Frameworks/"
cp "$root/packaging/Info.plist" "$app/Contents/Info.plist"
cp "$root/TemperPlayer/Resources/TemperPlayer.icns" "$app/Contents/Resources/"
cp "$root/packaging/THIRD-PARTY-NOTICES.txt" "$app/Contents/Resources/"

# A distributable bundle must not depend on the source checkout.
exe="$app/Contents/MacOS/TemperPlayer"
while IFS= read -r rpath; do
    case "$rpath" in
        @*|/usr/lib/swift) ;;
        /*) install_name_tool -delete_rpath "$rpath" "$exe" ;;
    esac
done < <(otool -l "$exe" | awk '/cmd LC_RPATH/{getline; getline; sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print}')
install_name_tool -id '@rpath/libtemperplayer.dylib' "$app/Contents/Frameworks/libtemperplayer.dylib"
codesign --force --sign - "$app/Contents/Frameworks/libtemperplayer.dylib"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
plutil -lint "$app/Contents/Info.plist"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "TemperPlayer $version" -srcfolder "$stage" -format UDZO "$out/$dmg"
hdiutil verify -quiet "$out/$dmg"
(cd "$out" && shasum -a 256 "$dmg" > SHA256SUMS)
printf 'Packaged %s\nAd-hoc signed; not Developer ID signed or notarized.\n' "$out/$dmg"
