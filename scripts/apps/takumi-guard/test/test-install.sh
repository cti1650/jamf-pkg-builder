#!/bin/bash
# Takumi Guard install.sh / uninstall.sh のユニットテスト。
# Linux (GitHub Actions ubuntu-latest) でも macOS でも動くように POSIX awk/grep のみで書く。
#
# 使い方:
#   ./scripts/apps/takumi-guard/test/test-install.sh
#
# 動作:
#   - install.sh / uninstall.sh を source して関数を直接呼ぶ (main は BASH_SOURCE ガードでスキップ)
#   - fake home を mktemp で作り、各 writer を呼んで出力を grep でアサート
#   - 9 ケース実行、最後に pass/fail 集計

set -u  # set -e は使わない (アサーションが失敗しても次のテストへ進めるため)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../install.sh"
UNINSTALL_SH="$SCRIPT_DIR/../uninstall.sh"

if [[ ! -f "$INSTALL_SH" ]]; then echo "FATAL: $INSTALL_SH not found" >&2; exit 2; fi
if [[ ! -f "$UNINSTALL_SH" ]]; then echo "FATAL: $UNINSTALL_SH not found" >&2; exit 2; fi

# install.sh / uninstall.sh は内部で `chown $user:staff` を呼ぶ。テスト中は root でないので失敗するが、
# install.sh 側に `|| true` が付いているので問題ない。staff グループが Linux に存在しないため
# stderr を消す目的で、テスト中だけ chown を no-op に差し替える。
# (chown は install.sh 側から間接的に呼ばれるので shellcheck は到達不能と判定する)
# shellcheck disable=SC2317
chown() { :; }
export -f chown

# install.sh / uninstall.sh は冒頭で `set -euo pipefail` するので、source するたびに
# テスト用に解除する必要がある (アサーション失敗で grep が exit 1 を返してもテストランナーが
# 止まらないようにするため)。
relax_strict() { set +e; set +u; set +o pipefail; }

# shellcheck source=/dev/null
source "$INSTALL_SH"
relax_strict

PASS=0
FAIL=0
CURRENT_TC=""

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }

assert_file_exists() {
  local f="$1" desc="$2"
  if [[ -f "$f" ]]; then
    PASS=$((PASS + 1)); printf '    %s %s\n' "$(green ✓)" "$desc"
  else
    FAIL=$((FAIL + 1)); printf '    %s %s (file missing: %s)\n' "$(red ✗)" "$desc" "$f"
  fi
}

assert_grep() {
  local f="$1" pattern="$2" desc="$3"
  if [[ -f "$f" ]] && /usr/bin/grep -qE -- "$pattern" "$f" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '    %s %s\n' "$(green ✓)" "$desc"
  else
    FAIL=$((FAIL + 1)); printf '    %s %s\n' "$(red ✗)" "$desc"
    printf '      file: %s\n' "$f"
    printf '      pattern: %s\n' "$pattern"
    if [[ -f "$f" ]]; then
      printf '      ----- file content -----\n'
      /usr/bin/awk '{print "      | " $0}' "$f"
      printf '      ------------------------\n'
    fi
  fi
}

assert_not_grep() {
  local f="$1" pattern="$2" desc="$3"
  if [[ ! -f "$f" ]] || ! /usr/bin/grep -qE -- "$pattern" "$f" 2>/dev/null; then
    PASS=$((PASS + 1)); printf '    %s %s\n' "$(green ✓)" "$desc"
  else
    FAIL=$((FAIL + 1)); printf '    %s %s (unexpectedly matched)\n' "$(red ✗)" "$desc"
    printf '      file: %s\n' "$f"
    printf '      pattern: %s\n' "$pattern"
  fi
}

assert_equal() {
  local actual="$1" expected="$2" desc="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); printf '    %s %s\n' "$(green ✓)" "$desc"
  else
    FAIL=$((FAIL + 1)); printf '    %s %s\n' "$(red ✗)" "$desc"
    printf '      expected: %q\n' "$expected"
    printf '      actual:   %q\n' "$actual"
  fi
}

tc() {
  CURRENT_TC="$1"
  printf '\n[%s]\n' "$CURRENT_TC"
}

new_fake_home() {
  mktemp -d
}

# ===== テストケース =====

