#!/bin/bash
# Takumi Guard の registry 設定および minimumReleaseAge 設定を解除する。
#
# install.sh が末尾に追記した管理ブロック ("# managed-by: takumi-guard" 行以下) を削除し、
# ユーザの既存設定行に付与した "# disabled-by: takumi-guard " プレフィックスを剥がす。
# 結果として「install で追記/変更した内容だけ」が元に戻る (install 後にユーザが
# 管理ブロック外で加えた編集は保持される)。
#
# .takumi-guard.bak は監査用に残しっぱなしにしている (デフォルトでは復元に使わない)。
# 完全に install 前の状態に巻き戻したい場合のみ、引数に --restore-bak を渡す。
set -euo pipefail

MARK_NEEDLE="managed-by: takumi-guard"
DISABLE_PREFIX="# disabled-by: takumi-guard "

# "# managed-by: takumi-guard" 行と続く管理ブロック (空行 or 他コメントに当たるまで) を削除。
strip_managed_block() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  /usr/bin/awk -v mark="$MARK_NEEDLE" '
    BEGIN { skip = 0 }
    {
      if (index($0, mark) > 0) { skip = 1; next }
      if (skip) {
        if ($0 ~ /^[[:space:]]*$/) { skip = 0; print; next }
        if ($0 ~ /^#/ && index($0, "disabled-by: takumi-guard") == 0) { skip = 0; print; next }
        next
      }
      print
    }
  ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

# 行頭の "# disabled-by: takumi-guard " を剥がして元の行を復活させる。
reenable_disabled_lines() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  /usr/bin/awk -v pre="$DISABLE_PREFIX" '
    {
      if (index($0, pre) == 1) {
        print substr($0, length(pre) + 1)
      } else {
        print
      }
    }
  ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

revert_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  strip_managed_block "$f"
  reenable_disabled_lines "$f"
}

restore_from_bak() {
  local f="$1"
  [[ -f "${f}.takumi-guard.bak" ]] || return 0
  mv "${f}.takumi-guard.bak" "$f"
}

revert_for_user() {
  local home_dir="$1" mode="$2"
  [[ -d "$home_dir" ]] || return 0
  local files=(
    "$home_dir/.npmrc"
    "$home_dir/.yarnrc.yml"
    "$home_dir/.bunfig.toml"
    "$home_dir/Library/Application Support/pip/pip.conf"
    "$home_dir/.config/pip/pip.conf"
    "$home_dir/.config/uv/uv.toml"
    "$home_dir/Library/Application Support/pypoetry/config.toml"
    "$home_dir/.bundle/config"
  )
  local f
  for f in "${files[@]}"; do
    if [[ "$mode" == "bak" ]]; then
      restore_from_bak "$f"
    else
      revert_file "$f"
    fi
  done
}

main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
  fi
  local mode="strip"
  [[ "${1:-}" == "--restore-bak" ]] && mode="bak"

  for h in /Users/*; do
    revert_for_user "$h" "$mode"
  done
  echo "done. (mode=$mode)"
}

# テストから関数だけ source できるように、直接実行時のみ main を呼ぶ。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
