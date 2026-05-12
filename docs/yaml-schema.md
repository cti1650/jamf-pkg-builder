# apps/*.yml スキーマ

各アプリの定義ファイル `apps/<name>.yml` のフィールド仕様。lint (`scripts/check-apps-schema.sh`) で機械的に検証される。

## トップレベルフィールド

| フィールド | 必須 | 型 | 説明 |
|---|---|---|---|
| `name` | ✓ | string | 表示用のアプリ名（人間可読）。例: `Google Chrome` |
| `download` | ※1 | object | インストーラのダウンロード情報 |
| `installer` | ✓ | object | PKG ビルド方法 |
| `detect` | ✓ | object | 配布後の存在確認方法 |
| `uninstall` | ※2 | object | アンインストール方法 |
| `extension_attribute` | 推奨 | object | Jamf Pro EA スクリプトパス |

※1: `installer.type: script_based` の場合は省略可。
※2: `installer.type: script_based` の場合は省略可。

## `download`

| フィールド | 必須 | 型 | 説明 |
|---|---|---|---|
| `url` | ✓ | string | インストーラの直接ダウンロード URL。リダイレクトは許容（`curl -fsSL`） |
| `file` | ✓ | string | 保存ファイル名（拡張子は `.pkg` または `.dmg`） |

## `installer`

| フィールド | 必須 | 型 | 説明 |
|---|---|---|---|
| `type` | ✓ | `pkg` \| `dmg` \| `script_based` | インストーラ形式 |
| `app_name` | ※ | string | DMG 内の `.app` バンドル名。`type: dmg` かつ `repackage: true` のとき必須 |
| `repackage` | ✓ | bool | `dmg` のとき、`pkgbuild` で PKG 化するか |

### `installer.type` ごとの挙動

| type | 動作 |
|---|---|
| `pkg` | DL した PKG をそのまま検証に使う |
| `dmg` + `repackage: true` | DMG マウント → `.app` を rsync → `pkgbuild` で PKG 化（未署名） |
| `dmg` + `repackage: false` | DMG をそのまま artifact 化（PKG 変換せず） |
| `script_based` | ダウンロード・ビルド・インストールはスキップ。EA / uninstall スクリプトだけ artifact 化 |

`pkgbuild` 時の identifier は `local.jamf-pkg-builder.<basename>`、version は `1.0.0` 固定。**署名・公証は付与しない**（MDM 配布が前提）。

## `detect`

| フィールド | 必須 | 型 | 説明 |
|---|---|---|---|
| `app_path` | ※ | string | `.app` バンドルの絶対パス。例: `/Applications/Google Chrome.app` |
| `min_version` | optional | string | `CFBundleShortVersionString` との `sort -V` 比較に使う最小バージョン |
| `ea_script` | ※ | string | カスタム検出スクリプトのパス。`app_path` が使えないアプリ向け |

※ `app_path` と `ea_script` のいずれか片方は必須。

カスタム検出スクリプトは stdout に `installed` / `true` / `yes` / `found` のいずれかを含めれば「インストール済み」と判定される。

## `uninstall`

| フィールド | 必須 | 型 | 説明 |
|---|---|---|---|
| `type` | ✓ | `pkg` \| `script` | アンインストール方式 |
| `pkg_id` | ※ | string | `pkgutil --forget` に渡すパッケージ識別子。`type: pkg` のとき必須 |
| `script` | ※ | string | `sudo bash` で実行されるアンインストールスクリプトパス。`type: script` のとき必須 |

`type: pkg` は pkgutil レシートの forget しか行わないため、実体ファイル削除は `detect.app_path` のみが対象。複雑なクリーンアップが必要なアプリは `type: script` で `scripts/apps/<name>/uninstall.sh` を書く。

## `extension_attribute`

| フィールド | 必須 | 型 | 説明 |
|---|---|---|---|
| `script` | 推奨 | string | Jamf Pro Extension Attribute スクリプトパス。`<result>...</result>` を stdout に出力すること |

EA スクリプトは Jamf Pro の「Computer Extension Attributes」にそのまま貼り付けて使う。配布状況の確認や、`policy custom event` の起動条件に利用される。
