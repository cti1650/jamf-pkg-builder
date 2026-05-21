#!/bin/bash
# Takumi Guard 設定一括配布スクリプト (Jamf Pro ポリシーから root で実行する想定)
#
# 対応パッケージマネージャ: pip, npm, yarn, pnpm, bun
# いずれも 3 日 quarantine が適用される Flatt Security のエンドポイントに向ける。
#
# - npm / yarn / pnpm / bun  → https://npm.flatt.tech/
# - pip                       → https://pypi.flatt.tech/simple/
#
# どちらも Anonymous tier (無料、トークン不要) のエンドポイント。
# 組織契約のトークンを使う場合は TG_NPM_TOKEN / TG_PYPI_TOKEN を環境変数で渡し、
# URL を https://<token>@npm.flatt.tech/ の形に組み立てるよう各 write_* 関数を改修する。
#
# 既存設定があれば .bak を残してから上書きする。冪等。

set -euo pipefail

NPM_REGISTRY="https://npm.flatt.tech/"
PYPI_INDEX_URL="https://pypi.flatt.tech/simple/"
MARK="# managed-by: takumi-guard (jamf-pkg-builder)"

backup_once() {
  local f="$1"
  [[ -f "$f" && ! -f "${f}.takumi-guard.bak" ]] && cp "$f" "${f}.takumi-guard.bak"
}

# npm / yarn(classic) / pnpm / bun はすべて ~/.npmrc の registry= を参照する。
# yarn berry のみ .yarnrc.yml に npmRegistryServer を別途書く必要がある。
write_npmrc() {
  local home_dir="$1" user="$2"
  local f="$home_dir/.npmrc"
  backup_once "$f"
  # 既存の registry= 行を落としてから追記
  if [[ -f "$f" ]]; then
    /usr/bin/sed -i '' '/^registry[[:space:]]*=/d' "$f"
  fi
  {
    echo "$MARK"
    echo "registry=$NPM_REGISTRY"
  } >> "$f"
  chown "$user":staff "$f"
  chmod 644 "$f"
}

write_yarnrc_yml() {
  local home_dir="$1" user="$2"
  local f="$home_dir/.yarnrc.yml"
  backup_once "$f"
  if [[ -f "$f" ]]; then
    /usr/bin/sed -i '' '/^npmRegistryServer:/d' "$f"
  fi
  {
    echo "$MARK"
    echo "npmRegistryServer: \"${NPM_REGISTRY%/}\""
  } >> "$f"
  chown "$user":staff "$f"
  chmod 644 "$f"
}

write_bunfig() {
  local home_dir="$1" user="$2"
  local f="$home_dir/.bunfig.toml"
  backup_once "$f"
  if [[ -f "$f" ]]; then
    /usr/bin/sed -i '' '/^\[install\]$/,/^\[/{/^registry[[:space:]]*=/d;}' "$f"
  fi
  {
    echo ""
    echo "$MARK"
    echo "[install]"
    echo "registry = \"$NPM_REGISTRY\""
  } >> "$f"
  chown "$user":staff "$f"
  chmod 644 "$f"
}

write_pip_conf() {
  local home_dir="$1" user="$2"
  local dir="$home_dir/.config/pip"
  local f="$dir/pip.conf"
  mkdir -p "$dir"
  chown "$user":staff "$home_dir/.config" "$dir"
  backup_once "$f"
  cat > "$f" <<EOF
$MARK
[global]
index-url = $PYPI_INDEX_URL
EOF
  chown "$user":staff "$f"
  chmod 644 "$f"
}

apply_for_user() {
  local home_dir="$1"
  local user
  user="$(basename "$home_dir")"
  # システムユーザ / ゲスト等を除外
  case "$user" in
    Shared|Guest|.localized|root|daemon|nobody) return 0 ;;
  esac
  [[ -d "$home_dir" ]] || return 0

  echo "==> applying Takumi Guard config for $user ($home_dir)"
  write_npmrc       "$home_dir" "$user"
  write_yarnrc_yml  "$home_dir" "$user"
  write_bunfig      "$home_dir" "$user"
  write_pip_conf    "$home_dir" "$user"
}

main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "must run as root (Jamf policy)" >&2
    exit 1
  fi
  for h in /Users/*; do
    apply_for_user "$h"
  done
  echo "done."
}

main "$@"
