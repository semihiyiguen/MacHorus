#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Munki postinstall: makes an install or update take effect for the user at
# the screen, without logging out.
# - MacHorus was running: quit it and start the new version.
# - MacHorus never ran for this user (first install): start it; its first
#   launch from /Applications turns "Open at login" on.
# - The user had quit MacHorus: leave it quit. It opens at the next login if
#   "Open at login" is on.

console_user=$(/usr/bin/stat -f %Su /dev/console)
[[ -z "$console_user" || "$console_user" == "root" || "$console_user" == "loginwindow" ]] && exit 0

if /usr/bin/pgrep -xq MacHorus; then
  /usr/bin/pkill -x MacHorus
  for _ in {1..10}; do
    /usr/bin/pgrep -xq MacHorus || break
    sleep 0.5
  done
else
  # MacHorus writes its settings at the first launch.
  home=$(/usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
  [[ -n "$home" && -f "$home/Library/Preferences/app.machorus.MacHorus.plist" ]] && exit 0
fi

uid=$(/usr/bin/id -u "$console_user")
/bin/launchctl asuser "$uid" /usr/bin/sudo -u "$console_user" /usr/bin/open -g -a /Applications/MacHorus.app
exit 0
