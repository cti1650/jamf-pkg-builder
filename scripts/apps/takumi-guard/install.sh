#!/bin/bash
# Takumi Guard + 3 日 minimum-release-age を全ユーザに一括適用するスクリプト
# (Jamf Pro ポリシーから root で実行する想定)
#
# 二段構えで supply chain attack を防ぐ:
#   (1) registry を Flatt Security のプロキシに向ける (blocklist 防御)
#       - npm 系 (npm/yarn/pnpm/bun) → https://npm.flatt.tech/
#       - pip                          → https://pypi.flatt.tech/simple/  (72h quarantine 自動)
#   (2) 各パッケージマネージャ標準の "公開から N 日経っていないバージョンを除外" 機能で
#       3 日遅延をクライアント側からも強制する。
#
# 3 日 = 72 時間 = 4320 分 = 259200 秒。各マネージャで単位が違う:
#   - npm  (.npmrc)            : min-release-age=3                (日)        ※ npm CLI 11.10+
#   - pnpm (~/.npmrc など)      : minimum-release-age=4320         (分)        ※ pnpm 10.16+
#   - yarn (~/.yarnrc.yml)     : npmMinimalAgeGate: "3d"          (duration)  ※ Yarn berry 4.10+ のみ
#   - bun  (~/.bunfig.toml)     : minimumReleaseAge = 259200       (秒)        ※ Bun 1.3+
#
# 冪等性とユーザ設定の尊重:
#   - 既存ファイルがあれば .takumi-guard.bak を残す (監査用)
#   - 既存の "# managed-by: takumi-guard" ブロックは削除して書き直す
#   - ユーザが管理ブロック外に書いていた管理対象キー (registry= 等) は
#     "# disabled-by: takumi-guard " プレフィックスを付けてコメントアウトする
#     (削除はしない。uninstall で元に戻せる)
#   - TOML/INI セクションヘッダ ([install] / [global]) の重複を避けるため、
#     既存セクションがあればその中に追記、無ければ末尾に新規セクションとして追加する

set -euo pipefail

NPM_REGISTRY="https://npm.flatt.tech/"
PYPI_INDEX_URL="https://pypi.flatt.tech/simple/"

NPM_MIN_RELEASE_AGE_DAYS=3       # npm 11.10+
PNPM_MIN_RELEASE_AGE_MIN=4320    # pnpm 10.16+
YARN_MIN_AGE_GATE="3d"           # Yarn berry 4.10+
BUN_MIN_RELEASE_AGE_SEC=259200   # Bun 1.3+

MARK="# managed-by: takumi-guard (jamf-pkg-builder)"
DISABLE_PREFIX="# disabled-by: takumi-guard "

backup_once() {
  local f="$1"
  [[ -f "$f" && ! -f "${f}.takumi-guard.bak" ]] && cp "$f" "${f}.takumi-guard.bak"
}

# "# managed-by: takumi-guard" 行と続く管理ブロック (空行 or 別コメントに当たるまで) を削除。
strip_managed_block() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  /usr/bin/awk -v mark="managed-by: takumi-guard" '
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

# 引数で渡したキー名にマッチする「行頭の (空白を許す) 行」に DISABLE_PREFIX を付与する。
# 既に DISABLE_PREFIX が付いている行は二重処理しない。
# 例: disable_keys file 'registry[[:space:]]*=' 'min-release-age[[:space:]]*='
disable_keys() {
  local f="$1"; shift
  [[ -f "$f" ]] || return 0
  local pat
  for pat in "$@"; do
    /usr/bin/awk -v pre="$DISABLE_PREFIX" -v pat="$pat" '
      BEGIN { full = "^" pre }
      {
        if ($0 ~ full) { print; next }
        if ($0 ~ ("^[[:space:]]*" pat)) { print pre $0; next }
        print
      }
    ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
  done
}

