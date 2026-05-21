#!/bin/bash
# Takumi Guard の registry 設定を解除する。
# install.sh が残した .takumi-guard.bak があれば復元し、なければ managed-by 行と
# それに続く registry/index-url 設定行のみを削除する。
set -euo pipefail

MARK="# managed-by: takumi-guard (jamf-pkg-builder)"

restore_or_strip() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if [[ -f "${f}.takumi-guard.bak" ]]; then
    mv "${f}.takumi-guard.bak" "$f"
    return 0
  fi
  # MARK と直後の 1〜2 行 (registry / index-url / [install] / npmRegistryServer) を落とす。
  /usr/bin/sed -i '' "\#${MARK}#,+2d" "$f" || true
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
