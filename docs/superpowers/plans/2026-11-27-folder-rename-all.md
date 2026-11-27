# フォルダ名をそろえる：ブックマークにない作品も対象にする 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** RJ番号のない手元の作品にも、中の RJ番号・DLsite の検索・手入力で番号を付け、1.8.0 の「フォルダ名をそろえる」の一覧から名前を変えられるようにする。

**Architecture:** 作品の見分け・中の手がかり・DLsite 検索・検索の保存は新しいファイル `owned-identify.ps1`（画面なし、Pester でテスト）に置く。`owned-rename.ps1` の対象の形に「手がかり」「候補」「最初からチェック」を足し、1.8.0 の名前の作り方・変え方・戻し方をそのまま使う。`owned-gui.ps1` は検索の進み具合と止めるボタン、一覧の RJ番号の欄を足す。

**Tech Stack:** Windows PowerShell 5.1、WinForms、Pester 3.4.0

**Spec:** `docs/superpowers/specs/2026-11-27-folder-rename-all-design.md`（前提：`docs/superpowers/specs/2026-11-27-folder-rename-design.md`）

## Global Constraints

- 追加のインストールなし。PowerShell 5.1 で動くこと
- ネットに送るのは RJ番号と検索する言葉だけ。DLsite への問い合わせは1件ごとに 800 ミリ秒あける
- 作品名は画面以外（ログ・コンソール・コミット）に出さない。テストの作品名は架空
- 個人のデータ（`dlsite-search-cache.json`）は `.gitignore` に入れる
- 新しい .ps1 は UTF-8（BOM付き）・CRLF（PowerShell 5.1 が日本語を読めるように）
- 新しい名前の形は 1.8.0 と同じ `RJ番号 正式な作品名 v版`

## Review Focus

1. **検索で何も見つからない・DLsite につながらない** → その行は「見つからなかった」で残り、自分で入れられる。ほかの行の検索は続く（Task 3・5）
2. **検索の途中で「止める」** → そこまでの結果は一覧に出て、保存もされる。次は残りだけ検索する（Task 3・5）
3. **自分で入れた RJ番号の形が違う（URL・小文字・空白入り）** → URL や小文字からも RJ番号を取り出し、取り出せなければ受け付けない（Task 4）
4. **同じ RJ番号を2つの行で選んだ** → どちらも変えない（「複数のフォルダに同じ番号」）。違う2つのフォルダに同じ番号を付けない（Task 4）
5. **作品の中のフォルダ（`www`・`*_Data` など）や、サークルでまとめたフォルダ** → 対象にならない（Task 1）

---

## ファイル

- Create: `owned-identify.ps1` — 作品の見分け、中の手がかり、検索する言葉、DLsite 検索の読み取り、検索の保存、最初からチェックの判定
- Create: `tests/owned-identify.Tests.ps1`、`tests/fixtures/dlsite-search-sample.json`（作品名は架空）
- Modify: `owned-rename.ps1` — 対象の形に `Clue` / `Choices` / `Auto` を足す。`Get-UnknownTargets`、`Set-TargetCode`、`Test-DuplicateCodes`
- Modify: `owned-gui.ps1` — `Show-RenameDialog` に検索と RJ番号の欄
- Modify: `.gitignore`、`README.md`、`as-patch-finder.user.js:4`（1.9.0）

テストの実行：

```powershell
powershell.exe -NoProfile -Command "Invoke-Pester -Script tests -EnableExit"
```

---

### Task 1: 作品の見分け

**Files:** Create `owned-identify.ps1`、`tests/owned-identify.Tests.ps1`

