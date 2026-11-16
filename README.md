# game-patch-tools

ゲームの翻訳パッチ探しと、気になる作品の管理を楽にするための個人用ツール集です。

## 所持チェック（Windows）

ブラウザのブックマーク（気になる作品のDLsiteのURL）と、手元のゲームフォルダを照らし合わせて、すでに持っている作品かどうかを判定します。

- `所持チェック.bat` をダブルクリックで起動（PowerShell 5.1 以上。追加のインストールは不要）
- 判定は作品名の一致・似かたで行います（RJ番号がフォルダ名にあればそれも使用）
- 持っている作品のブックマーク削除、URLのまとめて追加ができます（ブラウザ終了中のみ・毎回バックアップあり）
- ネットにアクセスするのは「URL をまとめて追加」で作品名をDLsiteから取るときだけです（送るのはRJ番号だけ）

| ファイル | 内容 |
|---|---|
| `所持チェック.bat` | 起動用 |
| `owned-gui.ps1` | 画面 |
| `owned-core.ps1` | 判定・追加・削除の処理本体 |
| `check-owned.ps1` | コマンド版 |

設定（`owned-gui-settings.json`）、結果レポート、ブックマークのバックアップは、このフォルダに保存されます。これらは `.gitignore` でリポジトリの対象から外しています。

## 検索結果のバージョン整理（Tampermonkey）

`as-patch-finder.user.js`：フォーラムの検索結果で、タイトルからバージョン・日付・作品コードを抜き出し、作品ごとにまとめて最新版をハイライトします。

インストール: Tampermonkey を入れたブラウザで次のURLを開く
https://raw.githubusercontent.com/Hoyomaru/game-patch-tools/main/as-patch-finder.user.js

更新するときは、スクリプトの `@version` を上げてから push すると、Tampermonkey が自動で取り込みます。
