#!/bin/bash
# Jamf Pro Extension Attribute (補助): Takumi Guard を **手動で** 設定したユーザ数を返す。
#
# 「MDM 経由で配信した」場合は `# managed-by: takumi-guard` MARK 行が付くので
# こちらにはカウントしない (MDM 優先)。
# 「ユーザが手で `npm config set registry https://npm.flatt.tech/` 等を実行した」場合は
# endpoint (flatt.tech) を含むが MARK 行が無い状態になる — そういうユーザをカウントする。
#
# 値の使い分け:
#   - MDM 用 EA (ea.sh) = 0 かつ Manual = 1 以上  →  MDM 管理外だが本人が対策済み
#   - MDM 用 EA = 1 以上                        →  MDM 配信成功 (Manual はゼロカウント)
#   - 両方 0                                  →  完全に未対策 (リスクあり、要配信)
set -euo pipefail

count=0
for h in /Users/*; do
  [[ -d "$h" ]] || continue
  user_mdm=false
  user_manual=false
  for f in \
    "$h/.npmrc" \
    "$h/.yarnrc.yml" \
    "$h/.bunfig.toml" \
    "$h/Library/Application Support/pip/pip.conf" \
    "$h/.config/pip/pip.conf" \
    "$h/.config/uv/uv.toml" \
    "$h/Library/Application Support/pypoetry/config.toml" \
    "$h/.bundle/config"; do
    [[ -f "$f" ]] || continue
    if /usr/bin/grep -q "managed-by: takumi-guard" "$f" 2>/dev/null; then
      user_mdm=true
      break  # MDM 判定されたら以降の判定は不要 (MDM 優先)
    fi
    if /usr/bin/grep -q "flatt\.tech" "$f" 2>/dev/null; then
      user_manual=true
    fi
  done
  # MDM 優先: MDM 判定されたユーザは manual にカウントしない
  if ! $user_mdm && $user_manual; then
    count=$((count + 1))
  fi
done

echo "<result>$count</result>"
