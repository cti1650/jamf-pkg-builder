#!/bin/bash
# Uninstall Cloudflare WARP. Run as root.
# Reference: https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp/troubleshooting/uninstall/
set -u

# 1. Disconnect first so the daemon releases the system extension.
/usr/local/bin/warp-cli --accept-tos disconnect 2>/dev/null || true
/usr/local/bin/warp-cli --accept-tos delete     2>/dev/null || true

# 2. Stop daemons.
/bin/launchctl bootout system /Library/LaunchDaemons/com.cloudflare.1dot1dot1dot1.macos.warp.daemon.plist 2>/dev/null || true

# 3. Remove application + supporting files.
rm -rf "/Applications/Cloudflare WARP.app"
rm -rf /Library/Application\ Support/Cloudflare/
rm -f  /Library/LaunchDaemons/com.cloudflare.1dot1dot1dot1.macos.warp.daemon.plist
rm -f  /usr/local/bin/warp-cli
rm -f  /usr/local/bin/warp-diag

# 4. Forget pkgutil receipts.
for pkg in $(/usr/sbin/pkgutil --pkgs | grep -i 'cloudflare' 2>/dev/null); do
  /usr/sbin/pkgutil --forget "$pkg" >/dev/null 2>&1 || true
done

exit 0