**Interfaces:**
- Consumes: `Get-GameCandidates` の候補（`Name / Path / Norm / Bigrams / Code`）
- Produces:
  - `Test-GameFolder([string]$Path) -> bool`：直下に `.exe` ファイル、`*_Data` フォルダ、`www` フォルダ、`data\System.json`、`Game.ini`、`package.json` のどれかがある
  - `Get-UnknownWorks($Candidates, [string[]]$ExcludePaths, [string[]]$GameDirs) -> object[]`：1件は `Path / OldName / IsArchive`
    - 名前に RJ番号がある候補、`$ExcludePaths`（ブックマークで当たった候補と「たぶん」の候補）、② のゲームフォルダとその親は外す
    - アーカイブはそのまま作品
    - 印のあるフォルダは作品。その中（下の階層）の候補は外す
    - 印のないフォルダは、子のうち印のあるフォルダがちょうど1つで、ほかに印のある子孫がないなら、そのフォルダを作品にし、その子は外す
    - ほかの印のないフォルダは外す

- [ ] **Step 1: 失敗するテストを書く**（`$TestDrive` に作る。`New-TestDirs` と同じ小道具をこのファイルにも置く）

```powershell
Describe 'Get-UnknownWorks' {
  # games\かくう\Game.exe, games\かくう\www\(中), games\サークル\あ\Game.exe, games\サークル\い\Game.exe,
  # games\つつみ\Game\Game.exe, games\RJ01111111 すでに\Game.exe, games\なにもない\readme.txt, games\あーかいぶ.zip
  It '印のあるフォルダは作品' { $paths -contains (Join-Path $g 'かくう') | Should Be $true }
  It '作品の中のフォルダは外す' { @($paths | Where-Object { $_ -like '*かくう\www*' }).Count | Should Be 0 }
  It 'サークルのフォルダは外し、中の作品を出す' { $paths -contains (Join-Path $g 'サークル') | Should Be $false; $paths -contains (Join-Path $g 'サークル\あ') | Should Be $true }
  It '印のある子が1つだけなら外側を作品にする' { $paths -contains (Join-Path $g 'つつみ') | Should Be $true; $paths -contains (Join-Path $g 'つつみ\Game') | Should Be $false }
  It 'RJ番号のあるもの・印のないものは外す' { ... Should Be $false }
  It 'アーカイブは作品' { ... }
  It 'ExcludePaths の候補は外す' { ... }
}
```

- [ ] **Step 2: 実行して失敗を確かめる**（関数が見つからない）
- [ ] **Step 3: 2つの関数を書く**
- [ ] **Step 4: 実行して通ることを確かめる**
- [ ] **Step 5: コミット** — 「ブックマークにない作品のフォルダを見分ける処理を追加」

---

### Task 2: 中の手がかりと検索する言葉

**Files:** Modify `owned-identify.ps1`、`tests/owned-identify.Tests.ps1`

**Interfaces:**
- Produces:
  - `Find-InsideCodes([string]$Path) -> string[]`：中のファイル名と、200KB 未満の `.txt .url .html .htm .md .ini .json .nfo`（50 個まで）の中身から `$script:CodeRe` で探した RJ番号（大文字、重複なし、並びは見つけた順）。アーカイブなら空
  - `Get-InnerGameTitle([string]$Path) -> string`：`data\System.json` か `www\data\System.json` の `gameTitle` → `Game.ini` の `Title=`（Shift_JIS で読む）→ `package.json` の `window.title`、なければ `name` → `*_Data\app.info` の2行目。なければ ''
  - `New-SearchTerm([string]$Name) -> string`：`Normalize-Title` と同じ考えで、版・括弧の中・「体験版」などを除く。ただし空白は1つに残す（検索語なので）。アーカイブは拡張子を除く

- [ ] **Step 1: 失敗するテストを書く**

