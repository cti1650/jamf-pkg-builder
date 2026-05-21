#!/bin/bash
# Takumi Guard + 3 日 minimum-release-age を全ユーザに一括適用するスクリプト
# (Jamf Pro ポリシーから root で実行する想定)
#
# 二段構えで supply chain attack を防ぐ:
#   (1) registry を Flatt Security のプロキシに向ける (blocklist 防御)
#       - npm 系 (npm/yarn/pnpm/bun) → https://npm.flatt.tech/
#       - pip                          → https://pypi.flatt.tech/simple/  (72h quarantine 自動)
#   (2) 各パッケージマネージャ標準の "公開から N 日経っていないバージョンを除外" 機能で
#       3 日遅延をクライアント側からも強制する。pip は (1) の quarantine と二重保険。
#
# 3 日 = 72 時間 = 4320 分 = 259200 秒。各マネージャで単位が違うので注意:
#   - npm  (.npmrc)            : min-release-age=3                (日)        ※ npm CLI 11.10+
#   - pnpm (~/.npmrc など)      : minimum-release-age=4320         (分)        ※ pnpm 10.16+
#   - yarn (~/.yarnrc.yml)     : npmMinimalAgeGate: "3d"          (duration)  ※ Yarn berry 4.10+ のみ。classic は未対応
#   - bun  (~/.bunfig.toml)     : minimumReleaseAge = 259200       (秒)        ※ Bun 1.3+
#
# 既存設定があれば .takumi-guard.bak を残してから上書きする。冪等。

set -euo pipefail

NPM_REGISTRY="https://npm.flatt.tech/"
PYPI_INDEX_URL="https://pypi.flatt.tech/simple/"

# minimumReleaseAge 値 (3 日)
NPM_MIN_RELEASE_AGE_DAYS=3
PNPM_MIN_RELEASE_AGE_MIN=4320
YARN_MIN_AGE_GATE="3d"
BUN_MIN_RELEASE_AGE_SEC=259200

MARK="# managed-by: takumi-guard (jamf-pkg-builder)"

backup_once() {
  local f="$1"
  [[ -f "$f" && ! -f "${f}.takumi-guard.bak" ]] && cp "$f" "${f}.takumi-guard.bak"
}

# 既存の MARK ブロック (MARK 行 + 直後の連続する non-blank 設定行) を除去してから書き直す。
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

# npm / pnpm 兼用の ~/.npmrc。
# - registry=  は npm / yarn classic / pnpm / bun が共通で読む
# - min-release-age= は npm 11.10+ が読む (単位: 日)
# - minimum-release-age= は pnpm 10.16+ が読む (単位: 分)
# 同じファイルに併記できる (各マネージャは自分が知らないキーを無視する)。
write_npmrc() {
  local home_dir="$1" user="$2"
  local f="$home_dir/.npmrc"
  backup_once "$f"
  strip_managed_block "$f"
  {
    echo "$MARK"
    echo "registry=$NPM_REGISTRY"
    echo "min-release-age=$NPM_MIN_RELEASE_AGE_DAYS"
    echo "minimum-release-age=$PNPM_MIN_RELEASE_AGE_MIN"
  } >> "$f"
  chown "$user":staff "$f"
  chmod 644 "$f"
}

# Yarn berry (v4.10+) の ~/.yarnrc.yml。
# classic (v1) はこのファイルを読まないので 3 日制限は適用されない (公式に機能なし)。
# berry の class 設定 (npmRegistryServer, npmMinimalAgeGate) を同居させる。
write_yarnrc_yml() {
  local home_dir="$1" user="$2"
  local f="$home_dir/.yarnrc.yml"
  backup_once "$f"
  strip_managed_block "$f"
  {
    echo "$MARK"
    echo "npmRegistryServer: \"${NPM_REGISTRY%/}\""
    echo "npmMinimalAgeGate: \"$YARN_MIN_AGE_GATE\""
  } >> "$f"
  chown "$user":staff "$f"
  chmod 644 "$f"
}

# Bun 1.3+ の ~/.bunfig.toml。[install] セクションを丸ごと管理ブロックとして書き込む。
write_bunfig() {
  local home_dir="$1" user="$2"
  local f="$home_dir/.bunfig.toml"
  backup_once "$f"
  strip_managed_block "$f"
  {
    echo ""
    echo "$MARK"
    echo "[install]"
    echo "registry = \"$NPM_REGISTRY\""
    echo "minimumReleaseAge = $BUN_MIN_RELEASE_AGE_SEC"
  } >> "$f"
  chown "$user":staff "$f"
  chmod 644 "$f"
}

# pip 用。pypi.flatt.tech/simple/ に向けるだけで 72h quarantine が自動適用される。
write_pip_conf() {
  local home_dir="$1" user="$2"
  local dir="$home_dir/.config/pip"
  local f="$dir/pip.conf"
  mkdir -p "$dir"
  chown "$user":staff "$home_dir/.config" "$dir" 2>/dev/null || true
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
  case "$user" in
    Shared|Guest|.localized|root|daemon|nobody) return 0 ;;
  esac
  [[ -d "$home_dir" ]] || return 0

  echo "==> applying Takumi Guard + minimumReleaseAge for $user ($home_dir)"
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
