# DLsite 以外で買った作品もフォルダ名をそろえる 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 「フォルダ名をそろえる…」の一覧で、Steam・FANZA の作品ページの URL を貼るか、作品名を自分で入れて、DLsite 以外の作品も「お店 番号 正式な作品名 v版」にそろえる。

**Architecture:** 対象（target）の `Code` に、RJ番号のほか `Steam 1234560`・`FANZA d_123456`・`Manual:<お店>:<作品名>` を入れる。名前の組み立て・同じ番号の重なり（dupcode）・作品名の表（`$script:RenameTitles`）は今のしくみをそのまま使う。お店ごとの読み取りと作品名の取得は新しい `owned-stores.ps1` にまとめる。そろえたフォルダは `rename-logs` の記録から読み、次の「ブックマークにない作品」から外す。

**Tech Stack:** PowerShell 5.1、WinForms、Pester 3.4

**Spec:** `docs/superpowers/specs/2026-11-27-other-store-rename-design.md`

## Global Constraints

- 追加のインストールなし。新しい .ps1 は UTF-8（BOM付き）・CRLF
- お店に送るのは番号だけ（Steam は appid、FANZA は作品の番号）。フォルダ名は送らない
- 名前の形：`<お店> <番号> <正式な作品名> v<版>`。自分で入れたとき：`<お店の名前> <作品名> v<版>`（お店の名前が空なら `<作品名> v<版>`）
- RJ番号を含む URL・文字は今までどおり RJ番号（DLsite）
- テストの作品名・番号はすべて架空

## Review Focus

1. **DLsite の URL や RJ番号を含む文字** → 今までどおり RJ番号になる（Steam・FANZA と取り違えない）（Task 1）
2. **Steam の URL に作品名や `?l=japanese` が付いている** → 番号だけを読む（Task 1）
3. **Steam が `success: false` を返す・FANZA のページに `og:title` がない（年齢確認のページなど）** → 作品名なしとして扱い、画面では作品名を入れる欄に進む（Task 2・4）
4. **そろえたあと「フォルダ名を戻す…」で戻したもの** → また「ブックマークにない作品」に出る。記録ファイルが壊れていても止まらない（Task 3）
5. **2つのフォルダに同じ Steam の番号・同じ自分で入れた名前** → どちらも変えない（dupcode）（Task 3）

---

### Task 1: お店の番号の読み取りと名前の頭（`owned-stores.ps1`）

**Files:** Create `owned-stores.ps1`。Create `tests/owned-stores.Tests.ps1`（core・identify・stores・rename を dot-source）

**Interfaces — Produces:**
- `ConvertTo-StoreCode([string]$Text) -> string`：
  - RJ番号（`$script:CodeRe`）があればそれ（大文字）。最初に見る
  - `store.steampowered.com/app/<数字>` または `^\s*steam\s*(\d+)\s*$` → `Steam <数字>`
  - `dmm.co.jp` の URL の `cid=<英数字_>`、`dlsoft.dmm.co.jp/detail/<英数字_>`、または `^\s*(d_\d+)\s*$` → `FANZA <番号>`（番号は小文字）
  - どれでもなければ ''
- `New-ManualCode([string]$Store, [string]$Title) -> string`：`Manual:<Store.Trim()>:<Title.Trim()>`
- `Get-CodePrefix([string]$Code) -> string`：名前の頭。RJ・Steam・FANZA は `$Code` そのもの、`Manual:` は `<お店>`（空もあり）
- `Get-ManualTitle([string]$Code) -> string`：`Manual:` の作品名、ほかは ''
- `Get-StorePageUrl([string]$Code) -> string`：RJ → `https://www.dlsite.com/maniax/work/=/product_id/<RJ>.html`、Steam → `https://store.steampowered.com/app/<数字>/`、FANZA で `d_` → `https://www.dmm.co.jp/dc/doujin/-/detail/=/cid=<番号>/`、FANZA ほか → `https://dlsoft.dmm.co.jp/detail/<番号>/`、Manual → ''

