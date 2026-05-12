#!/bin/bash
# Uninstall Slack. Run as root.
set -u

/usr/bin/pkill -f "/Applications/Slack.app" 2>/dev/null || true
sleep 2

rm -rf "/Applications/Slack.app"

for pkg in $(/usr/sbin/pkgutil --pkgs | grep -E '^(local\.jamf-pkg-builder\.slack|com\.tinyspeck\.slackmacgap)' 2>/dev/null); do
  /usr/sbin/pkgutil --forget "$pkg" >/dev/null 2>&1 || true
done

# Per-user data (~/Library/Application Support/Slack, ~/Library/Caches/com.tinyspeck.slackmacgap)
# is intentionally retained so re-install preserves sign-in state.

exit 0
