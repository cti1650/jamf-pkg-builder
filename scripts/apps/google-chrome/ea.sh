#!/bin/bash
# Jamf Pro Extension Attribute — Google Chrome version
APP="/Applications/Google Chrome.app"
if [[ -d "$APP" ]]; then
  ver=$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
  echo "<result>${ver:-Unknown}</result>"
else
  echo "<result>Not Installed</result>"
fi
