#!/bin/bash
# Takumi Guard が「全ユーザのうち少なくとも 1 人」に適用されているかを返す。
# 適用済みなら exit 0, 未適用なら exit 1 (Jamf の smart group 用)。
set -euo pipefail

found=1
for h in /Users/*; do
  [[ -d "$h" ]] || continue
  for f in "$h/.npmrc" "$h/.yarnrc.yml" "$h/.bunfig.toml" "$h/.config/pip/pip.conf"; do
    if [[ -f "$f" ]] && /usr/bin/grep -q "managed-by: takumi-guard" "$f" 2>/dev/null; then
      found=0
      break 2
    fi
  done
done

exit "$found"
