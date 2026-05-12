# CLAUDE.md

このファイルは Claude Code がこのリポジトリで作業するときに常時参照するプロジェクト固有のルール集。

## このリポジトリは何か

GitHub Actions の macOS-15 (arm64) ランナー上で macOS アプリのインストーラを取得し、Jamf Pro / iru などの MDM で配信するための `.pkg` を生成・事前検証する仕組み。Jamf Pro そのものはブラックボックスとして扱い、「MDM に渡す材料の品質」だけを責任範囲とする。

主な構成:

- [apps/](../apps/) — アプリ定義 YAML
- [scripts/core/](../scripts/core/) — 検証スクリプト本体
- [scripts/apps/<name>/](../scripts/apps/) — 各アプリの EA / uninstall / detect スクリプト
- [.github/workflows/](../.github/workflows/) — macOS の build-and-verify 系 + ubuntu の lint

## アプリ定義スキーマの主要ルール

詳細は [docs/yaml-schema.md](../docs/yaml-schema.md) 参照。lint で機械的に検証されるルール:

| フィールド | 許可される値 |
|---|---|
| `installer.type` | `pkg`, `dmg`, `script_based` |
| `uninstall.type` | `pkg`, `script` |

加えて:

- `installer.type: dmg` + `repackage: true` のとき `installer.app_name` 必須
- `uninstall.type: pkg` のとき `uninstall.pkg_id` 必須
- `uninstall.type: script` のとき `uninstall.script` 必須かつファイル存在チェック
- `detect.app_path` か `detect.ea_script` のどちらかは必須
- `download.url` / `download.file` は `script_based` 以外で必須

## URL 固定性の分類 (採用判断の基準)

| 等級 | 例 | 判断 |
|---|---|---|
| **A 級** (latest 固定 URL) | `dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg`、`zoom.us/client/latest/ZoomInstallerIT.pkg`、`1.1.1.1/mac/install` | そのまま採用 |
| **B 級** (GitHub Releases latest API) | `github.com/owner/repo/releases/latest/download/<asset>` | script_based で採用 |
| **C 級** (バージョン入り URL のみ) | `https://example.com/foo-1.2.3.pkg` | **基本不採用**。どうしても必要なら script_based + クローラ |

URL HEAD で 200 が返るかは PR 前に `curl -sIL <url>` で確認する。

## やってはいけないこと

- **Mac App Store 配信アプリを pkg 化しない**（Apps & Books / VPP の方が筋が良い）
- **PKG への署名・公証付与は CI でやらない**（Jamf Pro / iru 経由で配るので不要、かつ secret 管理が増える）
- **per-user installer をそのまま採用しない**（root で実行されるため動かない）
- **商用ライセンス必須のアプリ** を無断で追加しない

## CI

### lint (`.github/workflows/lint.yml`)

ubuntu-latest で 4 ジョブ並列:

| ジョブ | 内容 |
|---|---|
| shellcheck | `scripts/**/*.sh` を shellcheck |
| apps-schema | `scripts/check-apps-schema.sh` で apps/*.yml 検証 |
| choice-list | `scripts/check-choice-list.sh` で workflow choice の整合性検証 |
| actionlint | workflow YAML の lint |

### build-and-verify (`.github/workflows/build-and-verify-pkg.yml`)

`workflow_dispatch` 専用。手動でアプリを 1 つ選んで実行。

### build-and-verify-apps (`.github/workflows/build-and-verify-pkg-apps.yml`)

push / PR で発火。`apps/<name>.yml` または `scripts/apps/<name>/**` が変更されたアプリだけを matrix 並列で実行。`scripts/core/**` の変更時は全アプリ実行。

## 命名規則

- `apps/<name>.yml` の `<name>` は kebab-case
- `scripts/apps/<name>/` の `<name>` は YAML basename と一致させる
- `apps/<name>.yml` を追加したら `.github/workflows/build-and-verify-pkg.yml` の choice options にもアルファベット順で追加する（lint で検証）

## ローカル確認コマンド

```bash
brew install yq shellcheck   # 初回のみ
./scripts/dev-check.sh        # shellcheck + apps-schema + choice-list を一括実行
```

## コミット規約

`feat:`, `fix:`, `chore:`, `ci:`, `docs:` の prefix。日本語本文 OK。`#PR番号` は GitHub が自動付与するので手動で入れない。
