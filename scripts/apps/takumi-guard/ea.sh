#!/bin/bash
# Jamf Pro Extension Attribute: Takumi Guard が適用されたユーザ数を返す。
# 0 のとき = 未適用。
set -euo pipefail

count=0
for h in /Users/*; do
  [[ -d "$h" ]] || continue
  for f in \
    "$h/.npmrc" \
    "$h/.yarnrc.yml" \
    "$h/.bunfig.toml" \
    "$h/Library/Application Support/pip/pip.conf" \
    "$h/.config/pip/pip.conf" \
    "$h/.config/uv/uv.toml" \
    "$h/Library/Application Support/pypoetry/config.toml" \
    "$h/.bundle/config"; do
    if [[ -f "$f" ]] && /usr/bin/grep -q "managed-by: takumi-guard" "$f" 2>/dev/null; then
      count=$((count + 1))
      break
    fi
  done
done

echo "<result>$count</result>"
