# jamf-pkg-builder

GitHub Actions の macOS-15 (arm64) ランナー上で macOS アプリのインストーラを取得し、Jamf Pro / iru などの MDM で配信するための `.pkg` を生成・事前検証するリポジトリ。

ローカル端末を使わず、MDM に登録する **前** までの確認を CI で完結させることを目的とする。署名・公証は付与しない（MDM 配布前提）。

## できること

- macOS アプリの `.pkg` を GitHub Actions 上で生成（DMG は `pkgbuild` で再パッケージ）
- 同じランナー内で **インストール → 検出 → アンインストール → 残留チェック** までを自動検証
- Jamf Pro Extension Attribute 用スクリプトの動作確認 (`<result>...</result>` 出力)
- 12 ステップの結果を step summary とログにまとめて出力
- Artifact として `.pkg` ファイル / EA スクリプト / 実行ログを 7 日間保管

## 何をしないか

- Jamf Pro / iru への自動アップロード・配布
- スコープ / 割り当ての検証
- アプリのバージョン管理
- 署名・公証（Notarization）の付与

## 対応アプリ

| アプリ | インストーラ | 検出 | URL |
|---|---|---|---|
| Google Chrome | DMG → PKG | app_path + min_version | `dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg` |
| Slack | DMG → PKG | app_path + min_version | `slack.com/ssb/download-osx-universal` |
| Cloudflare WARP | PKG | EA スクリプト (`warp-cli status`) | `1.1.1.1/mac/install` |
| Zoom Workplace | PKG | app_path + min_version | `zoom.us/client/latest/ZoomInstallerIT.pkg` |

## 使い方

### 単体ビルド（手動）

GitHub Actions の `build-and-verify-pkg` を `workflow_dispatch` で起動し、アプリを 1 つ選択する。Artifact から `.pkg` と EA スクリプトを取得して Jamf Pro / iru にアップロードする。

### 全アプリ並列ビルド

`build-and-verify-pkg-apps` は `apps/` または `scripts/` の変更 push / PR で自動発火する。`apps/<name>.yml` または `scripts/apps/<name>/**` が変更されたアプリだけを matrix 並列で実行する（`scripts/core/**` 変更時は全アプリ）。

## アプリを追加する

1. `apps/<name>.yml` を新規作成（スキーマは [docs/yaml-schema.md](docs/yaml-schema.md)）
2. 必要に応じて `scripts/apps/<name>/ea.sh`, `uninstall.sh`, `detect.sh` を追加
3. `.github/workflows/build-and-verify-pkg.yml` の `inputs.app.options` にアルファベット順で `<name>` を追加
4. `./scripts/dev-check.sh` でローカル lint を通す
5. PR を作る（push で `build-and-verify-pkg-apps` がそのアプリだけ走る）

## ローカル確認

```bash
brew install yq shellcheck
./scripts/dev-check.sh
```

`build-and-verify.sh` 自体は macOS でしか動かない（`installer`, `pkgutil`, `hdiutil` 依存）。

## ディレクトリ構成

```
jamf-pkg-builder/
├── .github/workflows/
│   ├── build-and-verify-pkg.yml       # 単体テスト（アプリ選択式）
│   ├── build-and-verify-pkg-apps.yml  # 全アプリ並列テスト
│   └── lint.yml                       # shellcheck + schema + actionlint
├── apps/                              # アプリ定義 YAML
├── scripts/
│   ├── core/build-and-verify.sh       # 12 ステップ検証
│   ├── check-apps-schema.sh           # YAML スキーマ lint
│   ├── check-choice-list.sh           # workflow choice 整合性 lint
│   ├── dev-check.sh                   # ローカル lint まとめ実行
│   └── apps/<name>/                   # アプリごとの EA / uninstall / detect
└── docs/
    ├── yaml-schema.md
    └── verify-flow.md
```

## 関連

- [docs/yaml-schema.md](docs/yaml-schema.md) — `apps/*.yml` のフィールド仕様
- [docs/verify-flow.md](docs/verify-flow.md) — 12 ステップ検証フローの詳細

## License

MIT