- [ ] Step 1: 失敗するテスト：
  - `ConvertTo-StoreCode 'https://store.steampowered.com/app/1234560/Kakuu_Game/?l=japanese'` → `Steam 1234560`
  - `'steam 1234560'` → `Steam 1234560`
  - `'https://www.dmm.co.jp/dc/doujin/-/detail/=/cid=d_123456/'` → `FANZA d_123456`
  - `'https://dlsoft.dmm.co.jp/detail/kakuu_0001/'` → `FANZA kakuu_0001`
  - `'D_123456'` → `FANZA d_123456`
  - `'https://www.dlsite.com/maniax/work/=/product_id/RJ01234567.html'` → `RJ01234567`
  - `'https://example.com/app/123'` → ''
  - `Get-CodePrefix (New-ManualCode ' BOOTH ' ' かくう ')` → `BOOTH`、`Get-ManualTitle` → `かくう`、`Get-CodePrefix (New-ManualCode '' 'かくう')` → ''
  - `Get-StorePageUrl` の4種と Manual → ''
- [ ] Step 2: 失敗を確かめる → Step 3: 書く → Step 4: 通る → Step 5: コミット「お店の番号の読み取りを追加」

### Task 2: 正式な作品名を取る（`owned-stores.ps1`）

**Files:** Modify `owned-stores.ps1`、`tests/owned-stores.Tests.ps1`。Create `tests/fixtures/steam-appdetails-sample.json`（架空の appid `1234560`、`success: true`、`name: "架空のゲーム"`）、`tests/fixtures/fanza-page-sample.html`（`<meta property="og:title" content="架空の同人ゲーム &amp; 体験">` を含む）

**Interfaces — Produces:**
- `ConvertFrom-SteamAppDetails([string]$Json, [string]$AppId) -> string`：`<appid>.success` が真なら `data.name`、ほかは ''
- `ConvertFrom-FanzaPage([string]$Html) -> string`：`og:title` を HtmlDecode したもの、なければ ''
- `Get-StoreTitles([string[]]$Codes) -> hashtable`（Code → 作品名）：
  - RJ はまとめて `Get-DLsiteTitles`
  - Steam は1件ずつ `https://store.steampowered.com/api/appdetails?appids=<数字>&l=japanese`
  - FANZA は `Get-StorePageUrl` のページを cookie `age_check_done=1` を付けて取る
  - Manual は `Get-ManualTitle`（ネットに出ない）
  - Steam・FANZA の問い合わせの間は 800 ミリ秒あける
  - 取れなかった数を `$script:StoreFailedCount` に入れる（RJ の分は `$script:DLsiteFailedCount` を足す）
- [ ] Step 1: 失敗するテスト：見本の JSON で `架空のゲーム`、appid が違う・`success:false` で ''、見本の HTML で `架空の同人ゲーム & 体験`、`og:title` なしで ''、`Get-StoreTitles @((New-ManualCode 'BOOTH' 'かくう'))` が `かくう`（ネットに出ない）
- [ ] Step 2: 失敗 → Step 3: 書く（取る部分は `Invoke-WebRequest -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 10`、本文は RawContentStream から UTF-8 で読む。FANZA は `WebRequestSession` に cookie）→ Step 4: 通る
- [ ] Step 5: 実際に1件ずつ確かめる（Steam は公開の appid 1件、FANZA 同人は公開の作品1件。番号だけを送る）。FANZA の `dlsoft` で取れなければ、その形は ''（作品名を入れる欄へ）とし、ledger に Ruling を残す
- [ ] Step 6: コミット「Steam・FANZA から正式な作品名を取る処理を追加」

### Task 3: 名前を変える対象への組み込み（`owned-rename.ps1`・`owned-identify.ps1`）

**Files:** Modify `owned-rename.ps1`、`owned-identify.ps1`、`tests/owned-rename.Tests.ps1`（stores を dot-source に追加）、`tests/owned-identify.Tests.ps1`（同）

