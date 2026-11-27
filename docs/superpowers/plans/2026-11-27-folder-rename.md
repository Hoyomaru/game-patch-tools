# フォルダ名をそろえる 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 所持チェックの「持っている」作品のうち、RJ番号の入っていないゲームフォルダ・アーカイブの名前を `RJ番号 正式な作品名 v版` にそろえ、元に戻せるようにする。

**Architecture:** 名前を決める・変える・戻す処理は新しいファイル `owned-rename.ps1` に置き、画面を触らない関数だけにして Pester でテストする。`owned-gui.ps1` はそれを読み込み、確認用の一覧の画面とボタンだけを持つ。持っている作品の集め方は `Get-OwnedWorks` と同じ範囲にするため、ブックマークとバックアップを集める部分を `owned-core.ps1` の関数に切り出して両方から使う。

**Tech Stack:** Windows PowerShell 5.1、WinForms、Pester 3.4.0（Windows に最初から入っているもの。`Should Be` の書き方）

**Spec:** `docs/superpowers/specs/2026-11-27-folder-rename-design.md`

## Global Constraints

- 追加のインストールなし。PowerShell 5.1 で動くこと（`?.` `??` などは使わない）
- ネットにアクセスするのは作品名を取るときだけ。今の `Get-DLsiteTitles` を使い、送るのは RJ番号だけ
- 作品名は画面以外（ログ・コンソール・コミットメッセージ）に出さない。テストの作品名は架空のものにする
- 個人のデータ（`rename-logs/`）は `.gitignore` に入れる
- 文言はこのリポジトリの書き方にそろえる（やさしい日本語、「〜します」）
- 新しい名前の形：`RJ番号 正式な作品名 v版`（区切りは半角スペース。版がなければ `RJ番号 正式な作品名`。アーカイブは元の拡張子を付ける）

## Review Focus

1. **名前に使えない文字・末尾の点や空白が作品名に入っている** → 全角に置き換え・取り除いた名前になり、名前の変更が失敗しない（Task 1 のテスト）
2. **新しいフルパスが長すぎる** → 作品名を切り詰めて、フルパス 240 文字以内に収まる（Task 1 のテスト）
3. **名前を変える途中で1件失敗する（使用中など）** → 残りは続け、記録ファイルに成功したものだけ `done` が付き、`owned-links.json` は成功したものだけ書き換わる（Task 3 のテスト）
4. **戻すときに元の名前のものがもうある・新しい名前のものが消えている** → そこだけ飛ばして理由を返し、ほかは戻る（Task 3 のテスト）
5. **② に登録したゲームフォルダそのものが「持っている」の候補になっている**（見る深さ 1 で作品フォルダを直接登録した場合など） → 対象から外す（Task 2 のテスト）

---

## ファイル

- Create: `owned-rename.ps1` — 名前を決める・対象を選ぶ・変える・戻す（画面なし）
- Create: `tests/owned-rename.Tests.ps1` — Pester のテスト
- Modify: `owned-core.ps1:273-298` — `Get-OwnedWorks` からブックマークとバックアップを集める部分を `Get-OwnedWishlist` に切り出す
- Modify: `owned-gui.ps1` — `owned-rename.ps1` の読み込み、ボタン2つ、確認の一覧の画面
- Modify: `.gitignore`、`README.md`、`as-patch-finder.user.js:4`（版を 1.8.0 に）

テストの実行（どのタスクでも同じ）：

```powershell
powershell.exe -NoProfile -Command "Invoke-Pester -Script tests/owned-rename.Tests.ps1 -EnableExit"
```

テストファイルの先頭で `owned-core.ps1` と `owned-rename.ps1` をドットソースする。フォルダは `$TestDrive` の下に作る。

---

### Task 1: 新しい名前を作る

**Files:**
- Create: `owned-rename.ps1`
- Create: `tests/owned-rename.Tests.ps1`

**Interfaces:**
- Consumes: `Get-FolderVersion([string]$Name) -> string`（owned-core.ps1）
- Produces:
  - `ConvertTo-SafeFileName([string]$s) -> string`
  - `New-RenameName([string]$Code, [string]$Title, [string]$OldName, [bool]$IsArchive, [string]$ParentPath) -> string`（新しい名前。拡張子込み）

- [ ] **Step 1: 失敗するテストを書く**

