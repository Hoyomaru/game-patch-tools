# ブックマークの書き換えを Edge の拡張機能で行う 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 同期がオンの Edge のブックマークを、所持チェックが拡張機能を通して消す・足す・まとめるようにし、同期で戻らないようにする。

**Architecture:** 所持チェックは中身を URL の `#gpt-bookmarks=` に入れて、同じプロフィールの Edge で DLsite のページを開く。拡張機能（`edge-extension/`）の content script が読み取り、内容と「実行する」ボタンを出す。押されたら service worker が `chrome.bookmarks` で書き換える。判定の中身（フォルダ探し・何を消す/足す/移すか）は `edge-extension/ops.js` の画面なしの関数にまとめ、node でテストする。

**Tech Stack:** Manifest V3、素の JavaScript、node:test。PowerShell 5.1、Pester 3.4

**Spec:** `docs/superpowers/specs/2026-11-27-bookmark-extension-design.md`

## Global Constraints

- 拡張機能の権限は `bookmarks` と `https://www.dlsite.com/*` の content script だけ。ネットに何も送らない
- 書き換えは「実行する」を押したときだけ
- 同期がオンのとき、所持チェックは `Bookmarks` ファイルを直接書き換えない
- 所持チェックは追加のインストールなし。新しい .ps1 は UTF-8（BOM付き）・CRLF
- 渡す形：`#gpt-bookmarks=` + `encodeURIComponent(JSON)`、JSON は `{ v: 1, op: 'delete'|'add'|'move', folder, codes, items: [{code,title,url}], sub }`

## Review Focus

1. **ほかのサイトに仕込まれた `#gpt-bookmarks=` のリンク** → 内容を出すだけで、押さなければ何も変わらない（Task 2）
2. **① のフォルダが見つからない** → 何も変えず「フォルダが見つかりません」と出す（Task 2）
3. **中身が壊れている・`v` が違う** → 何もしない（Task 2）
4. **件数が多く URL が長すぎる** → 何回かに分けて開き、それぞれで実行できる（Task 1）
5. **同期がオンなのに古い処理（ファイルの書き換え）を通る道が残っている**（バックアップから戻す・コマンド版の -Prune を含む）→ どれも止まる（Task 3）

---

### Task 1: 所持チェック側の判定（同期・プロフィール・渡すもの）

**Files:** Modify `owned-core.ps1`。Create `tests/owned-bookmarks.Tests.ps1`

**Interfaces — Produces:**
- `Test-BookmarksSynced([string]$Path) -> bool`：JSON に `sync_metadata` があり空でない
- `Get-EdgeProfileDir([string]$Path) -> string`：パスが `…\Microsoft\Edge\User Data\<名前>\Bookmarks` なら `<名前>`、ほかは ''
- `New-BookmarkOpUrls([string]$Op, [string]$Folder, [string[]]$Codes, $Items, [string]$Sub, [int]$MaxLen = 30000) -> string[]`：`https://www.dlsite.com/maniax/#gpt-bookmarks=<encodeURIComponent(JSON)>` の一覧。1本が `$MaxLen` を超えるなら `codes`（add は `items`）を分ける。エンコードは `[uri]::EscapeDataString`

- [ ] Step 1: 失敗するテスト（同期あり/なし/空、Edge の Default・Profile 2・Chrome は ''、1本に収まる・分かれる・分けても全部の番号が1回ずつ入る、JSON を戻すと op/folder/sub が同じ）
- [ ] Step 2: 失敗を確かめる → Step 3: 書く → Step 4: 通る → Step 5: コミット「同期の見分けと拡張機能に渡す URL を作る処理を追加」

### Task 2: 拡張機能

**Files:** Create `edge-extension/manifest.json`、`edge-extension/ops.js`、`edge-extension/background.js`、`edge-extension/content.js`、`edge-extension/content.css`、`tests/bookmark-ops.test.js`

**Interfaces — Produces（`ops.js`。`importScripts` でも `require` でも読めるようにする）:**
- `parsePayload(hash) -> payload | null`：`#gpt-bookmarks=` で始まり、JSON が読めて `v === 1`・`op` が3つのどれか・`codes`/`items` が配列なら返す
- `findFolders(tree, path) -> node[]`：`path` が空ならルートの子（お気に入りバーなど）全部。`ルート名 / a / b` のルートは名前で、合わなければ位置（0 = お気に入りバー、1 = その他のお気に入り）で、その下は名前で
- `planOps(tree, payload) -> { error?, folderLabel, remove: [id], add: [{title,url}], move: [id], createSub: bool, subId? , parentId? }`：
  - delete：見つかったフォルダ全部の中（サブフォルダ含む）の DLsite の URL で、RJ番号（大文字小文字を区別しない）が `codes` にあるもの
  - add：最初のフォルダの中にまだない RJ番号の `items`
  - move：最初のフォルダの中（`sub` の中は除く）の `codes` のもの。`sub` がなければ `createSub`
  - フォルダが見つからなければ `error`