```powershell
Describe 'Find-InsideCodes' {
  It 'ファイル名から見つける' { ... | Should Be @('RJ00000101') }
  It 'テキストの中から見つける' { # readme.txt に "https://www.dlsite.com/maniax/work/=/product_id/RJ00000102.html"
  }
  It '2つあれば両方返す' { ... Count | Should Be 2 }
  It '大きいファイルは読まない' { # 300KB の .txt の中の番号は見つけない
  }
}
Describe 'Get-InnerGameTitle' {
  It 'ツクールMV/MZ の gameTitle' { ... | Should Be '架空のRPG' }
  It 'Game.ini の Title（Shift_JIS）' { ... }
  It 'package.json の window.title' { ... }
  It 'Unity の app.info の2行目' { ... }
  It 'なければ空' { ... | Should Be '' }
}
Describe 'New-SearchTerm' {
  It '版と括弧を除く' { New-SearchTerm 'かくうRPG_v1.02 (体験版)' | Should Be 'かくうRPG' }
  It 'アーカイブは拡張子を除く' { New-SearchTerm 'かくう ver2.zip' | Should Be 'かくう' }
}
```

- [ ] **Step 2〜4: 失敗 → 書く → 通る**
- [ ] **Step 5: コミット** — 「フォルダの中から RJ番号と作品名を探す処理を追加」

---

### Task 3: DLsite の検索と保存

**Files:** Modify `owned-identify.ps1`、`tests/owned-identify.Tests.ps1`。Create `tests/fixtures/dlsite-search-sample.json`。Modify `.gitignore`（`dlsite-search-cache.json`）

**Interfaces:**
- Produces:
  - `ConvertFrom-DLsiteSearch([string]$Json) -> object[]`：`search_result` の HTML の `<dd class="work_name">` ごとに、`product_id/(RJ…)\.html` と `title="…"`（HTML の文字参照を戻す）を読み、`@{ Code; Title }` を上から5件（同じ番号は1つ）
  - `Search-DLsite([string]$Term) -> pscustomobject`：`https://www.dlsite.com/maniax/fsr/ajax/=/language/jp/keyword/<UrlEncode>/` と `/home/` の同じ URL を順に取り、`@{ Ok = bool; Hits = @(@{ Code; Title; Floor }) }`。片方でも失敗したら `Ok = $false`（取れた分は返す）。2回の間に 800 ミリ秒
  - `Read-SearchCache([string]$Path) -> hashtable` / `Save-SearchCache([string]$Path, [hashtable]$Cache)`：`@{ 検索語 = @{ Ok; Hits; At（yyyy-MM-dd） } }`。UTF-8（BOMなし）
  - `Select-AutoCode($Hits, [string]$Term, [bool]$FromInnerTitle) -> string`：`$FromInnerTitle` が真で、`Normalize-Title` した作品名が `Normalize-Title $Term` と同じものが、全体でちょうど1つならその番号。ほかは ''

- [ ] **Step 1: テスト用の例を作る** — `tests/fixtures/dlsite-search-sample.json`：`{"search_result": "<dd class=\"work_name\">…<a href=\"https://www.dlsite.com/maniax/work/=/product_id/RJ00000201.html\" title=\"架空の作品 &amp; その2\">…</a></dd>" …, "page_info": {}}` を 6 件（うち1件は同じ番号の重複）。実物の形は、一般的な言葉の検索で確かめてある（`<dd class="work_name"><div class="icon_wrap"></div><div class="multiline_truncate"><a href="…/product_id/RJ….html" title="…">…</a></div></dd>`）
- [ ] **Step 2: 失敗するテストを書く**

```powershell
Describe 'ConvertFrom-DLsiteSearch' {
  It '上から5件、重複なし' { $h.Count | Should Be 5; $h[0].Code | Should Be 'RJ00000201' }
  It '文字参照を戻す' { $h[0].Title | Should Be '架空の作品 & その2' }
  It '形が違えば空' { @(ConvertFrom-DLsiteSearch '{"search_result":""}').Count | Should Be 0 }
}
Describe 'Select-AutoCode' {
  It '中の作品名で、完全一致が1つならその番号' { ... | Should Be 'RJ00000301' }
  It 'フォルダ名から作った言葉なら一致しても空' { ... | Should Be '' }
  It '全年齢と R18 で2つ一致したら空' { ... | Should Be '' }
}
Describe 'SearchCache' {
  It '保存して読み戻せる' { ... }
}
```