**Interfaces — Consumes:** Task 1 の関数。**Produces:**
- `Set-TargetCode($Target, [string]$Text) -> bool`：`ConvertTo-StoreCode` が空でなければ Code に入れる。Clue は Steam・FANZA なら `store`、RJ なら今までどおり `manual`
- `Set-TargetManual($Target, [string]$Store, [string]$Title) -> string`：`New-ManualCode` を Code に入れ、Clue `manual`・State `pending`、Code を返す（呼ぶ側が `$Titles[Code] = Title` を入れる）
- `New-RenameName` の `$Code` が空なら頭なし（`<作品名> v<版>`）
- `Set-RenameNames` は `Get-CodePrefix $t.Code` を名前の頭に使う
- `Get-RenamedPaths([string]$LogDir) -> string[]`：`rename-*.json`（`.links.json` は除く）の `entries` で `done` が真のものの `new`。読めないファイルは飛ばす
- `Find-SteamAppId([string]$Path) -> string`：`<Path>\steam_appid.txt` か、直下のフォルダの `steam_appid.txt` の中身が数字だけならその数字、ほかは ''
- `Get-UnknownTargets`：中の RJ番号が 0 件で `Find-SteamAppId` があれば、`Choices` の先頭に `@{ Code = 'Steam <数字>'; Title = '' }`（チェックは付けない）

- [ ] Step 1: 失敗するテスト：
  - `Set-TargetCode` に Steam の URL → Code `Steam 1234560`・Clue `store`、RJ番号 → Clue `manual`
  - 架空の作品名で `Set-RenameNames` → `Steam 1234560 架空のゲーム v1.02`（元の名前 `kakuu_v1.02`）
  - Manual（お店 `BOOTH`）→ `BOOTH かくう v1.02`、お店が空 → `かくう v1.02`
  - 2つの対象に同じ `Steam 1234560` → どちらも `dupcode`
  - `Get-RenamedPaths`：done 真・偽・壊れたファイル・`.links.json` を置いて、done 真の new だけ
  - `Find-SteamAppId`：直下・1つ下・中身が数字でない
- [ ] Step 2: 失敗 → Step 3: 書く → Step 4: すべての Pester が通る → Step 5: コミット「Steam・FANZA・自分で入れた名前でフォルダ名をそろえられるようにする」

### Task 4: 画面（`owned-gui.ps1`）

**Files:** Modify `owned-gui.ps1`（`owned-stores.ps1` を dot-source。identify の後・rename の前）

**Interfaces — Consumes:** Task 1〜3

- `Update-RenameTitles` は `Get-StoreTitles` を使い、取れなかった数（`$script:StoreFailedCount`）を返す
- `Show-RenameDialog`：`$excl` に `Get-RenamedPaths $RenameLogDir` を足す。「RJ番号」の列見出しを「番号」に。説明の文に「Steam・FANZA の作品ページの URL を右クリックで貼れる」ことを足す
- 行の候補の表示：Manual の Code は `<お店> <作品名>`（お店が空なら作品名だけ）と出す。表示の文字と Code の対応は行ごとに持ち（`Tag` に `ChoiceMap` など）、候補を選んだときは文字の頭ではなく対応から Code を決める
- 右クリック：「番号・お店の URL を入れる…」。入れた文字が `ConvertTo-StoreCode` で読めないとき、または読めたが作品名が取れなかったとき（Steam・FANZA）は、続けて「作品名」「お店の名前（空でもよい）」を InputBox で聞き、`Set-TargetManual` と `$script:RenameTitles[Code] = 作品名` にする。作品名が空なら何もしない
- 番号の欄をダブルクリック：`Get-StorePageUrl` が空でなければ開く
- `$RenameClueText` に `store` = `お店の URL` を足す（設計書の「決め手は『お店の URL』と出す」）
- [ ] Step 1: 書く → Step 2: 構文チェックとすべての Pester・node のテスト
- [ ] Step 3: 手で確かめる（ユーザーの実データ）：Steam の URL を1件貼って新しい名前が出る、対応外の URL で作品名を入れる欄が出る、名前を変えたあと開き直すと出てこない、「フォルダ名を戻す…」のあとまた出る
- [ ] Step 4: コミット「フォルダ名をそろえる一覧でお店の URL・作品名を入れられるようにする」

### Task 5: README と版

- [ ] README の「フォルダ名をそろえる」に節「DLsite 以外で買った作品（1.11.0〜）」：右クリックで Steam・FANZA の URL、対応外は作品名を入れる、名前の形、送るのは番号だけ、そろえたものは次から出ない、`steam_appid.txt` があれば候補に出る。開発メモのファイル表に `owned-stores.ps1`
- [ ] `as-patch-finder.user.js:4` を 1.11.0。コミット「DLsite 以外で買った作品もフォルダ名をそろえる（AS Patch Finder 1.11.0）」
- [ ] タグとリリースは push するとき（ユーザーに確かめてから）
