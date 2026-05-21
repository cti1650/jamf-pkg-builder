#!/bin/bash
# Takumi Guard の registry 設定および minimumReleaseAge 設定を解除する。
# install.sh が残した .takumi-guard.bak があれば復元し、なければ
# "# managed-by: takumi-guard" 行とそれに続く管理ブロック (空行 or 別コメントに当たるまで) を削除する。
set -euo pipefail

strip_managed_block() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  /usr/bin/awk -v mark="managed-by: takumi-guard" '
    BEGIN { skip = 0 }
    {
      if (index($0, mark) > 0) { skip = 1; next }
      if (skip) {
        if ($0 ~ /^[[:space:]]*$/) { skip = 0; print; next }
        if ($0 ~ /^#/)             { skip = 0; print; next }
        next
      }
      print
    }
  ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

restore_or_strip() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if [[ -f "${f}.takumi-guard.bak" ]]; then
    mv "${f}.takumi-guard.bak" "$f"
    return 0
  fi
  strip_managed_block "$f"
}

revert_for_user() {
  local home_dir="$1"
  [[ -d "$home_dir" ]] || return 0
  restore_or_strip "$home_dir/.npmrc"
  restore_or_strip "$home_dir/.yarnrc.yml"
  restore_or_strip "$home_dir/.bunfig.toml"
  restore_or_strip "$home_dir/.config/pip/pip.conf"
}

main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
  fi
  for h in /Users/*; do
    revert_for_user "$h"
  done
  echo "done."
}

main "$@"
