#!/usr/bin/env bash
# Wraps build/MacHorus.app into dist/MacHorus-<version>.pkg for Munki.
# The package installs to /Applications and is not relocatable, so an update
# always replaces the app at the same path.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

app="build/MacHorus.app"
[[ -d "$app" ]] || { echo "$app missing: run 'make app' first." >&2; exit 1; }

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/root/Applications" dist
ditto --norsrc --noextattr --noqtn "$app" "$work/root/Applications/MacHorus.app"

pkgbuild --analyze --root "$work/root" "$work/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$work/components.plist"

scripts=()

output="dist/MacHorus-$version.pkg"
COPYFILE_DISABLE=1 pkgbuild --quiet --root "$work/root" "${scripts[@]}" \
  --component-plist "$work/components.plist" \
  --identifier app.machorus.MacHorus.pkg \
  --version "$version" \
  --install-location / \
  "$output"

# Some environments (e.g. agent or sandboxed shells) tag every new file with
# the protected com.apple.provenance attribute; pkgbuild then ships it as
# AppleDouble "._" files. A release package must not contain them.
appledouble="$(pkgutil --payload-files "$output" | grep -c '/\._' || true)"
if [[ "$appledouble" -gt 0 ]]; then
  if [[ "${MACHORUS_ALLOW_XATTRS:-0}" == "1" ]]; then
    echo "WARNING: $output contains $appledouble AppleDouble files (test build only)." >&2
  else
    rm -f "$output"
    echo "Payload contains $appledouble AppleDouble files (extended attributes)." >&2
    echo "Build the release from a regular Terminal session, or set MACHORUS_ALLOW_XATTRS=1 for a test package." >&2
    exit 1
  fi
fi

echo "Built $output"
