#!/bin/bash
# Jamf Pro Extension Attribute — Zoom version
APP="/Applications/zoom.us.app"
if [[ -d "$APP" ]]; then
  ver=$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
  echo "<result>${ver:-Unknown}</result>"
else
  echo "<result>Not Installed</result>"
fi