tc "TC1: 空 home → 全 writer が 7 ファイルを生成し MARK 行を含む"
{
  H=$(new_fake_home)
  apply_for_user "$H" >/dev/null 2>&1
  assert_file_exists "$H/.npmrc"                                              ".npmrc が作られる"
  assert_file_exists "$H/.yarnrc.yml"                                         ".yarnrc.yml が作られる"
  assert_file_exists "$H/.bunfig.toml"                                        ".bunfig.toml が作られる"
  assert_file_exists "$H/Library/Application Support/pip/pip.conf"            "pip.conf (Library 配下) が作られる"
  assert_file_exists "$H/.config/uv/uv.toml"                                  "uv.toml が作られる"
  assert_file_exists "$H/Library/Application Support/pypoetry/config.toml"    "poetry config.toml が作られる"
  assert_file_exists "$H/.bundle/config"                                      ".bundle/config が作られる"
  assert_grep "$H/.npmrc"                                              'managed-by: takumi-guard'  ".npmrc に MARK 行"
  assert_grep "$H/.bundle/config"                                      'managed-by: takumi-guard'  ".bundle/config に MARK 行"
  rm -rf "$H"
}

tc "TC2: 各設定値が正しく書き込まれる"
{
  H=$(new_fake_home)
  apply_for_user "$H" >/dev/null 2>&1
  assert_grep "$H/.npmrc"           '^registry=https://npm\.flatt\.tech/'            "npm registry URL"
  assert_grep "$H/.npmrc"           '^min-release-age=3'                             "npm min-release-age=3 (日)"
  assert_grep "$H/.npmrc"           '^minimum-release-age=4320'                      "pnpm minimum-release-age=4320 (分)"
  assert_grep "$H/.yarnrc.yml"      'npmRegistryServer:'                             "yarn npmRegistryServer"
  assert_grep "$H/.yarnrc.yml"      'npmMinimalAgeGate: "3d"'                        "yarn npmMinimalAgeGate=3d"
  assert_grep "$H/.bunfig.toml"     'minimumReleaseAge = 259200'                     "bun minimumReleaseAge=259200 (秒)"
  assert_grep "$H/.bunfig.toml"     '^\[install\]'                                   "bun [install] section"
  assert_grep "$H/Library/Application Support/pip/pip.conf" '^\[global\]'            "pip [global] section"
  assert_grep "$H/Library/Application Support/pip/pip.conf" 'index-url = https://pypi\.flatt\.tech/simple/'  "pip index-url"
  assert_grep "$H/.config/uv/uv.toml" 'exclude-newer = "3 days"'                     "uv exclude-newer=3 days"
  assert_grep "$H/.config/uv/uv.toml" 'url = "https://pypi\.flatt\.tech/simple/"'    "uv [[index]] url"
  assert_grep "$H/.config/uv/uv.toml" 'default = true'                               "uv [[index]] default=true"
  assert_grep "$H/Library/Application Support/pypoetry/config.toml" 'min-release-age = 3'  "poetry solver.min-release-age=3"
  assert_grep "$H/Library/Application Support/pypoetry/config.toml" '^\[solver\]'    "poetry [solver] section"
  assert_grep "$H/.bundle/config"   'BUNDLE_MIRROR__HTTPS://RUBYGEMS__ORG/: "https://rubygems\.flatt\.tech/"'  "bundle mirror key+value"
  rm -rf "$H"
}

tc "TC3: 既存設定がブロック外にある場合 disabled-by プレフィックスでコメントアウトされる"
{
  H=$(new_fake_home)
  cat > "$H/.npmrc" <<'EOF'
email=foo@example.com
registry=https://registry.npmjs.org/
cache=/tmp/cache
EOF
  apply_for_user "$H" >/dev/null 2>&1
  assert_grep     "$H/.npmrc" '^# disabled-by: takumi-guard registry=https://registry\.npmjs\.org/' "既存 registry= が disabled-by でコメントアウト"
  assert_grep     "$H/.npmrc" '^email=foo@example\.com'                       "管理対象外の email= はそのまま残る"
  assert_grep     "$H/.npmrc" '^cache=/tmp/cache'                             "管理対象外の cache= はそのまま残る"
  rm -rf "$H"
}

