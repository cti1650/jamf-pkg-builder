# 検証フロー（12ステップ）

`scripts/core/build-and-verify.sh` が macOS 15 ランナー上で実行する 12 ステップ。各ステップの結果は最後にサマリーとして出力され、`FAIL` が 1 つでもあればジョブが失敗扱いになる（`WARN` は緑のまま）。

| # | ステップ | 主なコマンド | 目的 |
|---|---|---|---|
| 1 | download | `curl -fsSL --retry 3` | URL から DL。失敗のみ即時 abort |
| 2 | static analysis | `file`, `pkgutil --check-signature`, `hdiutil imageinfo` | 形式・署名チェック（情報出力のみ） |
| 3 | build pkg | `hdiutil attach`, `rsync`, `pkgbuild` | dmg→pkg 再パッケージ。attach は 3 回までリトライ |
| 4 | pre-install snapshot | `ls /Applications`, `pkgutil --pkgs` | インストール前の状態保存 |
| 5 | install | `sudo installer -pkg ... -target /` | 実機インストール。600 秒で timeout |
| 6 | post-install diff | `diff` | `/Applications` と receipt の差分検出 |
| 7 | detection | `defaults read CFBundleShortVersionString` または `detect.sh` | `min_version` を `sort -V` で比較 |
| 8 | arch check | `file`, `lipo -info` | universal バイナリかどうか確認 |
| 9 | uninstall | `pkgutil --forget` または `uninstall.sh` | アンインストール実行 |
| 10 | post-uninstall diff | `diff` | アンインストール後の残留チェック |
| 11 | removal verify | `[[ -d ... ]]` | `.app` バンドルが消えているか |
| 12 | EA functional test | `bash ea.sh` | `<result>...</result>` タグ出力チェック |

## 既知の flake と対策

| 現象 | 対策 |
|---|---|
| `hdiutil attach` がたまに `hdiutil: attach failed - no mountable file systems` | 3 秒間隔で 3 回リトライ |
| `installer` コマンドがハング | `/usr/bin/timeout 600` でラップ |
| `pkgutil --pkgs` が初回起動時に遅い | snapshot のみで利用しているため許容 |

## script_based モード

`installer.type: script_based` の YAML はステップ 1〜12 をスキップし、EA / uninstall スクリプトを artifact に積むだけで終了する。端末側で DL してインストールするポリシー（例: GitHub Releases から最新を取得するパターン）用。