- [ ] **Step 3〜5: 失敗 → 書く → 通る**
- [ ] **Step 6: 一般的な言葉で1回だけ `Search-DLsite` を動かし、`Ok` が真で `Hits` が出ることを確かめる**（ユーザーのフォルダ名は使わない。作品名は表示せず件数だけ）
- [ ] **Step 7: コミット** — 「DLsite の検索と検索結果の保存を追加」

---

### Task 4: 対象をまとめる・番号を決める

**Files:** Modify `owned-rename.ps1`、`tests/owned-rename.Tests.ps1`

**Interfaces:**
- Consumes: Task 1〜3 の関数。1.8.0 の `Get-RenameTargets`、`Set-RenameNames`
- 対象の形を広げる：1.8.0 の `Code / Path / OldName / IsArchive / How / State / NewName / NewPath` に `Clue`（'bookmark' / 'inside' / 'search-exact' / 'search' / 'manual' / ''）、`Choices`（`@{ Code; Title }` の一覧）、`Auto`（最初からチェックするか）、`Term`、`FromInnerTitle` を足す。`Get-RenameTargets` の行は `Clue='bookmark'`、`Auto=$true`
- Produces:
  - `Get-UnknownTargets($Candidates, [string[]]$ExcludePaths, [string[]]$GameDirs) -> object[]`：`Get-UnknownWorks` の作品ごとに1行。`Find-InsideCodes` が1つなら `Code` と `Clue='inside'`・`Auto=$true`・`State='pending'`。それ以外は `Code=''`・`State='nocode'`、`Choices` に中で見つかった番号（2つ以上のとき。作品名は空）、`Term`（`Get-InnerGameTitle` があればそれと `FromInnerTitle=$true`、なければ `New-SearchTerm`）
  - `Set-SearchResults($Targets, [hashtable]$Cache) -> void`：`State='nocode'` の行に、保存した検索結果から `Choices` を足し、`Select-AutoCode` の番号があれば `Code`・`Clue='search-exact'`・`Auto=$true`・`State='pending'`。候補だけなら `Clue='search'`
  - `Set-TargetCode($Target, [string]$Input) -> bool`：RJ番号か URL から `$script:CodeRe` で番号を取り出して（大文字）`Code` に入れ、`Clue='manual'`（候補から選んだときは呼び出し側が 'search' のまま）、`State='pending'`、`NewName/NewPath` を空に戻す。取り出せなければ `$false`
  - `Test-DuplicateCodes($Targets) -> void`：`State` が 'ok' か 'pending' の行で同じ `Code` が2つ以上のパスにあれば、その行をすべて `State='dupcode'`
  - 一覧のための ExcludePaths：`Compare-Owned` の結果のうち `Status` が owned / maybe の `MatchPath`（呼び出し側の GUI が作る）

- [ ] **Step 1: 失敗するテストを書く**

```powershell
Describe 'Get-UnknownTargets / Set-SearchResults' {
  It '中の番号が1つなら pending・inside・Auto' { ... }
  It '中の作品名があれば検索語にする' { ... .Term | Should Be '架空のRPG'; .FromInnerTitle | Should Be $true }
  It '検索で一致が1つなら search-exact・Auto' { ... }
  It '候補だけなら nocode のまま Choices が入る' { ... }
}
Describe 'Set-TargetCode' {
  It 'URL から取り出す' { Set-TargetCode $t 'https://www.dlsite.com/maniax/work/=/product_id/rj00000401.html' | Should Be $true; $t.Code | Should Be 'RJ00000401' }
  It '番号がなければ受け付けない' { Set-TargetCode $t 'abc' | Should Be $false }
}
Describe 'Test-DuplicateCodes' {
  It '同じ番号が2つのフォルダにあれば両方 dupcode' { ... }
}
```

