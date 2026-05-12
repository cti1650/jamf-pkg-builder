#!/bin/bash
# Uninstall Google Chrome. Run as root (Jamf Pro / MDM context).
set -u

# 1. Quit running Chrome processes (best-effort).
/usr/bin/pkill -f "/Applications/Google Chrome.app" 2>/dev/null || true
sleep 2

# 2. Remove application bundle.
rm -rf "/Applications/Google Chrome.app"

# 3. Forget pkgutil receipts (we install via pkgbuild repackage; identifier is local.*).
for pkg in $(/usr/sbin/pkgutil --pkgs | grep -E '^(local\.jamf-pkg-builder\.google-chrome|com\.google\.Chrome)' 2>/dev/null); do
  /usr/sbin/pkgutil --forget "$pkg" >/dev/null 2>&1 || true
done

# 4. System-level support files. Per-user profiles are intentionally left untouched
#    so Jamf-driven uninstall does not delete a user's browser data.

exit 0
