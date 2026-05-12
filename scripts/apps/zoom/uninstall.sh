#!/bin/bash
# Uninstall Zoom Workplace. Run as root.
# Reference: https://support.zoom.us/hc/en-us/articles/201362983
set -u

/usr/bin/pkill -f "/Applications/zoom.us.app" 2>/dev/null || true
sleep 2

rm -rf "/Applications/zoom.us.app"
rm -rf "/Library/Internet Plug-Ins/ZoomUsPlugIn.plugin"
rm -rf "/Library/Logs/zoom.us"

for pkg in $(/usr/sbin/pkgutil --pkgs | grep -E '^us\.zoom\.' 2>/dev/null); do
  /usr/sbin/pkgutil --forget "$pkg" >/dev/null 2>&1 || true
done

# Per-user data (ZoomChat cache, sign-in tokens) is intentionally retained.

exit 0