# [section] ヘッダ重複を避けつつ管理ブロックを差し込む。
# 既存に [section] があれば: そのセクション末尾 (次の [...] の直前 or EOF) に MARK + 行群を挿入
# なければ:                    EOF に [section] + MARK + 行群を追加
# payload は awk -v で複数行を渡せないため一時ファイル経由で受け渡す。
inject_into_section() {
  local f="$1" section="$2"; shift 2
  local payload_file
  payload_file="$(mktemp)"
  printf '%s\n' "$MARK" "$@" > "$payload_file"

  if [[ -f "$f" ]] && /usr/bin/grep -q "^\[${section}\][[:space:]]*$" "$f"; then
    /usr/bin/awk -v sec="[${section}]" -v pf="$payload_file" '
      BEGIN {
        in_sec = 0; injected = 0; n = 0
        while ((getline line < pf) > 0) inj[++n] = line
        close(pf)
      }
      function flush_inj(   i) { for (i = 1; i <= n; i++) print inj[i] }
      {
        if (!in_sec && $0 ~ ("^\\" sec "[[:space:]]*$")) { print; in_sec = 1; next }
        if (in_sec && $0 ~ /^\[/) {
          flush_inj()
          injected = 1
          in_sec = 0
        }
        print
      }
      END {
        if (in_sec && !injected) flush_inj()
      }
    ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
  else
    {
      echo ""
      echo "[$section]"
      cat "$payload_file"
    } >> "$f"
  fi
  rm -f "$payload_file"
}

# ---- 各マネージャ用 writer ----

# .npmrc は npm / pnpm / yarn classic / bun が読む INI 形式。セクションヘッダなし、平置き。
write_npmrc() {
  local home_dir="$1" user="$2"
  local f="$home_dir/.npmrc"
  backup_once "$f"
  strip_managed_block "$f"
  disable_keys "$f" \
    'registry[[:space:]]*=' \
    'min-release-age[[:space:]]*=' \
    'minimum-release-age[[:space:]]*='
  {
    echo "$MARK"
    echo "registry=$NPM_REGISTRY"
    echo "min-release-age=$NPM_MIN_RELEASE_AGE_DAYS"
    echo "minimum-release-age=$PNPM_MIN_RELEASE_AGE_MIN"
  } >> "$f"
  chown "$user":staff "$f"
  chmod 644 "$f"
}

# Yarn berry の .yarnrc.yml はトップレベル YAML。インデントなしのキーを想定して disable する。
write_yarnrc_yml() {
  local home_dir="$1" user="$2"
  local f="$home_dir/.yarnrc.yml"
  backup_once "$f"
  strip_managed_block "$f"
  disable_keys "$f" \
    'npmRegistryServer[[:space:]]*:' \
    'npmMinimalAgeGate[[:space:]]*:'
  {
    echo "$MARK"
    echo "npmRegistryServer: \"${NPM_REGISTRY%/}\""
    echo "npmMinimalAgeGate: \"$YARN_MIN_AGE_GATE\""
  } >> "$f"
  chown "$user":staff "$f"
  chmod 644 "$f"
}

# bun の .bunfig.toml は [install] セクション内に書く。既存 [install] があればその中に挿入。
write_bunfig() {
  local home_dir="$1" user="$2"
  local f="$home_dir/.bunfig.toml"
  backup_once "$f"
  strip_managed_block "$f"
  # [install] セクション内の registry / minimumReleaseAge を disable する
  # (セクションを跨ぐ厳密判定は awk が複雑になるので、保守的に同名キーを全行 disable)
  disable_keys "$f" \
    'registry[[:space:]]*=' \
    'minimumReleaseAge[[:space:]]*='
  inject_into_section "$f" "install" \
    "registry = \"$NPM_REGISTRY\"" \
    "minimumReleaseAge = $BUN_MIN_RELEASE_AGE_SEC"
  chown "$user":staff "$f"
  chmod 644 "$f"
}

# pip の pip.conf は [global] セクションに index-url を書く。
write_pip_conf() {
  local home_dir="$1" user="$2"
  local dir="$home_dir/.config/pip"
  local f="$dir/pip.conf"
  mkdir -p "$dir"
  chown "$user":staff "$home_dir/.config" "$dir" 2>/dev/null || true
  backup_once "$f"
  [[ -f "$f" ]] && strip_managed_block "$f"
  [[ -f "$f" ]] && disable_keys "$f" 'index-url[[:space:]]*='
  inject_into_section "$f" "global" \
    "index-url = $PYPI_INDEX_URL"
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