```powershell
Describe 'ConvertTo-SafeFileName' {
  It '使えない文字を全角にする' { ConvertTo-SafeFileName 'A:B/C?D*E"F<G>H|I\J' | Should Be 'A：B／C？D＊E＂F＜G＞H｜I＼J' }
  It '改行・タブは空白1つにまとめる' { ConvertTo-SafeFileName "A`t`r`nB  C" | Should Be 'A B C' }
  It '末尾の点と空白を取る' { ConvertTo-SafeFileName 'ゲーム名. . ' | Should Be 'ゲーム名' }
}
Describe 'New-RenameName' {
  It '版があれば最後に付ける' { New-RenameName 'RJ01234567' '架空の作品' 'kakuu_game_v1.02' $false 'E:\Games' | Should Be 'RJ01234567 架空の作品 v1.02' }
  It '版がなければ付けない' { New-RenameName 'RJ01234567' '架空の作品' 'てきとう' $false 'E:\Games' | Should Be 'RJ01234567 架空の作品' }
  It 'アーカイブは拡張子を残す' { New-RenameName 'RJ01234567' '架空の作品' 'kakuu ver2.0.zip' $true 'E:\Games' | Should Be 'RJ01234567 架空の作品 v2.0.zip' }
  It 'フルパスが240文字を超えるなら作品名を切り詰める' {
    $parent = 'E:\' + ('x' * 200)
    $n = New-RenameName 'RJ01234567' ('あ' * 100) 'old_v1.0' $false $parent
    (Join-Path $parent $n).Length | Should Not BeGreaterThan 240
    $n | Should Match '^RJ01234567 あ+ v1\.0$'
  }
}
```

- [ ] **Step 2: 実行して失敗を確かめる** — 関数が見つからないエラーで FAIL

- [ ] **Step 3: `owned-rename.ps1` に2つの関数を書く**
  - 置き換え表：`\ / : * ? " < > |` → `＼ ／ ： ＊ ？ ＂ ＜ ＞ ｜`
  - 版は、アーカイブなら拡張子を除いた名前から `Get-FolderVersion` で読み、`v` を前に付ける
  - 切り詰めは作品名だけ。切り詰めたあとで末尾の点・空白をもう一度取る

- [ ] **Step 4: 実行して通ることを確かめる** — `Tests Passed: 7, Failed: 0`

- [ ] **Step 5: コミット** — `git add owned-rename.ps1 tests/owned-rename.Tests.ps1`、メッセージ「フォルダの新しい名前を作る処理を追加」

---

### Task 2: 名前を変える対象を選ぶ

**Files:**
- Modify: `owned-core.ps1:273-298`
- Modify: `owned-rename.ps1`、`tests/owned-rename.Tests.ps1`

**Interfaces:**
- Consumes: `Compare-Owned`、`Get-GameCandidates`（owned-core.ps1）。`New-RenameName`（Task 1）
- Produces:
  - `Get-OwnedWishlist([string[]]$Sources, [string]$Folder, [string]$BackupDir) -> object[]`（`Read-Wishlist` と同じ形。今の `Get-OwnedWorks` の前半をそのまま移す。`Get-OwnedWorks` はこれを使うように直す）
  - `Get-RenameTargets($Wishlist, $Candidates, [double]$Threshold, $Links, [string[]]$GameDirs) -> object[]`
    - 1件の形：`Code / Path / OldName / IsArchive / How / State / NewName / NewPath`
    - `State`：`'pending'`（作品名を入れる前）か `'multi'`（複数の作品に当たる）
    - `How`：`Compare-Owned` の `How`（`RJ番号が一致` は出てこない。`確かめた対応` か `作品名が一致`）
  - `Set-RenameNames($Targets, [hashtable]$Titles) -> void`：`State` が `'pending'` のものに `NewName` / `NewPath` を入れ、`State` を `'ok'`・`'notitle'`（作品名が取れなかった）・`'exists'`（同じ名前のものがもうある。`Test-Path -LiteralPath`）のどれかにする

- [ ] **Step 1: 失敗するテストを書く**（`$TestDrive` の下にフォルダを作り、`Get-GameCandidates` で候補を作る。気になるリストは `[pscustomobject]@{ Code; Title; Url }` の配列で渡す）