- `codeOf(url) -> string`：`/(?<![A-Za-z0-9])((?:RJ|VJ|BJ|RE)\d{6,8})(?![0-9])/i` の大文字、ないなら ''

- manifest：MV3、`name`「所持チェック ブックマーク係」、`permissions: ["bookmarks"]`、`background.service_worker`、`content_scripts`（`https://www.dlsite.com/*`、`run_at: document_idle`）
- background.js：`importScripts('ops.js')`。メッセージ `plan`（tree を取り `planOps` の結果と件数を返す）と `apply`（もう一度 tree を取り計画し直して `chrome.bookmarks.remove` / `create` / `move` を行い、件数を返す）
- content.js：`parsePayload(location.hash)` が null なら何もしない。`history.replaceState` で `#` を消す。`plan` を送り、右下に「お気に入り『<folderLabel>』から N 件を消します／に N 件を足します／の中の N 件を『sub』に移します」と「実行する」「やめる」を出す。押したら `apply`、結果の件数を出す
- [ ] Step 1: 失敗するテスト（node）：parsePayload（正しい・壊れた JSON・v 違い・# がない）、findFolders（名前・位置・空・見つからない）、planOps の3つ（サブフォルダの中も消す・フォルダの外は消さない・add の重複を足さない・move で sub の中は除く・sub を作る）
- [ ] Step 2: 失敗 → Step 3: `ops.js` → Step 4: 通る → Step 5: manifest・background・content を書き、`node --check` で構文を確かめる → Step 6: コミット「ブックマークを書き換える Edge の拡張機能を追加」

### Task 3: 所持チェックの画面とコマンド版

**Files:** Modify `owned-gui.ps1`、`check-owned.ps1`

**Interfaces — Consumes:** Task 1 の関数

- `Invoke-BookmarkOpInEdge([string]$BookmarksPath, [string]$Op, [string]$Folder, [string[]]$Codes, $Items, [string]$Sub) -> bool`（owned-gui.ps1）：
  - 初回（設定 `ExtensionReady` が偽）は、入れ方を説明して「入れましたか？」と聞き、はいなら設定に覚える
  - `Backup-BookmarksFile` を取る
  - `New-BookmarkOpUrls` の URL ごとに `Start-Process msedge.exe -ArgumentList "--profile-directory=`"<名前>`"", <URL>` で開き、「Edge のページで『実行する』を押し、結果が出たら OK を押してください（i / n）」と待つ
  - 戻り値：最後まで進んだら $true
- `Delete-Checked`・`Invoke-BulkAdd`・`Move-ASFound`：ファイルごとに `Test-BookmarksSynced` を見て、真なら `Get-EdgeProfileDir` が空でなければ `Invoke-BookmarkOpInEdge`、空なら「同期がオンの Edge 以外のブラウザのブックマークは書き換えられません」と出して飛ばす。偽なら今までどおり
- 拡張機能で行ったあとは、Edge がファイルを書き出すまで最大 10 秒、`Bookmarks` の更新日時が変わるのを待ってから `Run-Check`（変わらなければ「Edge を一度閉じてからチェックし直してください」と出す）
- `Restore-Backup`：同期がオンなら止めて、設計書の文言で知らせる
- `check-owned.ps1 -Prune`：同期がオンのファイルは消さずに「同期がオンなので消しません（所持チェックの画面から拡張機能で消してください）」
- 設定の保存・読み込みに `ExtensionReady` を足す
- [ ] Step 1: 書く → Step 2: 構文チェック・Pester・node のテスト → Step 3: 手で確かめる（架空のブックマークの作業用コピーで、同期オフの今までの流れが変わらないこと。同期オンの流れは、ユーザーが拡張機能を入れたあとに一緒に確かめる）→ Step 4: コミット「同期がオンのときは拡張機能でブックマークを書き換える」

### Task 4: README と版

- [ ] README：「同期がオンの Edge」節（なぜ戻るか、拡張機能の入れ方：`edge://extensions` → 開発者モード → 「展開して読み込み」→ `edge-extension` フォルダ、使い方、バックアップから戻すの扱い）。④・まとめて追加・まとめるの説明の「ブラウザを閉じる」に「同期がオフのとき」を足す
- [ ] `as-patch-finder.user.js:4` を 1.10.0 に。コミット「同期がオンの Edge のブックマークを拡張機能で書き換える（AS Patch Finder 1.10.0）」
- [ ] タグとリリースは main に取り込んで push するとき（ユーザーに確かめてから）