tc "TC4: 既存 [global] セクションがあれば pip.conf はそのセクション内に挿入される (重複なし)"
{
  H=$(new_fake_home)
  mkdir -p "$H/Library/Application Support/pip"
  cat > "$H/Library/Application Support/pip/pip.conf" <<'EOF'
[global]
timeout = 60
EOF
  apply_for_user "$H" >/dev/null 2>&1
  GLOBAL_COUNT=$(/usr/bin/grep -c '^\[global\]' "$H/Library/Application Support/pip/pip.conf")
  assert_equal  "$GLOBAL_COUNT" "1"  "[global] section が 1 個だけ (重複なし)"
  assert_grep   "$H/Library/Application Support/pip/pip.conf" '^timeout = 60' "既存 timeout 値が保持される"
  assert_grep   "$H/Library/Application Support/pip/pip.conf" 'index-url = https://pypi\.flatt\.tech/simple/' "新規 index-url 行が追加"
  rm -rf "$H"
}

tc "TC5: 既存 [install] セクションがあれば bunfig.toml はそのセクション内に挿入される (TOML 重複なし)"
{
  H=$(new_fake_home)
  cat > "$H/.bunfig.toml" <<'EOF'
[run]
hot = true

[install]
production = false
EOF
  apply_for_user "$H" >/dev/null 2>&1
  INSTALL_COUNT=$(/usr/bin/grep -c '^\[install\]' "$H/.bunfig.toml")
  assert_equal "$INSTALL_COUNT" "1"   "[install] section が 1 個だけ (重複なし)"
  assert_grep  "$H/.bunfig.toml" '^production = false'                  "既存 production が保持される"
  assert_grep  "$H/.bunfig.toml" '^registry = "https://npm\.flatt\.tech/"'  "新規 registry が同じ [install] 内に追加"
  rm -rf "$H"
}

tc "TC6: install 2 回実行しても冪等 (MARK ブロックが 1 個だけ)"
{
  H=$(new_fake_home)
  apply_for_user "$H" >/dev/null 2>&1
  apply_for_user "$H" >/dev/null 2>&1
  MARK_NPM=$(/usr/bin/grep -c 'managed-by: takumi-guard' "$H/.npmrc")
  MARK_PIP=$(/usr/bin/grep -c 'managed-by: takumi-guard' "$H/Library/Application Support/pip/pip.conf")
  MARK_BUNDLE=$(/usr/bin/grep -c 'managed-by: takumi-guard' "$H/.bundle/config")
  assert_equal "$MARK_NPM" "1"    ".npmrc の MARK 行が 1 個だけ"
  assert_equal "$MARK_PIP" "1"    "pip.conf の MARK 行が 1 個だけ"
  assert_equal "$MARK_BUNDLE" "1" ".bundle/config の MARK 行が 1 個だけ"
  rm -rf "$H"
}

tc "TC7: uninstall → MARK ブロック削除 + disabled-by プレフィックス剥がし"
{
  H=$(new_fake_home)
  cat > "$H/.npmrc" <<'EOF'
email=foo@example.com
registry=https://registry.npmjs.org/
EOF
  apply_for_user "$H" >/dev/null 2>&1
  # uninstall の関数だけ source
  # shellcheck source=/dev/null
  source "$UNINSTALL_SH"
  relax_strict
  revert_for_user "$H" "strip"
  assert_not_grep "$H/.npmrc"  'managed-by: takumi-guard'  ".npmrc から MARK 行が消える"
  assert_not_grep "$H/.npmrc"  'disabled-by: takumi-guard' ".npmrc から disabled-by プレフィックスが剥がれる"
  assert_grep     "$H/.npmrc"  '^registry=https://registry\.npmjs\.org/'  ".npmrc の既存 registry= が復活する"
  assert_grep     "$H/.npmrc"  '^email=foo@example\.com'   ".npmrc の email= も残っている"
  rm -rf "$H"
}

