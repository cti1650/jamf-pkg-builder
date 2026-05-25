# Takumi Guard を Jamf Pro で配信する手順

[Takumi Guard](https://shisho.dev/docs/t/guard/) (GMO Flatt Security) は実体のあるアプリではなく **レジストリプロキシ SaaS**。各パッケージマネージャの設定ファイルを Flatt Security のエンドポイントに向けることで導入する。本リポジトリでは `apps/takumi-guard.yml` を `installer.type: script_based` で定義し、設定ファイル一括書き換えスクリプト一式を `scripts/apps/takumi-guard/` 配下に置いている。

## ポリシー (Policy) を使う — 構成プロファイルは不可

| 方式 | 採否 | 理由 |
|---|---|---|
| **ポリシー (Policy)** | ✅ 採用 | Script ペイロードで `install.sh` を root 実行できる。任意パスの設定ファイル書き換えはこの方式しか取れない |
| **構成プロファイル (Configuration Profile)** | ❌ 不可 | Custom Settings ペイロードは「対象アプリが `defaults` 経由で読む設定」しか配信できない。`~/.npmrc` 等の任意パスのテキストファイルは作れず、npm/pip/uv/poetry も `defaults` 経由で設定を読まない |

## 配信構成の全体像

```
┌────────────────────────────────────────────────────────────────┐
│ Jamf Pro                                                       │
│                                                                │
│  Scripts            EA              Smart Group     Policy     │
│  ┌──────────┐      ┌─────┐         ┌──────────┐    ┌────────┐ │
│  │install.sh│  ←   │ea.sh│  ──→    │未適用機  │ ←  │install │ │
│  └──────────┘      └─────┘         └──────────┘    └────────┘ │
│  ┌────────────┐                                    ┌────────┐ │
│  │uninstall.sh│  ───────────────────────────  ←    │uninstal│ │
│  └────────────┘                                    └────────┘ │
└────────────────────────────────────────────────────────────────┘
```

## 事前準備 — Jamf Pro 側の登録物

### 1. Scripts に install / uninstall を登録

**Computer Management → Scripts → New**

| Script | Settings |
|---|---|
| `takumi-guard-install` | Script: `scripts/apps/takumi-guard/install.sh` の中身を貼り付け。Priority: After。Parameter は使用しない |
| `takumi-guard-uninstall` | Script: `scripts/apps/takumi-guard/uninstall.sh` の中身を貼り付け。Priority: Before。`$4` に `--restore-bak` を渡せば完全復元モードで動作 |

> uninstall.sh は `--restore-bak` 引数で **タイムスタンプ付きバックアップ (`<元ファイル名>-backup-<YYYYMMDDhhmmss>`)** の最新世代から install 前状態に復元する (公式 Takumi Guard setup.sh と同じ命名規則)。Jamf の Script Parameter ($4 以降) を渡せるようにしておくと便利。

### 2. Extension Attribute (EA) に ea.sh を登録

**Computer Management → Extension Attributes → New**

| Field | Value |
|---|---|
| Display Name | `Takumi Guard Applied User Count` |
| Data Type | `Integer` |
| Inventory Display | `Extension Attributes` |
| Input Type | `Script` |
| Script | `scripts/apps/takumi-guard/ea.sh` の中身を貼り付け |

→ Mac ごとに「Takumi Guard 設定が書かれているユーザ数」を整数で返す。0 なら未適用。

### 3. Smart Computer Group を 2 つ作る

**Computers → Smart Computer Groups → New**

| Group | Criteria |
|---|---|
| `Takumi Guard - Not Applied` | `Takumi Guard Applied User Count` `is` `0` |
| `Takumi Guard - Applied` | `Takumi Guard Applied User Count` `more than` `0` |

## Install ポリシーを作る

**Computers → Policies → New**

| Field | Value |
|---|---|
| Display Name | `Deploy Takumi Guard registry config` |
| Trigger | `Recurring Check-in` (推奨)。即時に流すなら `Enrollment Complete` を追加で有効化 |
| **Execution Frequency** | **`Ongoing`** ⚠️ 重要 |
| Scope | `Takumi Guard - Not Applied` Smart Group |
| Payload: Scripts | `takumi-guard-install` を追加 |
| Payload: Maintenance → Update Inventory | ✅ チェック (EA を最新化して Smart Group メンバシップが更新される) |

> ⚠️ **`Ongoing`** にする理由: ユーザがファイルを消した・上書きされたケースでも次の Check-in で再適用される。`Once per computer` だと一度きりで再適用されず、ドリフトに気付けない。install.sh は冪等なので `Ongoing` で問題なし。

## Uninstall ポリシーを作る (任意だが推奨)

**Computers → Policies → New**

| Field | Value |
|---|---|
| Display Name | `Uninstall Takumi Guard registry config` |
| Trigger | `Custom`. Custom Event Name: `takumi-guard-uninstall` |
| Execution Frequency | `Ongoing` |
| Scope | `Takumi Guard - Applied` Smart Group |
| Payload: Scripts | `takumi-guard-uninstall`。完全復元したい場合は Parameter 4 に `--restore-bak` |
| Payload: Maintenance → Update Inventory | ✅ |

→ オペレータ側で `sudo jamf policy -event takumi-guard-uninstall` を叩けば任意のタイミングで巻き戻せる。

## 動作確認

### 配信直後

1. 対象 Mac で `sudo jamf policy` を実行 (or `Recurring Check-in` を待つ)
2. 以下 7 ファイルに `# managed-by: takumi-guard (jamf-pkg-builder)` 行があることを確認:
   - `~/.npmrc`
   - `~/.yarnrc.yml`
   - `~/.bunfig.toml`
   - `~/Library/Application Support/pip/pip.conf`
   - `~/.config/uv/uv.toml`
   - `~/Library/Application Support/pypoetry/config.toml`
   - `~/.bundle/config`
3. `npm config get registry` が `https://npm.flatt.tech/` を返すこと
4. `pip config list` が `global.index-url='https://pypi.flatt.tech/simple/'` を含むこと
5. `bundle config get mirror.https://rubygems.org` が `https://rubygems.flatt.tech/` を返すこと
6. `npm install lodash` 等の通常パッケージは動き、`npm install <最近 3 日以内に公開されたバージョン>` が拒否されること

### 公式検証パッケージで blocklist が効くかを確認

```bash
# npm
npm install @panda-guard/test-malicious  # → 403 Forbidden が返れば設定 OK

# Ruby (Bundler)
cd $(mktemp -d) && \
  printf 'source "https://rubygems.org"\ngem "hola-takumi", "0.1.0"\n' > Gemfile && \
  bundle install  # → "Could not find gem" が返れば設定 OK
```

### Jamf Pro 側

1. 対象 Mac の Inventory を更新 (Update Inventory)
2. Extension Attribute `Takumi Guard Applied User Count` が `1` 以上になっていること
3. Smart Group `Takumi Guard - Applied` にメンバとして入っていること

## 既知の制限事項

| 制限 | 対応 |
|---|---|
| Poetry の **index プロキシ化はグローバル設定不可** (Poetry 公式仕様) | プロジェクト毎に `poetry source add --priority=primary takumi https://pypi.flatt.tech/simple/` を別途案内。配信されるのは `solver.min-release-age = 3` のみ |
| **Ruby (Bundler/RubyGems)** 側に N 日遅延機能が公式に未実装 (2026-05 時点 / [rubygems#9113](https://github.com/ruby/rubygems/discussions/9113) 議論中) | `~/.bundle/config` には registry mirror のみ配布。3 日遅延が必要なら Dependabot の `cooldown.days: 3` を `.github/dependabot.yml` で併用 |
| **Yarn classic (v1)** は 3 日制限の公式機能なし | 影響を受ける開発者には Yarn berry 4.10+ への移行を推奨 |
| 各マネージャの **最小バージョン** が新しい (npm 11.10+ / pnpm 10.16+ / yarn 4.10+ / bun 1.3+ / Poetry 2.4+) | EA で `npm -v` 等を併せて取得する拡張版を別途検討 |
| **bun** は Takumi Guard 公式サポート対象外 | registry URL を向ければ動く想定だが Flatt Security 公式の保証はない |
| **Anonymous tier 前提**。組織トークン (`tg_org_...`) は未対応 | 組織契約に切り替える場合は `install.sh` の URL を `https://<token>@npm.flatt.tech/` 形式にする改修が必要 |
| uv の既存設定に `default = true` index があると競合 | install 時に warning を出すのみ。手動対応してもらう |

## トラブルシュート

| 症状 | 確認・対処 |
|---|---|
| EA が 0 のまま | install.sh の Jamf 実行ログを確認 (`/var/log/jamf.log`)。`must run as root` で落ちていないか / `mkdir -p` が刺さっていないか |
| `~/.npmrc` の `registry=` が古いままになっている | ユーザが管理ブロック外で独自 `registry=` を書いていた場合は `# disabled-by: takumi-guard ` でコメントアウトされているはず。手動で書き換えていれば優先される |
| install 後の `[install] / [global] / [solver]` セクションが重複してパースエラー | `inject_into_section` の同セクション挿入ロジックが効いていないケース。該当ファイルの内容を共有し issue 化 |
| 完全に元に戻したい | uninstall ポリシーを Parameter 4 に `--restore-bak` を渡して実行。`<元ファイル名>-backup-<YYYYMMDDhhmmss>` の最新世代から install 直前状態が復元される (バックアップ自体は監査用に残る) |
| バックアップが溜まりすぎてディスクを圧迫 | install は **毎回新規にバックアップを生成する** (公式 setup.sh と同じ仕様)。`Recurring Check-in` ポリシーで `Ongoing` 実行している場合、世代が単調増加する。古い世代を定期削除したい場合は別途クリーンアップ運用が必要 (例: `find ~ -name '*-backup-*' -mtime +30 -delete`) |

## 関連

- [apps/takumi-guard.yml](../apps/takumi-guard.yml) — アプリ定義
- [scripts/apps/takumi-guard/](../scripts/apps/takumi-guard/) — install / uninstall / detect / ea スクリプト
- [Takumi Guard 公式ドキュメント](https://shisho.dev/docs/t/guard/)
- [Takumi Guard PyPI quarantine リリースノート](https://shisho.dev/docs/r/202603-takumi-guard-pypi-quarantine/)
