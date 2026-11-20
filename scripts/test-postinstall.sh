#!/usr/bin/env bash
# Runs packaging/munki/postinstall.sh with every system command it uses
# replaced by a stub, once per situation an install can meet, and checks
# what it would quit and start. Needs no root and changes nothing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/packaging/munki/postinstall.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

stubbed="$work/postinstall.sh"
{
  head -n 1 "$script"
  cat <<'STUBS'
stub_stat() { print -r -- "$STUB_USER"; }
stub_pgrep() { [[ -f "$STUB_STATE/running" ]]; }
stub_pkill() { print kill >>"$STUB_STATE/log"; rm -f "$STUB_STATE/running"; }
stub_dscl() { print -r -- "NFSHomeDirectory: $STUB_HOME"; }
stub_id() { print 501; }
stub_launchctl() { print -r -- "launchctl $*" >>"$STUB_STATE/log"; }
STUBS
  tail -n +2 "$script"
} >"$stubbed"

# Every system command with an effect or an answer is stubbed; the test
# fails when the script stops using one, so it is updated with the script.
for command in /usr/bin/stat /usr/bin/pgrep /usr/bin/pkill /usr/bin/dscl /usr/bin/id /bin/launchctl; do
  grep -qF "$command " "$stubbed" || { echo "postinstall no longer uses $command: update $0" >&2; exit 1; }
  sed -i '' "s#$command #stub_$(basename "$command") #g" "$stubbed"
done

launch="launchctl asuser 501 /usr/bin/sudo -u tester /usr/bin/open -g -a /Applications/MacHorus.app"
failures=0

# check <situation> <console user> <running 0|1> <settings exist 0|1> <expected actions>
check() {
  local situation="$1" user="$2" running="$3" settings="$4" expected="$5"
  local state="$work/state" home="$work/home"
  rm -rf "$state" "$home"
  mkdir -p "$state" "$home/Library/Preferences"
  touch "$state/log"
  [[ "$running" == 1 ]] && touch "$state/running"
  [[ "$settings" == 1 ]] && touch "$home/Library/Preferences/app.machorus.MacHorus.plist"
  [[ "$settings" == unknown ]] && home=""
  STUB_USER="$user" STUB_STATE="$state" STUB_HOME="$home" /bin/zsh "$stubbed" || {
    echo "FAIL $situation: exit code $?"
    failures=$((failures + 1))
    return
  }
  local actions
  actions="$(cat "$state/log")"
  if [[ "$actions" == "$expected" ]]; then
    echo "ok   $situation"
  else
    echo "FAIL $situation"
    echo "     expected: ${expected:-<nothing>}"
    echo "     got:      ${actions:-<nothing>}"
    failures=$((failures + 1))
  fi
}

check "nobody logged in (root)" root 1 1 ""
check "login window" loginwindow 1 1 ""
check "update while running" tester 1 1 "kill"$'\n'"$launch"
check "first install" tester 0 0 "$launch"
check "first install, home unknown" tester 0 unknown "$launch"
check "quit by the user before the update" tester 0 1 ""

[[ "$failures" -eq 0 ]] || { echo "postinstall: $failures situation(s) failed" >&2; exit 1; }
echo "postinstall ok: 6 situations"
