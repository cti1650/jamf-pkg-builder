#!/bin/bash
# Jamf Pro Extension Attribute — Cloudflare WARP status + version
WARP_CLI="/usr/local/bin/warp-cli"
APP="/Applications/Cloudflare WARP.app"

if [[ ! -d "$APP" ]]; then
  echo "<result>Not Installed</result>"
  exit 0
fi

ver=$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)

if [[ -x "$WARP_CLI" ]]; then
  status=$("$WARP_CLI" --accept-tos status 2>/dev/null | head -1 | sed 's/^Status update: //')
  echo "<result>${ver:-Unknown} (${status:-unknown-status})</result>"
else
  echo "<result>${ver:-Unknown}</result>"
fi
