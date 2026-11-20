#!/usr/bin/env bash
# Creates dist/MacHorus-<version>.pkginfo for Munki from the package built by
# `make release`. Catalog defaults to "testing"; set MUNKI_CATALOG to change it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

makepkginfo=/usr/local/munki/makepkginfo
[[ -x "$makepkginfo" ]] || { echo "Munki tools not found at $makepkginfo" >&2; exit 1; }

app="build/MacHorus.app"
plist="$app/Contents/Info.plist"
[[ -f "$plist" ]] || { echo "$app missing: run 'make release' first." >&2; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
pkg="dist/MacHorus-$version.pkg"
[[ -f "$pkg" ]] || { echo "$pkg missing: run 'make release' first." >&2; exit 1; }
output="dist/MacHorus-$version.pkginfo"

"$makepkginfo" "$pkg" \
  --name MacHorus \
  --displayname MacHorus \
  --description "System monitor and everyday tools in the menu bar. No account, no telemetry." \
  --category Utilities \
  --developer "MacHorus contributors" \
  --minimum_os_version 14.2 \
  --arch arm64 \
  --arch x86_64 \
  --unattended_install \
  --catalog "${MUNKI_CATALOG:-testing}" \
  --postinstall_script packaging/munki/postinstall.sh \
  >"$output"

# MacHorus is always running. Without an explicit empty list Munki would treat
# the app as blocking and never update it unattended; postinstall relaunches it.
plutil -insert blocking_applications -array "$output"

# Compare against the installed app bundle, not only the package receipt.
plutil -insert installs -array "$output"
plutil -insert installs.0 -dictionary "$output"
plutil -insert installs.0.type -string application "$output"
plutil -insert installs.0.path -string /Applications/MacHorus.app "$output"
plutil -insert installs.0.CFBundleIdentifier -string "$bundle_id" "$output"
plutil -insert installs.0.CFBundleName -string MacHorus "$output"
plutil -insert installs.0.CFBundleShortVersionString -string "$version" "$output"
plutil -insert installs.0.minosversion -string 14.2 "$output"
plutil -insert installs.0.version_comparison_key -string CFBundleShortVersionString "$output"

plutil -lint "$output" >/dev/null
echo "Built $output"