```powershell
Describe 'Get-RenameTargets' {
  # Games\かくうのげーむ, Games\RJ09999999 べつ, Games\にじゅう\にじゅう, Games\セット（2作品が同じ名前で当たる）
  It '作品名が完全一致した候補を対象にする' { ($t | Where-Object Code -eq 'RJ00000001').Path | Should Be (Join-Path $games 'かくうのげーむ') }
  It 'すでにRJ番号が入っている候補は対象にしない' { @($t | Where-Object Path -like '*RJ09999999*').Count | Should Be 0 }
  It '2つの作品が同じ候補に当たったら multi にする' { @($t | Where-Object State -eq 'multi').Count | Should Be 2 }
  It '作品\作品 は外側を対象にする' { ($t | Where-Object Code -eq 'RJ00000003').Path | Should Be (Join-Path $games 'にじゅう') }
  It 'ゲームフォルダそのものは対象にしない' { @(Get-RenameTargets $wish2 $cands2 0.6 $links @($games2)).Count | Should Be 0 }
  It '「たぶん」は対象にしない' { @($t | Where-Object Code -eq 'RJ00000005').Count | Should Be 0 }
}
Describe 'Set-RenameNames' {
  It '作品名が取れたら ok' { ... State | Should Be 'ok'; NewName | Should Be 'RJ00000001 架空の作品' }
  It '作品名が取れなければ notitle' { ... State | Should Be 'notitle' }
  It '同じ名前がもうあれば exists' { ... State | Should Be 'exists' }
}
```

- [ ] **Step 2: 実行して失敗を確かめる**

- [ ] **Step 3: 関数を書く**
  - `Compare-Owned` の結果のうち `Status -eq 'owned'` で、候補の `Code` が空のものを使う
  - `MatchPath` ごとにまとめ、2つ以上の RJ番号があればすべて `'multi'`
  - `MatchPath` の親が `$Candidates` の中にあり、親の `Norm` が同じで、親が `$GameDirs` のどれでもなければ、親に置き換える
  - `$GameDirs` と同じパス（末尾の `\` を無視して大文字小文字を区別せずに比べる）は外す

- [ ] **Step 4: 実行して通ることを確かめる**。あわせて今の動きが変わっていないか、`Get-OwnedWorks` を使う「持っている作品の更新をASで確認」を Task 4 の手での確認でも見る

- [ ] **Step 5: コミット** — 「名前を変える対象を選ぶ処理を追加」

---

### Task 3: 名前を変える・戻す・owned-links.json の書き換え

**Files:**
- Modify: `owned-rename.ps1`、`tests/owned-rename.Tests.ps1`、`.gitignore`（`rename-logs/` を追加）

**Interfaces:**
- Consumes: `Read-OwnedLinks`、`Save-OwnedLinks`（owned-core.ps1）。Task 2 の対象の形
- Produces:
  - `Update-LinkPaths($Links, [string]$OldPath, [string]$NewPath) -> void`：`Same` の値と `Diff` の各要素のうち、`OldPath` と同じか `OldPath + '\'` で始まるもの（大文字小文字を区別しない）を書き換える
  - `Invoke-FolderRename($Targets, [string]$LogDir, $Links, [string]$LinksPath) -> pscustomobject`：`State -eq 'ok'` のものだけ変える。戻り値は `@{ Log = 記録ファイルのパス; Done = 件数; Failed = @(@{ OldName; Reason }) }`
  - `Undo-FolderRename([string]$LogPath, $Links, [string]$LinksPath) -> pscustomobject`：戻り値は `@{ Done; Skipped = @(@{ Name; Reason }) }`
- 記録ファイル：`$LogDir\rename-yyyyMMdd-HHmmss.json`、UTF-8（BOMなし）。`{ "entries": [ { "old": "フルパス", "new": "フルパス", "done": false } ] }`。変える前に全件を書き、1件ごとに `done` を更新して書き直す。`owned-links.json` があれば同じ名前の `.links.json` として先にコピーする

- [ ] **Step 1: 失敗するテストを書く**

```powershell
Describe 'Update-LinkPaths' {
  It 'same のパスを書き換える' { ... $links.Same['RJ00000001'] | Should Be 'E:\G\RJ00000001 架空' }
  It '下にあるパスも書き換える' { ... $links.Same['RJ00000002'] | Should Be 'E:\G\RJ00000001 架空\中' }
  It 'diff の要素も書き換える' { ... }
  It '名前の先頭が同じだけの別フォルダは書き換えない' { # E:\G\架空2 は E:\G\架空 の書き換えで変わらない
  }
}
Describe 'Invoke-FolderRename / Undo-FolderRename' {
  It '名前を変えて記録に done を付ける' { ... Test-Path $new | Should Be $true; (Get-Content $r.Log -Raw | ConvertFrom-Json).entries[0].done | Should Be $true }
  It 'owned-links.json も新しいパスになる' { ... }
  It '1件失敗しても残りは変える' { # 片方のフォルダの中のファイルを開いたままにして失敗させる
    $r.Done | Should Be 1; $r.Failed.Count | Should Be 1 }
  It '戻すと元の名前とリンクに戻る' { ... }
  It '戻すとき元の名前がもうあれば飛ばす' { ... $u.Skipped.Count | Should Be 1 }
  It '戻すとき新しい名前のものがなければ飛ばす' { ... }
}
```

