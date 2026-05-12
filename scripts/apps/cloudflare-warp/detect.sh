#!/bin/bash
# Custom detection — used when an app does not live at a fixed bundle path.
# Stdout must include one of: "installed" / "true" / "yes" / "found" for the
# verify step to treat the app as present.

WARP_CLI="/usr/local/bin/warp-cli"
APP="/Applications/Cloudflare WARP.app"

if [[ -d "$APP" ]] || [[ -x "$WARP_CLI" ]]; then
  echo "installed"
  exit 0
fi
echo "not found"
exit 1
