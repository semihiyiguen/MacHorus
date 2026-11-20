#!/usr/bin/env bash
# Assembles build/MacHorus.app from the SwiftPM release binary and signs it
# with the stable "MacHorus Signing" identity (see scripts/setup-signing.sh).
#
# Usage: scripts/bundle-app.sh            # sign with MacHorus Signing
#        MACHORUS_ADHOC=1 scripts/bundle-app.sh   # ad-hoc, e.g. on CI
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

identity="MacHorus Signing"
keychain="$HOME/Library/Keychains/machorus-signing.keychain-db"
bundle_id="app.machorus.MacHorus"
binary="${MACHORUS_BINARY:-$(swift build -c release --show-bin-path)/MacHorus}"
app="build/MacHorus.app"
version="$(tr -d '[:space:]' < VERSION)"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

[[ -x "$binary" ]] || { echo "Release binary missing: run 'make app'." >&2; exit 1; }
# Munki serves Apple Silicon and Intel Macs from the same package.
archs="$(lipo -archs "$binary")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || echo "Note: binary has only $archs (not universal)." >&2

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/MacHorus"
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$app/Contents/Info.plist"
for lproj in Resources/*.lproj; do
  cp -R "$lproj" "$app/Contents/Resources/"
done
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
plutil -lint "$app/Contents/Info.plist" >/dev/null

# Without the local signing identity (a fresh clone): ad-hoc. It runs the
# same, but macOS asks for permissions again after every rebuild; run
# scripts/setup-signing.sh once to keep them.
if [[ "${MACHORUS_ADHOC:-0}" == "1" || ! -f "$keychain" ]]; then
  codesign --force --options runtime --identifier "$bundle_id" --sign - "$app"
  echo "Built $app $version ($build_number), ad-hoc signed."
  [[ -f "$keychain" ]] || echo "Tip: scripts/setup-signing.sh creates a local signing identity, so permissions survive rebuilds."
  exit 0
fi

password="$(security find-generic-password -s machorus-signing-keychain -a "$USER" -w 2>/dev/null)" || {
  echo "Signing keychain password not found. Run scripts/setup-signing.sh first." >&2
  exit 1
}
security unlock-keychain -p "$password" "$keychain"
unset password

codesign --force --options runtime --timestamp=none --identifier "$bundle_id" \
  --sign "$identity" --keychain "$keychain" "$app"
codesign --verify --strict --verbose=1 "$app"

# The designated requirement must pin the certificate, otherwise macOS would
# not carry granted permissions over to the next build.
leaf_hash="$(security find-certificate -c "$identity" -Z "$keychain" | awk '/SHA-1 hash:/ {print tolower($3)}')"
requirement="$(codesign -d -r- "$app" 2>&1)"
if [[ "$requirement" != *"identifier \"$bundle_id\""* || "$requirement" != *"certificate leaf = H\"$leaf_hash\""* ]]; then
  echo "Unexpected designated requirement:" >&2
  echo "$requirement" >&2
  exit 1
fi

echo "Built $app $version ($build_number), signed with '$identity'."