tc "TC8: 公式 setup.sh と同じ命名で世代保持バックアップが作られる (再 install ごとに新規生成)"
{
  H=$(new_fake_home)
  cat > "$H/.npmrc" <<'EOF'
ORIGINAL_V1=true
EOF
  apply_for_user "$H" >/dev/null 2>&1
  # 1 回目 install で `.npmrc-backup-YYYYMMDDhhmmss[-N]` が 1 個できる
  BAK_COUNT_1=$(/usr/bin/find "$H" -maxdepth 1 -name '.npmrc-backup-*' 2>/dev/null | wc -l | tr -d ' ')
  assert_equal "$BAK_COUNT_1" "1" "1 回目 install で世代バックアップが 1 個できる"
  # バックアップ名が公式仕様 `-backup-YYYYMMDDhhmmss` 形式 (14 桁のタイムスタンプ、衝突時は -N サフィックス)
  BAK1=$(/usr/bin/find "$H" -maxdepth 1 -name '.npmrc-backup-*' | head -1)
  BAK1_BASE=$(basename "$BAK1")
  if [[ "$BAK1_BASE" =~ ^\.npmrc-backup-[0-9]{14}(-[0-9]+)?$ ]]; then
    PASS=$((PASS + 1)); printf '    %s 命名規則 .npmrc-backup-YYYYMMDDhhmmss[-N] に一致 (%s)\n' "$(green ✓)" "$BAK1_BASE"
  else
    FAIL=$((FAIL + 1)); printf '    %s 命名規則 .npmrc-backup-YYYYMMDDhhmmss[-N] に一致しない (%s)\n' "$(red ✗)" "$BAK1_BASE"
  fi
  assert_grep "$BAK1" '^ORIGINAL_V1=true' "1 回目バックアップに install 前の内容が保存される"

  # 2 回目 install (内容を変えて再実行) で世代が追加される
  apply_for_user "$H" >/dev/null 2>&1
  BAK_COUNT_2=$(/usr/bin/find "$H" -maxdepth 1 -name '.npmrc-backup-*' 2>/dev/null | wc -l | tr -d ' ')
  # 2 回目実行時点ではすでに registry= 等が書き込まれた状態がバックアップされる
  # ただし同じ秒の場合は -1 サフィックス付きで衝突回避するため、必ず増える
  if [[ "$BAK_COUNT_2" -ge 2 ]]; then
    PASS=$((PASS + 1)); printf '    %s 2 回目 install で世代バックアップが追加される (count: %d)\n' "$(green ✓)" "$BAK_COUNT_2"
  else
    FAIL=$((FAIL + 1)); printf '    %s 2 回目 install で世代が追加されない (count: %d)\n' "$(red ✗)" "$BAK_COUNT_2"
  fi
  # 1 回目のバックアップ内容は維持されていること (世代保持)
  assert_grep "$BAK1" '^ORIGINAL_V1=true' "1 回目バックアップの内容は維持される (世代保持)"
  rm -rf "$H"
}

tc "TC10: uninstall --restore-bak で最新タイムスタンプのバックアップから復元される"
{
  H=$(new_fake_home)
  cat > "$H/.npmrc" <<'EOF'
ORIGINAL=true
EOF
  apply_for_user "$H" >/dev/null 2>&1
  # 異なるタイムスタンプの旧バックアップを偽装作成 (より古い時刻)
  echo "VERY_OLD=true" > "$H/.npmrc-backup-19990101000000"
  # source uninstall して revert を bak モードで実行
  # shellcheck source=/dev/null
  source "$UNINSTALL_SH"
  relax_strict
  revert_for_user "$H" "bak"
  # 最新タイムスタンプの内容 (= 直前 install 前の .npmrc = ORIGINAL=true) が戻ること
  assert_grep      "$H/.npmrc" '^ORIGINAL=true'  "最新タイムスタンプから復元される"
  assert_not_grep  "$H/.npmrc" '^VERY_OLD=true'  "古いタイムスタンプは選ばれない"
  # バックアップ自体は残る (監査用)
  assert_file_exists "$H/.npmrc-backup-19990101000000" "復元しても古いバックアップは残る"
  rm -rf "$H"
}

tc "TC9: 古い ~/.config/pip/pip.conf に MARK ブロックがある場合、移行クリーンアップで剥がされる"
{
  H=$(new_fake_home)
  mkdir -p "$H/.config/pip"
  cat > "$H/.config/pip/pip.conf" <<'EOF'
[global]
timeout = 30
# managed-by: takumi-guard (jamf-pkg-builder)
index-url = https://pypi.flatt.tech/simple/
EOF
  apply_for_user "$H" >/dev/null 2>&1
  assert_not_grep "$H/.config/pip/pip.conf"  'managed-by: takumi-guard' "旧パスから MARK ブロックが除去される"
  assert_grep     "$H/.config/pip/pip.conf"  '^\[global\]'              "旧パスの [global] section は残る"
  assert_grep     "$H/.config/pip/pip.conf"  '^timeout = 30'            "旧パスの timeout は残る"
  assert_grep     "$H/Library/Application Support/pip/pip.conf"  'managed-by: takumi-guard'  "新パスに MARK 行が書かれる"
  rm -rf "$H"
}

# ===== 集計 =====

printf '\n========================================\n'
printf 'Pass: %d  Fail: %d  Total: %d\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
printf '========================================\n'

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