- [ ] **Step 2〜4: 失敗 → 書く → 通る**（`Set-RenameNames` は `State='pending'` だけを扱うので、そのまま使える）
- [ ] **Step 5: コミット** — 「ブックマークにない作品を名前を変える対象に加える」

---

### Task 5: 画面

**Files:** Modify `owned-gui.ps1`

**Interfaces:** Consumes Task 1〜4、`Get-DLsiteTitles`、1.8.0 の `Show-RenameDialog` / `Invoke-FolderRename`。`$SearchCachePath = Join-Path $PSScriptRoot 'dlsite-search-cache.json'`

- [ ] **Step 1: 対象を集める** — `Show-RenameDialog` で、`Get-RenameTargets` の行に `Get-UnknownTargets` の行を足す。ExcludePaths は `$script:Results` の owned / maybe の `MatchPath` と、`Get-RenameTargets` の行の `Path`
- [ ] **Step 2: 検索する** — 保存した結果にない `Term` を数え、「N 件を DLsite で検索します（送るのは検索する言葉だけ）。数分かかることがあります」と聞く。小さな進み具合の画面（「何件中何件」と「止める」ボタン）を `Show()` で出し、1件ごとに `Search-DLsite` → 保存 → `[System.Windows.Forms.Application]::DoEvents()`。止めたらそこで終わり。終わったら `Set-SearchResults`
- [ ] **Step 3: 作品名を取る** — `State='pending'` の番号をまとめて `Get-DLsiteTitles`（1.8.0 と同じ）。`Set-RenameNames`、`Test-DuplicateCodes`
- [ ] **Step 4: 一覧** — 列：変える / 今の名前 / RJ番号（`DataGridViewComboBoxColumn`、`Choices` を「RJ… 作品名」で並べる）/ 新しい名前 / 手がかり / 状態。チェックは `State -eq 'ok' -and $_.Auto` だけ最初から付ける。`State` が ok でなければチェックできない。状態の文字に `nocode`=番号が決まっていない、`dupcode`=複数のフォルダに同じ番号 を足す。手がかりの文字：bookmark=ブックマークと一致、inside=中に書いてある、search-exact=DLsite で検索（一致）、search=DLsite で検索（候補）、manual=自分で入れた
  - RJ番号を選んだ・右クリック「RJ番号を入れる…」（`InputBox`）で入れたら、`Set-TargetCode` → その番号だけ `Get-DLsiteTitles` → `Set-RenameNames` → `Test-DuplicateCodes` → その行（と同じ番号の行）を描き直す。選んだ・入れた行はチェックを付ける
  - 候補の行の RJ番号の欄をダブルクリックで DLsite の作品ページを開く
- [ ] **Step 5: 手で確かめる**（本物のフォルダは使わない）— 構文チェック、架空のフォルダだけを ② に入れた作業用コピーで起動して、一覧が開き、検索の画面が出て止められること。検索は一般的な言葉の名前のフォルダで1件だけ
- [ ] **Step 6: テスト全体と `node --test tests/` を流してコミット** — 「フォルダ名をそろえる一覧にブックマークにない作品を出す」

---

### Task 6: README と版

**Files:** Modify `README.md`、`as-patch-finder.user.js:4`（`@version 1.9.0`）

- [ ] **Step 1: README** — 「送るのは RJ番号だけ」の2か所を「RJ番号と検索する言葉だけ」に。「フォルダ名をそろえる」の節に、ブックマークにない作品（中の番号・DLsite の検索・自分で入れる）、最初からチェックが付く条件、`dlsite-search-cache.json` を足す
- [ ] **Step 2: 版を 1.9.0 にしてコミット** — 「ブックマークにない作品もフォルダ名をそろえられるようにする（AS Patch Finder 1.9.0）」
- [ ] **Step 3: タグとリリース** は main に取り込んで push するとき（ユーザーに確かめてから）