- [ ] **Step 2: 実行して失敗を確かめる**

- [ ] **Step 3: 関数を書く**
  - 変える順番はパスの深い方から（入れ子になっている別の作品のため）。戻すときは記録の逆順
  - 名前の変更は `Rename-Item -LiteralPath ... -NewName ... -ErrorAction Stop` を `try` で囲み、失敗は理由（例外のメッセージ）を `Failed` に入れて続ける
  - 1件成功するたびに `Update-LinkPaths`。最後に1回 `Save-OwnedLinks`

- [ ] **Step 4: 実行して通ることを確かめる**

- [ ] **Step 5: コミット** — 「フォルダの名前を変える・戻す処理を追加」

---

### Task 4: 所持チェックの画面

**Files:**
- Modify: `owned-gui.ps1`（4行目のあとで `owned-rename.ps1` を読み込む。`$bot` にボタン2つ。関数 `Show-RenameDialog`、`Undo-Rename`。`$RenameLogDir = Join-Path $PSScriptRoot 'rename-logs'`）

**Interfaces:**
- Consumes: Task 2・3 の関数、`Get-DLsiteTitles`、`Get-Candidates`、`Get-SelectedFolder`、`Run-Check`、`$script:Links`、`$LinksPath`、`$BackupDir`

- [ ] **Step 1: 「フォルダ名をそろえる…」（`Show-RenameDialog`）を書く**
  - `$script:Results` が空なら「先に「チェック開始」を押してください。」
  - `Get-OwnedWishlist` → `Get-RenameTargets`（候補は `Get-Candidates -Reuse`）。対象が0件なら「名前を変えられるフォルダはありません。（RJ番号が入っていない「持っている」作品だけが対象です）」
  - 作品名を取る前に「RJ番号 N 件を DLsite に送って作品名を取ります。よろしいですか？」と聞く（`Ask-YesNo`）。待つ間は `WaitCursor` と `$lblStatus`
  - 一覧の画面：`DataGridView`（チェック / 今の名前 / 新しい名前 / 決め手 / 状態）。`State -eq 'ok'` だけチェックでき、最初からチェック済み。状態の文字は `ok`=変えられる、`multi`=複数の作品に当たる、`notitle`=作品名が取れなかった、`exists`=同じ名前がもうある
  - 「名前を変える」→ 確認（N 件）→ `Invoke-FolderRename`。チェックを外したものは `State` を `'skip'` にしてから渡す
  - 結果を `Show-Info`（変えた数・変えられなかった名前と理由）。そのあと `Run-Check`（候補は調べ直す）
- [ ] **Step 2: 「フォルダ名を戻す…」（`Undo-Rename`）を書く** — `OpenFileDialog` で `rename-logs` の `rename-*.json` を選び、確認 → `Undo-FolderRename` → 結果を `Show-Info` → `Run-Check`
- [ ] **Step 3: 手で確かめる**（架空の名前のテスト用フォルダで。本物のゲームフォルダは使わない）
  - ② にテスト用フォルダだけを登録してチェック → 「フォルダ名をそろえる…」で一覧が出て、状態と決め手が正しい
  - 名前を変えたあとのチェックで、その作品が「RJ番号が一致」になる
  - 「フォルダ名を戻す…」で元に戻る
  - 「持っている作品の更新をASで確認」の件数が Task 2 の前と変わらない
- [ ] **Step 4: テスト全体を流す** — `Tests Passed: …, Failed: 0`、`node --test tests/` も通る
- [ ] **Step 5: コミット** — 「所持チェックにフォルダ名をそろえるボタンを追加」

---

### Task 5: README と版

**Files:**
- Modify: `README.md`（所持チェックの機能一覧と、「### フォルダ名をそろえる（1.8.0〜）」の節。`rename-logs` も保存されるものの一覧に足す）
- Modify: `as-patch-finder.user.js:4`（`@version 1.8.0`）

- [ ] **Step 1: README を書く** — 対象（RJ番号が入っていない「持っている」作品）、名前の形、DLsite に RJ番号を送ること、一覧で確かめてから変えること、戻し方
- [ ] **Step 2: 版を 1.8.0 にしてコミット** — 「フォルダ名をそろえる機能を追加（AS Patch Finder 1.8.0）」
- [ ] **Step 3: タグとリリース**（push はユーザーに確かめてから）— `git tag v1.8.0`、`gh release create v1.8.0`
