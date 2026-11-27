# owned-gui.ps1 — 所持チェック（GUI 版）。「所持チェック.bat」をダブルクリックで起動します。
# すべてこのPCの中だけで処理します。ネットにアクセスするのは、DLsite から作品名を取るとき（送るのは RJ 番号だけ）と、「フォルダ名をそろえる」でブックマークにない作品を検索するとき（送るのは検索する言葉だけ）です。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'owned-core.ps1')
. (Join-Path $PSScriptRoot 'owned-identify.ps1')
. (Join-Path $PSScriptRoot 'owned-rename.ps1')

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace Win32 -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][Win32.Dpi]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

$SettingsPath = Join-Path $PSScriptRoot 'owned-gui-settings.json'
$BackupDir    = Join-Path $PSScriptRoot 'bookmark-backups'
$ReportPath   = Join-Path $PSScriptRoot 'owned-report.html'
$LinksPath    = Join-Path $PSScriptRoot 'owned-links.json'
$RenameLogDir = Join-Path $PSScriptRoot 'rename-logs'
$SearchCachePath = Join-Path $PSScriptRoot 'dlsite-search-cache.json'

# 「たぶん持っている」を自分で確かめた対応（読めなければ空から始める）
try { $script:Links = Read-OwnedLinks $LinksPath } catch { $script:Links = @{ Same = @{}; Diff = @{} } }
# 読み込んだ AS Patch Finder の検索結果（TSV）。@{ RJ番号 = 結果 }
$script:ASInfo = $null

$g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
# 注意: PowerShell の変数名は大文字小文字を区別しないので、イベントの $s（押されたボタン）とぶつからない名前にする
$script:DpiScale = $g.DpiX / 96.0
$g.Dispose()
function px([double]$v) { [int]($v * $script:DpiScale) }

$Font = New-Object System.Drawing.Font('Yu Gothic UI', 9.5)
$Bold = New-Object System.Drawing.Font('Yu Gothic UI', 9.5, [System.Drawing.FontStyle]::Bold)

# ---------- 共通の小道具 ----------

function Show-Info([string]$msg, [string]$title = '所持チェック') {
  [void][System.Windows.Forms.MessageBox]::Show($form, $msg, $title, 'OK', 'Information')
}
function Show-Error([string]$msg) {
  [void][System.Windows.Forms.MessageBox]::Show($form, $msg, 'エラー', 'OK', 'Error')
}
function Ask-YesNo([string]$msg, [string]$title = '確認') {
  [System.Windows.Forms.MessageBox]::Show($form, $msg, $title, 'YesNo', 'Question') -eq 'Yes'
}
# イベントの中で起きたエラーを画面に出す（出さないと何も起きないように見えてしまう）
function Invoke-Safe([scriptblock]$body) {
  try { & $body }
  catch {
    $form.Cursor = 'Default'
    Show-Error ("エラーが起きました:`n`n" + $_.Exception.Message)
  }
}

# ボタンの処理は Tag に入れておき、共通のハンドラから Invoke-Safe で呼ぶ
function New-Button([string]$text, [scriptblock]$onClick, [switch]$Primary) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text; $b.AutoSize = $true; $b.Font = $(if ($Primary) { $Bold } else { $Font })
  $b.Padding = New-Object System.Windows.Forms.Padding((px 6), (px 2), (px 6), (px 2))
  $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, (px 6), (px 4))
  if ($onClick) { $b.Tag = $onClick; $b.Add_Click({ param($s, $e) Invoke-Safe $s.Tag }) }
  return $b
}
function New-Flow {
  $f = New-Object System.Windows.Forms.FlowLayoutPanel
  $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'; $f.WrapContents = $true; $f.Dock = 'Fill'
  $f.Margin = New-Object System.Windows.Forms.Padding(0)
  return $f
}
function New-Label([string]$text) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $text; $l.AutoSize = $true; $l.Font = $Font
  $l.Margin = New-Object System.Windows.Forms.Padding(0, (px 6), (px 6), 0)
  return $l
}

# ---------- 画面 ----------

$form = New-Object System.Windows.Forms.Form
$form.Text = '所持チェック — 気になるリストとゲームフォルダの照らし合わせ'
$form.Font = $Font
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size((px 1060), (px 760))
$form.MinimumSize = New-Object System.Drawing.Size((px 760), (px 560))

$main = New-Object System.Windows.Forms.TableLayoutPanel
$main.Dock = 'Fill'; $main.ColumnCount = 1
[void]$main.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$main.Padding = New-Object System.Windows.Forms.Padding((px 10))
foreach ($i in 1..5) { [void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
$main.RowStyles[0] = New-Object System.Windows.Forms.RowStyle('Absolute', (px 250))
$main.RowStyles[3] = New-Object System.Windows.Forms.RowStyle('Percent', 100)
$form.Controls.Add($main)

# 1) 設定（気になるリスト／ゲームフォルダ）
$top = New-Object System.Windows.Forms.TableLayoutPanel
$top.Dock = 'Fill'; $top.ColumnCount = 2; $top.RowCount = 1
[void]$top.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 50)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 50)))
$main.Controls.Add($top, 0, 0)

function New-ListGroup([string]$title) {
  $gb = New-Object System.Windows.Forms.GroupBox
  $gb.Text = $title; $gb.Dock = 'Fill'; $gb.Font = $Bold
  $gb.Padding = New-Object System.Windows.Forms.Padding((px 8))
  $t = New-Object System.Windows.Forms.TableLayoutPanel
  $t.Dock = 'Fill'; $t.ColumnCount = 1; $t.Font = $Font
  [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
  [void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
  [void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
  $lb = New-Object System.Windows.Forms.ListBox
  $lb.Dock = 'Fill'; $lb.IntegralHeight = $false; $lb.HorizontalScrollbar = $true; $lb.Font = $Font
  $lb.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (px 6))
  $flow = New-Flow
  $t.Controls.Add($lb, 0, 0); $t.Controls.Add($flow, 0, 1)
  $gb.Controls.Add($t)
  return @{ Group = $gb; List = $lb; Buttons = $flow; Table = $t }
}

# 気になるリスト
$src = New-ListGroup '① 気になるリスト（DLsite の URL を読む場所）'
$top.Controls.Add($src.Group, 0, 0)

$bmMenu = New-Object System.Windows.Forms.ContextMenuStrip
$bmMenu.Font = $Font
$btnAddBm = New-Button 'ブラウザのブックマークを追加 ▼' {
  $bmMenu.Items.Clear()
  $found = @(Find-BrowserBookmarks)
  if ($found.Count -eq 0) { Show-Info 'Chrome / Edge のブックマークが見つかりませんでした。「ファイルを追加」から選んでください。'; return }
  foreach ($f in $found) {
    $it = $bmMenu.Items.Add("$($f.Label)    ($($f.Path))")
    $it.Tag = $f.Path
    $it.Add_Click({ param($s, $e) Invoke-Safe { Add-Source $s.Tag } })
  }
  $bmMenu.Show($btnAddBm, 0, $btnAddBm.Height)
}
$src.Buttons.Controls.Add($btnAddBm)
$src.Buttons.Controls.Add((New-Button 'ファイルを追加…' {
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Title = '気になるリストのファイルを選ぶ（Session Buddy のエクスポートなど）'
  $dlg.Filter = '対応するファイル|*.json;*.csv;*.txt;*.html;*.htm;Bookmarks|すべてのファイル|*.*'
  $dlg.Multiselect = $true
  if ($dlg.ShowDialog($form) -eq 'OK') { $dlg.FileNames | ForEach-Object { Add-Source $_ } }
}))
$src.Buttons.Controls.Add((New-Button '選んだものを外す' {
  if ($src.List.SelectedIndex -ge 0) { $src.List.Items.RemoveAt($src.List.SelectedIndex); Refresh-Folders; Save-Settings }
}))
$src.Buttons.Controls.Add((New-Button 'URL をまとめて追加…' { Show-BulkAdd }))

# ブックマークのどのフォルダを読むか（消すときもこのフォルダの中だけ）
$AllFolders = '（ブックマーク全体）'
$src.Buttons.Controls.Add((New-Label 'ブックマークのフォルダ:'))
$cmbFolder = New-Object System.Windows.Forms.ComboBox
$cmbFolder.DropDownStyle = 'DropDownList'; $cmbFolder.Width = (px 300); $cmbFolder.Font = $Font
$cmbFolder.Margin = New-Object System.Windows.Forms.Padding(0, (px 3), (px 6), 0)
$src.Buttons.Controls.Add($cmbFolder)
$cmbFolder.Add_SelectedIndexChanged({ if (-not $script:LoadingFolders) { Save-Settings } })

function Refresh-Folders([string]$want) {
  if (-not $want) { $want = "$($cmbFolder.SelectedItem)" }
  $script:LoadingFolders = $true
  $cmbFolder.Items.Clear()
  [void]$cmbFolder.Items.Add($AllFolders)
  $seen = @{}
  foreach ($p in @($src.List.Items | ForEach-Object { "$_" } | Where-Object { Test-BookmarksFile $_ })) {
    try { foreach ($f in Get-BookmarkFolderPaths $p) { if (-not $seen[$f]) { $seen[$f] = 1; [void]$cmbFolder.Items.Add($f) } } } catch { }
  }
  # 前に選んでいたフォルダが今は見つからない場合も、勝手に「全体」に変えないで残しておく
  if ($want -and $want -ne $AllFolders -and -not $cmbFolder.Items.Contains($want)) { [void]$cmbFolder.Items.Add($want) }
  $cmbFolder.SelectedItem = $(if ($want -and $cmbFolder.Items.Contains($want)) { $want } else { $AllFolders })
  $script:LoadingFolders = $false
}

function Get-SelectedFolder {
  $f = "$($cmbFolder.SelectedItem)"
  if (-not $f -or $f -eq $AllFolders) { return '' } else { return $f }
}

function Add-Source([string]$p) {
  if (-not $src.List.Items.Contains($p)) { [void]$src.List.Items.Add($p); Refresh-Folders; Save-Settings }
}

# ゲームフォルダ
$gd = New-ListGroup '② ゲームフォルダ'
$top.Controls.Add($gd.Group, 1, 0)
$gd.Buttons.Controls.Add((New-Button 'フォルダを追加…' {
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = 'ゲームを置いているフォルダを選んでください'
  if ($dlg.ShowDialog($form) -eq 'OK' -and -not $gd.List.Items.Contains($dlg.SelectedPath)) {
    [void]$gd.List.Items.Add($dlg.SelectedPath); Save-Settings
  }
}))
$gd.Buttons.Controls.Add((New-Button '選んだものを外す' {
  if ($gd.List.SelectedIndex -ge 0) { $gd.List.Items.RemoveAt($gd.List.SelectedIndex); Save-Settings }
}))

# 2) 実行ボタンと状態表示
$act = New-Flow
$main.Controls.Add($act, 0, 1)
$btnRun = New-Button '③ チェック開始' { Run-Check } -Primary
$act.Controls.Add($btnRun)
$act.Controls.Add((New-Button 'レポートをブラウザで開く' {
  if (Test-Path -LiteralPath $ReportPath) { Start-Process $ReportPath } else { Show-Info '先に「チェック開始」を押してください。' }
}))
$act.Controls.Add((New-Button '持っていない作品をASで検索' { Open-ASSearch }))
$act.Controls.Add((New-Button '持っている作品の更新をASで確認' { Open-ASOwned }))
$act.Controls.Add((New-Label '  見る深さ'))
$numDepth = New-Object System.Windows.Forms.NumericUpDown
$numDepth.Minimum = 1; $numDepth.Maximum = 6; $numDepth.Value = 2; $numDepth.Width = (px 48)
$numDepth.Margin = New-Object System.Windows.Forms.Padding(0, (px 3), (px 6), 0)
$act.Controls.Add($numDepth)
$act.Controls.Add((New-Label '判定の厳しさ'))
$numTh = New-Object System.Windows.Forms.NumericUpDown
$numTh.DecimalPlaces = 2; $numTh.Increment = 0.05; $numTh.Minimum = 0.3; $numTh.Maximum = 0.95; $numTh.Value = 0.6; $numTh.Width = (px 58)
$numTh.Margin = New-Object System.Windows.Forms.Padding(0, (px 3), (px 12), 0)
$act.Controls.Add($numTh)
$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($numDepth, "ゲームフォルダの何階層下まで見るか。`n例: Games\サークル名\作品名 なら 2")
$tip.SetToolTip($numTh, "「たぶん持っている」にする似かたの基準。`n関係ない作品が混ざるときは上げてください。")
$lblStatus = New-Label '「気になるリスト」と「ゲームフォルダ」を追加して、「チェック開始」を押してください。'
$act.Controls.Add($lblStatus)

# 3) 表示の絞り込み
$flt = New-Flow
$main.Controls.Add($flt, 0, 2)
$flt.Controls.Add((New-Label '表示:'))
function New-Check([string]$text, [bool]$on) {
  $c = New-Object System.Windows.Forms.CheckBox
  $c.Text = $text; $c.Checked = $on; $c.AutoSize = $true
  $c.Margin = New-Object System.Windows.Forms.Padding(0, (px 4), (px 10), 0)
  $c.Add_CheckedChanged({ Invoke-Safe { Fill-Grid } })
  $flt.Controls.Add($c)
  return $c
}
$chkOwned = New-Check '持っている' $true
$chkMaybe = New-Check 'たぶん持っている' $true
$chkNot   = New-Check '持っていない' $true
$flt.Controls.Add((New-Label '（作品名をダブルクリックで DLsite、手元の候補でフォルダ、AS の欄でスレッドを開きます。右クリックで対応を覚えられます）'))

# 4) 結果の表
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
$grid.RowHeadersVisible = $false; $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false
$grid.AutoSizeRowsMode = 'AllCells'; $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
$grid.ColumnHeadersHeightSizeMode = 'AutoSize'
$grid.DefaultCellStyle.WrapMode = 'True'
$colDel = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colDel.HeaderText = '消す'; $colDel.Name = 'Del'; $colDel.Width = (px 46)
[void]$grid.Columns.Add($colDel)
foreach ($c in @(
  @{ N = 'Status'; H = '判定';       W = 110 },
  @{ N = 'Title';  H = '作品名（気になるリスト）'; W = 330 },
  @{ N = 'Code';   H = 'RJ番号';     W = 100 },
  @{ N = 'AS';     H = 'AS';         W = 150 },
  @{ N = 'Match';  H = '手元の候補'; W = 300 },
  @{ N = 'Score';  H = '似かた';     W = 72 }
)) {
  $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
  $col.Name = $c.N; $col.HeaderText = $c.H; $col.Width = (px $c.W); $col.ReadOnly = $true
  [void]$grid.Columns.Add($col)
}
$grid.Columns['Title'].AutoSizeMode = 'Fill'
$grid.Columns['Match'].AutoSizeMode = 'Fill'
$main.Controls.Add($grid, 0, 3)

# チェックボックスの変更をすぐ反映する
$grid.Add_CurrentCellDirtyStateChanged({ if ($grid.IsCurrentCellDirty) { $grid.CommitEdit('CurrentCellChange') } })
$grid.Add_CellValueChanged({ param($s, $e) Invoke-Safe {
  if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 0 -and -not $script:Filling) {
    $r = $grid.Rows[$e.RowIndex].Tag
    $script:DelState[$r.Code] = [bool]$grid.Rows[$e.RowIndex].Cells['Del'].Value
    Update-DeleteButton
  }
} })
$grid.Add_CellDoubleClick({ param($s, $e) Invoke-Safe {
  if ($e.RowIndex -lt 0) { return }
  $r = $grid.Rows[$e.RowIndex].Tag
  $name = $grid.Columns[$e.ColumnIndex].Name
  $info = if ($script:ASInfo) { $script:ASInfo[$r.Code] } else { $null }
  if ($name -eq 'Match' -and $r.MatchPath) { Start-Process explorer.exe "/select,`"$($r.MatchPath)`"" }
  elseif ($name -eq 'AS' -and $info -and $info.Url) { Start-Process $info.Url }
  elseif ($name -eq 'AS') { Start-Process "https://www.anime-sharing.com/search/search?keywords=$($r.Code)" }
  elseif ($name -ne 'Del') { Start-Process $r.Url }
} })

# 右クリック：手元の候補が同じ作品か別の作品かを覚える（次のチェックから使う）
$rowMenu = New-Object System.Windows.Forms.ContextMenuStrip
$rowMenu.Font = $Font
$miSame = $rowMenu.Items.Add('この手元の候補で合っている（次から「持っている」にする）')
$miDiff = $rowMenu.Items.Add('この手元の候補は別の作品（次から候補にしない）')
$miForget = $rowMenu.Items.Add('この作品について覚えたことを忘れる')
$grid.ContextMenuStrip = $rowMenu
# 開くときに、マウスの下の行を対象にする（行の外なら開かない）
$rowMenu.Add_Opening({ param($s, $e)
  $pt = $grid.PointToClient([System.Windows.Forms.Cursor]::Position)
  $hit = $grid.HitTest($pt.X, $pt.Y)
  if ($hit.RowIndex -lt 0) { $e.Cancel = $true; return }
  $grid.ClearSelection(); $grid.Rows[$hit.RowIndex].Selected = $true
  $r = $grid.Rows[$hit.RowIndex].Tag
  $script:MenuRow = $r
  $path = Get-RowCandidatePath $r
  $miSame.Enabled = [bool]$path -and -not $r.Confirmed
  $miDiff.Enabled = [bool]$path
  $miForget.Enabled = [bool]($script:Links.Same[$r.Code] -or $script:Links.Diff[$r.Code])
})
$miSame.Add_Click({ Invoke-Safe { Set-RowLink $true } })
$miDiff.Add_Click({ Invoke-Safe { Set-RowLink $false } })
$miForget.Add_Click({ Invoke-Safe {
  Clear-OwnedLink $script:Links $script:MenuRow.Code
  Save-OwnedLinks $LinksPath $script:Links
  Run-Check -ReuseCandidates -KeepChecks
} })

# 5) ブックマークの削除・復元
$bot = New-Flow
$main.Controls.Add($bot, 0, 4)
$btnDel = New-Button '④ チェックした作品をブックマークから消す' { Delete-Checked } -Primary
$btnDel.Enabled = $false
$bot.Controls.Add($btnDel)
$bot.Controls.Add((New-Button 'バックアップから戻す…' { Restore-Backup }))
$bot.Controls.Add((New-Button 'バックアップのフォルダを開く' {
  New-Item -ItemType Directory -Force $BackupDir | Out-Null; Start-Process explorer.exe $BackupDir
}))
$bot.Controls.Add((New-Button 'ASの結果を読み込む…' { Import-ASResults }))
$bot.Controls.Add((New-Button 'ASで見つかった作品をフォルダにまとめる…' { Move-ASFound }))
$bot.Controls.Add((New-Button 'フォルダ名をそろえる…' { Show-RenameDialog }))
$bot.Controls.Add((New-Button 'フォルダ名を戻す…' { Undo-Rename }))
$bot.Controls.Add((New-Label '※ 消す・まとめるときはブラウザを完全に終了しておいてください。毎回バックアップを取ります。'))

# ---------- 処理 ----------

$script:Results = @()
$script:DelState = @{}
$StatusText = @{ owned = '持っている'; maybe = 'たぶん持っている'; notowned = '持っていない' }
$StatusColor = @{
  owned = [System.Drawing.Color]::FromArgb(222, 244, 226)
  maybe = [System.Drawing.Color]::FromArgb(255, 243, 205)
  notowned = [System.Drawing.SystemColors]::Window
}

# ゲームフォルダの候補を集める。「チェック開始」では毎回調べ直す。
# 削除のあとと「まとめて追加」は、同じフォルダ・同じ深さで調べた結果があればそれを使う（フォルダを調べ直すのは時間がかかるため）
$script:CandCache = $null
function Get-Candidates([switch]$Reuse) {
  $dirs = @($gd.List.Items | ForEach-Object { "$_" })
  $depth = [int]$numDepth.Value
  $key = ($dirs -join '|') + "|$depth"
  if ($Reuse -and $script:CandCache -and $script:CandCache.Key -eq $key) {
    $script:MissingGameDirs = $script:CandCache.Missing
    return ,$script:CandCache.Cands
  }
  $c = Get-GameCandidates $dirs $depth
  $script:CandCache = @{ Key = $key; Cands = $c; Missing = @($script:MissingGameDirs) }
  return ,$c
}

# 行の作品の手元の候補（「持っていない」なら、参考に出している「いちばん近い」候補）
function Get-RowCandidatePath($r) { if ($r.MatchPath) { $r.MatchPath } else { $r.NearPath } }

# 右クリックの「合っている」「別の作品」
function Set-RowLink([bool]$same) {
  $r = $script:MenuRow
  $path = Get-RowCandidatePath $r
  if (-not $r -or -not $path) { return }
  Set-OwnedLink $script:Links $r.Code $path $same
  Save-OwnedLinks $LinksPath $script:Links
  Run-Check -ReuseCandidates -KeepChecks
}

# -ReuseCandidates: ゲームフォルダは調べ直さず、前回の候補で照らし合わせ直す（ブックマークを消したあと用）
# -KeepChecks: 判定が変わらなかった作品は、「消す」のチェックを今のまま残す（右クリックで対応を覚えたあと用）
function Run-Check([switch]$ReuseCandidates, [switch]$KeepChecks) {
  $prevStatus = @{}
  if ($KeepChecks) { foreach ($r in $script:Results) { $prevStatus[$r.Code] = $r.Status } }
  $prevDel = $script:DelState
  $sources = @($src.List.Items | ForEach-Object { "$_" })
  $dirs = @($gd.List.Items | ForEach-Object { "$_" })
  if ($sources.Count -eq 0) { Show-Info '① の「気になるリスト」を追加してください。'; return }
  if ($dirs.Count -eq 0) { Show-Info '② の「ゲームフォルダ」を追加してください。'; return }
  Save-Settings
  $form.Cursor = 'WaitCursor'; $btnRun.Enabled = $false
  try {
    $lblStatus.Text = '気になるリストを読んでいます…'; $form.Refresh()
    $folder = Get-SelectedFolder
    $wish = @(Read-Wishlist $sources $folder)
    if ($wish.Count -eq 0) {
      $lblStatus.Text = 'DLsite の作品URLが見つかりませんでした。'
      $hint = if ($folder) { "`n選んでいるブックマークのフォルダ「$folder」が正しいか確認してください。" } else { "`n別のファイルや別の形式でエクスポートしたものを試してください。" }
      Show-Info ("気になるリストの中に DLsite の作品URL（RJ番号入り）が見つかりませんでした。" + $hint)
      return
    }
    if (-not $ReuseCandidates) { $lblStatus.Text = 'ゲームフォルダを調べています…'; $form.Refresh() }
    $cands = Get-Candidates -Reuse:$ReuseCandidates
    $lblStatus.Text = '照らし合わせています…'; $form.Refresh()
    $script:Results = @(Compare-Owned $wish $cands ([double]$numTh.Value) $script:Links)
    Write-OwnedReport $script:Results $wish.Count $cands.Count ([double]$numTh.Value) $ReportPath
    # 初期状態：「持っている」は消す対象、「たぶん」は自分で選ぶ
    $script:DelState = @{}
    foreach ($r in $script:Results) {
      $keep = $KeepChecks -and $prevStatus[$r.Code] -eq $r.Status -and $prevDel.ContainsKey($r.Code)
      $script:DelState[$r.Code] = $(if ($keep) { [bool]$prevDel[$r.Code] } else { $r.Status -eq 'owned' })
    }
    Fill-Grid
    $o = @($script:Results | Where-Object Status -eq 'owned').Count
    $m = @($script:Results | Where-Object Status -eq 'maybe').Count
    $n = @($script:Results | Where-Object Status -eq 'notowned').Count
    $lblStatus.Text = "気になるリスト $($wish.Count) 作品 ／ 手元 $($cands.Count) 件 → 持っている $o ・ たぶん $m ・ 持っていない $n"
    $cf = @($script:Results | Where-Object Confirmed).Count
    if ($cf) { $lblStatus.Text += "（確かめた対応 $cf 作品を含む）" }
    $missing = @($script:MissingGameDirs)
    if ($missing.Count) {
      $lblStatus.Text += " ／ 見つからないゲームフォルダ $($missing.Count) か所を飛ばしました"
      # 削除のあとの照らし合わせ直しでは、同じ知らせを2回出さない
      if (-not $ReuseCandidates) { Show-Info ("次のゲームフォルダが見つからなかったので、飛ばして判定しました。`n（ドライブがつながっているか確かめてください。この中の作品は「持っていない」になっています）`n`n" + ($missing -join "`n")) }
    }
  } finally {
    $form.Cursor = 'Default'; $btnRun.Enabled = $true
  }
}

# 「持っていない」作品の RJ 番号を付けて AS の検索ページをブラウザで開く。
# 検索は AS Patch Finder（Tampermonkey）がブラウザの中で1件ずつ行う。
# 番号は URL の # より後ろに入れるので、ページを開いた時点ではサーバーに送られない。
function Open-ASSearch {
  if (-not $script:Results) { Show-Info '先に「チェック開始」を押してください。'; return }
  $notOwned = @($script:Results | Where-Object Status -eq 'notowned')
  $codes = @($notOwned | ForEach-Object Code)
  if ($codes.Count -eq 0) { Show-Info '「持っていない」作品がありません。'; return }
  $msg = "「持っていない」$($codes.Count) 作品を anime-sharing で順番に検索します。`n`n" +
         "ブラウザで AS の検索ページが開くので、上に出る「自動検索」の「開始」を押してください。`n`n" +
         "RJ番号で見つからない作品を作品名でも探したいときは、開始の前に「RJ番号を貼り付け…」を押して、" +
         "Ctrl+V で貼り付けてから「このリストにする」を押してください（作品名をクリップボードにコピーしておきます）。`n" +
         "（Tampermonkey と AS Patch Finder 1.5.0 以降が必要です）`n`n開きますか？"
  if (-not (Ask-YesNo $msg 'AS で検索')) { return }
  # 「RJ番号 [タブ] 作品名」の行。作品名はURLに入れると長すぎるので、クリップボードで渡す
  $lines = @($notOwned | ForEach-Object {
    $t = if ($_.Title -and $_.Title -ne '(タイトル不明)') { ($_.Title -replace '[\t\r\n]+', ' ') } else { '' }
    if ($t) { "$($_.Code)`t$t" } else { $_.Code }
  })
  try { [System.Windows.Forms.Clipboard]::SetText(($lines -join "`r`n")) }
  catch { Show-Info "作品名をクリップボードにコピーできませんでした（$($_.Exception.Message)）。`nRJ番号だけで検索します。作品名でも探したいときは、もう一度このボタンを押してください。" }
  Start-Process ('https://www.anime-sharing.com/search/#apf-auto=' + ($codes -join ','))
}

# 持っている作品（RJ番号がわかるもの）を、フォルダ名から読んだ版といっしょに AS Patch Finder に渡す。
# AS Patch Finder の「持っている作品」のリストに入り、検索するとASの最新と手元の版を比べる。
# 渡すのは URL の # より後ろなので、ページを開いた時点ではサーバーに送られない。
function Open-ASOwned {
  $sources = @($src.List.Items | ForEach-Object { "$_" })
  $dirs = @($gd.List.Items | ForEach-Object { "$_" })
  if ($dirs.Count -eq 0) { Show-Info '② の「ゲームフォルダ」を追加してください。'; return }
  $form.Cursor = 'WaitCursor'
  try {
    $lblStatus.Text = '持っている作品を集めています…'; $form.Refresh()
    $cands = Get-Candidates -Reuse
    $owned = @(Get-OwnedWorks $sources (Get-SelectedFolder) $BackupDir $cands ([double]$numTh.Value) $script:Links)
  } finally { $form.Cursor = 'Default' }
  $withVer = @($owned | Where-Object Version).Count
  $lblStatus.Text = "持っている作品（RJ番号がわかるもの） $($owned.Count) 作品 ／ フォルダ名に版があるもの $withVer 作品"
  if ($owned.Count -eq 0) {
    Show-Info ("RJ番号がわかる持っている作品が見つかりませんでした。`n`n" +
      "持っている作品は、① の気になるリストとブックマークのバックアップ（消したブックマーク）から作品名の一致で探すほか、フォルダ名に RJ番号が入っているものを使います。")
    return
  }
  $parts = @($owned | ForEach-Object { if ($_.Version) { "$($_.Code)~$([uri]::EscapeDataString($_.Version))" } else { $_.Code } })
  $url = 'https://www.anime-sharing.com/search/#apf-owned=' + ($parts -join ',')
  if ($url.Length -gt 30000) { Show-Error "作品が多すぎて渡せません（$($owned.Count) 作品）。"; return }
  $missing = @($script:MissingGameDirs).Count
  $msg = "持っている $($owned.Count) 作品を、AS Patch Finder の「持っている作品」のリストに入れます。`n" +
         "（RJ番号がわかるものだけ。① の気になるリストとブックマークのバックアップから作品名の一致で探したもの、フォルダ名に RJ番号があるもの）`n`n" +
         "・フォルダ名から手元の版を読めたもの: $withVer 作品（ほかは AS のパネルで手で入れられます）`n" +
         $(if ($missing) { "・見つからないゲームフォルダ $missing か所は飛ばしました`n" } else { '' }) +
         "`nブラウザで AS の検索ページが開くので、「開始」を押すと順番に検索し、手元の版より新しい版があれば印を付けます。`n" +
         "（Tampermonkey と AS Patch Finder 1.7.0 以降が必要です）`n`n開きますか？"
  if (-not (Ask-YesNo $msg 'AS で更新を確認')) { return }
  Start-Process $url
}

# 表の「AS」の欄の文字
function Get-ASText([string]$code) {
  if (-not $script:ASInfo) { return '' }
  $i = $script:ASInfo[$code]
  if (-not $i) { return '（読み込んだ結果になし）' }
  if (-not $i.Found) { return $i.Kind }
  $t = "見つかった $($i.Count) 件"
  if ($i.Version) { $t += "`n最新 $($i.Version)" }
  if ($i.Patch) { $t += ' パッチ/翻訳' }
  if ($i.Mark) { $t += "`n[$($i.Mark)]" }
  return $t
}

# AS Patch Finder の「ファイルに保存（TSV）」で保存した結果を読み込み、表の「AS」の欄に出す
function Import-ASResults {
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Title = 'AS Patch Finder の検索結果（TSV）を選ぶ'
  $dlg.Filter = 'AS Patch Finder の結果|as-search-*.tsv|TSV|*.tsv|すべてのファイル|*.*'
  $dl = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
  if (Test-Path -LiteralPath $dl) {
    $dlg.InitialDirectory = $dl
    # いちばん新しい結果を最初から選んでおく
    $latest = Get-ChildItem -LiteralPath $dl -Filter 'as-search-*.tsv' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { $dlg.FileName = $latest.Name }
  }
  if ($dlg.ShowDialog($form) -ne 'OK') { return }
  $script:ASInfo = Read-ASResults $dlg.FileName
  $found = @($script:ASInfo.Values | Where-Object Found).Count
  Fill-Grid
  $msg = "$(Split-Path $dlg.FileName -Leaf) を読み込みました（$($script:ASInfo.Count) 作品・見つかった $found 作品）。"
  if (-not $script:Results) { $msg += "`n「チェック開始」を押すと、表の「AS」の欄に出ます。" }
  Show-Info $msg
}

# 読み込んだ AS の結果で見つかった作品のブックマークを、① で選んでいるフォルダの中のサブフォルダにまとめる
# （サブフォルダもこのフォルダの中なので、気になるリストからは外れない）
function Move-ASFound {
  if (-not $script:ASInfo) { Show-Info '先に「ASの結果を読み込む…」で、AS Patch Finder で保存した TSV を読み込んでください。'; return }
  if (-not $script:Results) { Show-Info '先に「チェック開始」を押してください。'; return }
  $folder = Get-SelectedFolder
  if (-not $folder) { Show-Info '先に ① の「ブックマークのフォルダ」で、気になるリストのフォルダを選んでください（その中にサブフォルダを作ります）。'; return }
  $target = Get-TargetBookmarks 'まとめる'
  if (-not $target) { return }
  # 持っている作品は消す対象なので除く。「見送り」の印を付けた作品も除く
  $rows = @($script:Results | Where-Object { $_.Status -ne 'owned' -and $script:ASInfo[$_.Code].Found })
  $skipN = @($rows | Where-Object { $script:ASInfo[$_.Code].Mark -eq '見送り' }).Count
  $codes = @($rows | Where-Object { $script:ASInfo[$_.Code].Mark -ne '見送り' } | ForEach-Object Code)
  if ($codes.Count -eq 0) { Show-Info 'まとめる作品がありません（AS で見つかった「持っていない」「たぶん」の作品がありません）。'; return }

  Add-Type -AssemblyName Microsoft.VisualBasic
  $name = [Microsoft.VisualBasic.Interaction]::InputBox(
    "AS で見つかった $($codes.Count) 作品のブックマークを、「$folder」の中のこのフォルダにまとめます（なければ作ります）。`n`nフォルダ名:",
    'フォルダにまとめる', 'ASで見つかった')
  if (-not $name.Trim()) { return }
  $plan = Move-BookmarksToSubfolder $target $folder $name.Trim() $codes $BackupDir -DryRun
  if ($plan.Moved.Count -eq 0) { Show-Info "まとめるものはありません（どれもすでに「$($name.Trim())」の中にあります）。"; return }
  $msg = "「$folder / $($name.Trim())」に $($plan.Moved.Count) 作品のブックマークを移します。" +
         $(if ($plan.Created) { "`n・フォルダはまだないので作ります" } else { '' }) +
         $(if ($skipN) { "`n・「見送り」の印を付けた $skipN 作品は移しません" } else { '' }) +
         "`n`n移す前にバックアップを取ります。よろしいですか？"
  $synced = Test-BookmarksSynced $target
  if ($synced -and -not (Get-EdgeProfileDir $target)) { Show-Info $SyncedOtherBrowserMsg; return }
  if (-not (Ask-YesNo $msg 'まとめる確認')) { return }
  if ($synced) {
    if ((Invoke-BookmarkOpInEdge $target 'move' $folder $codes $null $name.Trim()) -in 'changed', 'partial') { Refresh-Folders }
    return
  }
  if (-not (Wait-BrowserClosed $target)) { return }
  $r = Move-BookmarksToSubfolder $target $folder $name.Trim() $codes $BackupDir
  Show-Info "$($r.Moved.Count) 作品を移しました。`n（バックアップ: $(Split-Path $r.Backup -Leaf)）" 'まとめた結果'
  Refresh-Folders
}

# ---------- フォルダ名をそろえる ----------

$RenameStateText = @{
  ok = '変えられる'; multi = '複数の作品に当たる'; notitle = '作品名が取れなかった'; exists = '同じ名前がもうある'
  nocode = 'RJ番号が決まっていない'; dupcode = '複数のフォルダに同じ番号'; pending = '作品名を取っていない'
}
$RenameClueText = @{
  bookmark = 'ブックマークと一致'; inside = '中に書いてある'; 'search-exact' = 'DLsite で検索（一致）'
  search = 'DLsite で検索（候補）'; manual = '自分で入れた'; '' = '見つからなかった'
}
# 取った正式な作品名（RJ番号 → 作品名）。画面を開き直しても取り直さない
$script:RenameTitles = @{}

# 正式な作品名を、まだ取っていない番号だけ DLsite から取る（送るのは RJ番号だけ）。取れなかった数を返す
function Update-RenameTitles([string[]]$Codes) {
  $need = @($Codes | Where-Object { $_ -and -not $script:RenameTitles.ContainsKey($_) } | Select-Object -Unique)
  if ($need.Count -eq 0) { return 0 }
  $got = Get-DLsiteTitles $need
  foreach ($k in $got.Keys) { $script:RenameTitles[$k] = $got[$k] }
  return [int]$script:DLsiteFailedCount
}

# 検索する言葉を1件ずつ DLsite で検索し、結果を $Cache に入れて保存する。進み具合と「止める」を出す。検索した数を返す
function Invoke-RenameSearch([string[]]$Terms, [hashtable]$Cache) {
  $pf = New-Object System.Windows.Forms.Form
  $pf.Text = 'DLsite で検索しています'; $pf.Font = $Font; $pf.StartPosition = 'CenterParent'
  $pf.FormBorderStyle = 'FixedDialog'; $pf.ControlBox = $false; $pf.AutoSize = $true; $pf.AutoSizeMode = 'GrowAndShrink'
  $pf.Padding = New-Object System.Windows.Forms.Padding((px 12))
  $pfl = New-Flow; $pfl.FlowDirection = 'TopDown'
  $plbl = New-Label "0 / $($Terms.Count) 件"; $plbl.MinimumSize = New-Object System.Drawing.Size((px 320), 0)
  $script:RenameStop = $false
  $pbtn = New-Button '止める' { $script:RenameStop = $true }
  $pfl.Controls.Add($plbl); $pfl.Controls.Add($pbtn); $pf.Controls.Add($pfl)
  # Alt+F4 で閉じられたら止める（閉じたまま検索が続き、本体の画面が操作できなくなるのを防ぐ）
  $pf.Add_FormClosing({ $script:RenameStop = $true })
  # Show() では CenterParent が効かないので、表示してから親の真ん中に動かす
  $pf.StartPosition = 'Manual'; $pf.Show($form)
  $pf.Location = New-Object System.Drawing.Point(($form.Left + [int](($form.Width - $pf.Width) / 2)), ($form.Top + [int](($form.Height - $pf.Height) / 2)))
  $form.Enabled = $false
  $n = 0; $failRun = 0; $gaveUp = $false
  try {
    foreach ($term in $Terms) {
      if ($script:RenameStop) { break }
      $plbl.Text = "$n / $($Terms.Count) 件（止めても、そこまでの結果は使えます）"
      [System.Windows.Forms.Application]::DoEvents()
      $r = Search-DLsite $term -Pump { [System.Windows.Forms.Application]::DoEvents() }
      $Cache[$term] = [pscustomobject]@{ Ok = $r.Ok; At = (Get-Date -Format 'yyyy-MM-dd'); Hits = @($r.Hits) }
      $n++
      # つながらないことが3回続いたら止める（1件で最大 10 秒待つため）
      if ($r.Ok) { $failRun = 0 } else { $failRun++; if ($failRun -ge 3) { $gaveUp = $true; break } }
      if ($n % 10 -eq 0) { try { Save-SearchCache $SearchCachePath $Cache } catch { } }
      # 次の問い合わせまで 800 ミリ秒あける（その間も「止める」を受け付ける）
      for ($i = 0; $i -lt 8 -and -not $script:RenameStop; $i++) { Start-Sleep -Milliseconds 100; [System.Windows.Forms.Application]::DoEvents() }
    }
  } finally {
    # 先に本体の画面を戻す（保存に失敗しても操作できなくならないように）
    $form.Enabled = $true; $pf.Close()
    try { Save-SearchCache $SearchCachePath $Cache } catch { Show-Error "検索の結果を保存できませんでした（次回また検索します）:`n$($_.Exception.Message)" }
  }
  if ($gaveUp) { Show-Info "DLsite につながらないことが続いたので、検索を止めました（$n 件まで調べました）。`nネットにつながっているか確かめてから、もう一度「フォルダ名をそろえる…」を押すと、残りを検索します。" }
  return $n
}

# 名前を変えるフォルダ・アーカイブを集め、「RJ番号 正式な作品名 v版」にそろえる。
#   ・ブックマーク（とバックアップ）で「持っている」になった作品
#   ・ブックマークに当たらない作品：中に書いてある RJ番号、DLsite の検索、自分で入れた番号
# 一覧で確かめてから、チェックしたものだけ変える。変えた記録は rename-logs に残し、「フォルダ名を戻す…」で戻せる
function Show-RenameDialog {
  if (-not $script:Results) { Show-Info '先に「チェック開始」を押してください。'; return }
  $sources = @($src.List.Items | ForEach-Object { "$_" })
  $dirs = @($gd.List.Items | ForEach-Object { "$_" })
  $form.Cursor = 'WaitCursor'
  try {
    $lblStatus.Text = '名前を変えるフォルダを集めています…'; $form.Refresh()
    $cands = Get-Candidates -Reuse
    $wish = @(Get-OwnedWishlist $sources (Get-SelectedFolder) $BackupDir)
    $known = @(Get-RenameTargets $wish $cands ([double]$numTh.Value) $script:Links $dirs)
    # ブックマークで当たった候補と「たぶん」の候補は、ブックマークにない作品として扱わない
    $excl = @(@($script:Results | Where-Object { $_.Status -in 'owned', 'maybe' -and $_.MatchPath } | ForEach-Object MatchPath) + @($known | ForEach-Object Path))
    $lblStatus.Text = 'ブックマークにない作品を調べています…'; $form.Refresh()
    $unknown = @(Get-UnknownTargets $cands $excl $dirs {
      param($i, $n)
      $lblStatus.Text = "ブックマークにない作品を調べています…（$i / $n）"; [System.Windows.Forms.Application]::DoEvents()
    })
  } finally { $form.Cursor = 'Default' }
  $targets = @($known + $unknown)
  if ($targets.Count -eq 0) {
    $lblStatus.Text = '名前を変えられるフォルダはありません。'
    Show-Info "名前を変えられるフォルダはありません。`n（名前に RJ番号が入っていない作品が見つかりませんでした。「たぶん持っている」は、右クリックで確かめると対象になります）"
    return
  }

  # ブックマークにない作品で番号がわからないものを DLsite で検索する（保存した結果があるものは検索しない）
  $cache = Read-SearchCache $SearchCachePath
  $terms = @($unknown | Where-Object { $_.State -eq 'nocode' -and $_.Term } | ForEach-Object Term | Select-Object -Unique |
             Where-Object { -not $cache.ContainsKey($_) -or -not $cache[$_].Ok })
  if ($terms.Count) {
    $q = "ブックマークにない作品のうち、RJ番号がわからないもの $($terms.Count) 件を DLsite で検索します。`n" +
         "送るのは検索する言葉（ゲームの中の作品名か、フォルダ名を整えたもの）だけです。1件に1秒ほどかかり、途中で止められます。`n`n" +
         "検索しますか？（「いいえ」でも、一覧で自分で RJ番号を入れられます）"
    if (Ask-YesNo $q 'DLsite で検索') { [void](Invoke-RenameSearch $terms $cache) }
  }
  Set-SearchResults $targets $cache

  $codes = @($targets | Where-Object { $_.State -eq 'pending' } | ForEach-Object Code | Where-Object { -not $script:RenameTitles.ContainsKey($_) } | Select-Object -Unique)
  $failedFetch = 0
  if ($codes.Count) {
    if (-not (Ask-YesNo "正式な作品名を取るため、RJ番号 $($codes.Count) 件を DLsite に送ります（送るのは RJ番号だけ）。`n`nよろしいですか？" 'フォルダ名をそろえる')) { return }
    $form.Cursor = 'WaitCursor'
    try {
      $lblStatus.Text = 'DLsite から作品名を取っています…'; $form.Refresh()
      $failedFetch = Update-RenameTitles $codes
    } finally { $form.Cursor = 'Default' }
  }
  Update-TargetStates $targets $script:RenameTitles
  $okN = @($targets | Where-Object State -eq 'ok').Count
  $noN = @($targets | Where-Object State -eq 'nocode').Count
  $lblStatus.Text = "名前を変えられるフォルダ $okN 件 ／ RJ番号が決まっていないもの $noN 件 ／ ほか $($targets.Count - $okN - $noN) 件"

  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = 'フォルダ名をそろえる'
  $dlg.Font = $Font; $dlg.StartPosition = 'CenterParent'
  $dlg.Size = New-Object System.Drawing.Size((px 1180), (px 640))
  $dlg.MinimumSize = New-Object System.Drawing.Size((px 720), (px 400))
  $lay = New-Object System.Windows.Forms.TableLayoutPanel
  $lay.Dock = 'Fill'; $lay.ColumnCount = 1; $lay.Padding = New-Object System.Windows.Forms.Padding((px 10))
  [void]$lay.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
  foreach ($i in 1..3) { [void]$lay.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
  $lay.RowStyles[1] = New-Object System.Windows.Forms.RowStyle('Percent', 100)
  $dlg.Controls.Add($lay)

  $note = "チェックしたフォルダの名前を「RJ番号 正式な作品名 v版」に変えます（版は今の名前から読めたときだけ）。`n" +
          "最初からチェックが付くのは、手がかりが確かなものだけです。「DLsite で検索（候補）」の行は、RJ番号の欄で候補を選ぶか、右クリックで番号を入れてください（RJ番号の欄をダブルクリックで DLsite のページを開きます）。`n" +
          "「決め手」が「作品名が一致」のものは、同じ作品か気になるならチェックを外してください。変えた記録を残すので、「フォルダ名を戻す…」で戻せます。" +
          $(if ($failedFetch) { "`n※ $failedFetch 件は DLsite から作品名を取れませんでした（ネットにつながっているか確かめてください）。" } else { '' })
  $lay.Controls.Add((New-Label $note), 0, 0)

  $rg = New-Object System.Windows.Forms.DataGridView
  $rg.Dock = 'Fill'; $rg.AllowUserToAddRows = $false; $rg.AllowUserToDeleteRows = $false
  $rg.RowHeadersVisible = $false; $rg.SelectionMode = 'CellSelect'; $rg.MultiSelect = $false
  $rg.AutoSizeRowsMode = 'AllCells'; $rg.BackgroundColor = [System.Drawing.SystemColors]::Window
  $rg.ColumnHeadersHeightSizeMode = 'AutoSize'; $rg.DefaultCellStyle.WrapMode = 'True'
  $rg.EditMode = 'EditOnEnter'
  $cc = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
  $cc.HeaderText = '変える'; $cc.Name = 'Do'; $cc.Width = (px 50)
  [void]$rg.Columns.Add($cc)
  $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
  $col.Name = 'Old'; $col.HeaderText = '今の名前'; $col.Width = (px 260); $col.ReadOnly = $true
  [void]$rg.Columns.Add($col)
  $cb = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
  $cb.Name = 'Code'; $cb.HeaderText = 'RJ番号'; $cb.Width = (px 260); $cb.DisplayStyle = 'DropDownButton'; $cb.FlatStyle = 'Flat'
  [void]$rg.Columns.Add($cb)
  foreach ($c in @(
    @{ N = 'New';   H = '新しい名前'; W = 300 },
    @{ N = 'Clue';  H = '手がかり';   W = 150 },
    @{ N = 'How';   H = '決め手';     W = 100 },
    @{ N = 'State'; H = '状態';       W = 150 }
  )) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $c.N; $col.HeaderText = $c.H; $col.Width = (px $c.W); $col.ReadOnly = $true
    [void]$rg.Columns.Add($col)
  }
  $rg.Columns['Old'].AutoSizeMode = 'Fill'; $rg.Columns['New'].AutoSizeMode = 'Fill'
  # 選べない値などで出る表示のエラーは出さない
  $rg.Add_DataError({ param($s, $e) $e.ThrowException = $false })

  # 行の RJ番号の候補（「RJ… 作品名」）。今の番号が候補になければ先頭に足す
  $choiceText = { param($t)
    $items = @(@($t.Choices) | Where-Object { $_ } | ForEach-Object { if ($_.Title) { "$($_.Code) $($_.Title)" } else { [string]$_.Code } })
    if ($t.Code -and -not @($items | Where-Object { $_ -eq $t.Code -or $_.StartsWith($t.Code + ' ') }).Count) {
      $label = if ($script:RenameTitles[$t.Code]) { "$($t.Code) $($script:RenameTitles[$t.Code])" } else { [string]$t.Code }
      $items = @($label) + $items
    }
    return ,$items
  }
  # 行の表示を、その行の対象（Tag）に合わせる
  $paintRow = { param($row)
    $t = $row.Tag
    $cell = $row.Cells['Code']
    $items = & $choiceText $t
    $cell.Items.Clear()
    foreach ($it in $items) { [void]$cell.Items.Add($it) }
    $cell.Value = $(if ($t.Code) { @($items | Where-Object { $_ -eq $t.Code -or $_.StartsWith($t.Code + ' ') })[0] } else { $null })
    $cell.ReadOnly = $t.State -eq 'multi' -or $t.Clue -eq 'bookmark' -or $items.Count -eq 0
    $row.Cells['New'].Value = $t.NewName
    $row.Cells['Clue'].Value = $RenameClueText[[string]$t.Clue]
    $row.Cells['How'].Value = $t.How
    $row.Cells['State'].Value = $RenameStateText[$t.State]
    $ok = $t.State -eq 'ok'
    $row.Cells['Do'].ReadOnly = -not $ok
    if (-not $ok) { $row.Cells['Do'].Value = $false }
    $row.DefaultCellStyle.ForeColor = $(if ($ok -or $t.State -eq 'nocode') { [System.Drawing.SystemColors]::ControlText } else { [System.Drawing.SystemColors]::GrayText })
  }
  # 番号を決めた・変えたあと：作品名を取り、全部の行の状態を作り直して描き直す。その行はチェックを付ける
  $applyCode = { param($row, [string]$text, [bool]$manual)
    $t = $row.Tag
    $clue = $t.Clue
    if (-not (Set-TargetCode $t $text)) { Show-Info 'RJ番号（RJ01234567 など）か、DLsite の作品ページの URL を入れてください。'; return }
    if (-not $manual) { $t.Clue = $(if ($clue -eq 'inside') { 'inside' } else { 'search' }) }
    if (-not $script:RenameTitles.ContainsKey($t.Code)) {
      $dlg.Cursor = 'WaitCursor'
      try { [void](Update-RenameTitles @($t.Code)) } finally { $dlg.Cursor = 'Default' }
    }
    Update-TargetStates $targets $script:RenameTitles
    $script:RenameFilling = $true
    try {
      $keep = @{}
      foreach ($r in $rg.Rows) { $keep[$r.Index] = [bool]$r.Cells['Do'].Value }
      foreach ($r in $rg.Rows) { & $paintRow $r; if ($r.Tag.State -eq 'ok' -and $keep[$r.Index]) { $r.Cells['Do'].Value = $true } }
      if ($t.State -eq 'ok') { $row.Cells['Do'].Value = $true }
    } finally { $script:RenameFilling = $false }
    $btnGo.Enabled = @($targets | Where-Object State -eq 'ok').Count -gt 0
  }

  $script:RenameFilling = $true
  foreach ($t in @($targets | Sort-Object @{ e = { $_.State -ne 'ok' } }, @{ e = { $_.State -ne 'nocode' } }, OldName)) {
    $i = $rg.Rows.Add()
    $row = $rg.Rows[$i]; $row.Tag = $t; $row.Cells['Old'].Value = $t.OldName
    & $paintRow $row
    if ($t.State -eq 'ok' -and $t.Auto) { $row.Cells['Do'].Value = $true }
  }
  $script:RenameFilling = $false

  $rg.Add_CurrentCellDirtyStateChanged({ if ($rg.IsCurrentCellDirty) { $rg.CommitEdit('CurrentCellChange') } })
  $rg.Add_CellValueChanged({ param($s, $e) Invoke-Safe {
    if ($script:RenameFilling -or $e.RowIndex -lt 0 -or $rg.Columns[$e.ColumnIndex].Name -ne 'Code') { return }
    $row = $rg.Rows[$e.RowIndex]
    $v = [string]$row.Cells['Code'].Value
    if ($v -and $v -notmatch ('^' + [regex]::Escape([string]$row.Tag.Code) + '(\s|$)')) { & $applyCode $row $v $false }
    elseif ($v -and -not $row.Tag.Code) { & $applyCode $row $v $false }
  } })
  $rg.Add_CellDoubleClick({ param($s, $e) Invoke-Safe {
    if ($e.RowIndex -lt 0) { return }
    $t = $rg.Rows[$e.RowIndex].Tag
    $name = $rg.Columns[$e.ColumnIndex].Name
    if ($name -eq 'Code' -and $t.Code) { Start-Process "https://www.dlsite.com/maniax/work/=/product_id/$($t.Code).html" }
    elseif ($name -eq 'Old') { Start-Process explorer.exe "/select,`"$($t.Path)`"" }
  } })
  # 右クリック：RJ番号を自分で入れる
  $rmenu = New-Object System.Windows.Forms.ContextMenuStrip
  $rmenu.Font = $Font
  $miCode = $rmenu.Items.Add('RJ番号を入れる…（DLsite の URL でもよい）')
  $rg.ContextMenuStrip = $rmenu
  $script:RenameMenuRow = -1
  $rg.Add_CellMouseDown({ param($s, $e) if ($e.Button -eq 'Right' -and $e.RowIndex -ge 0) { $script:RenameMenuRow = $e.RowIndex } })
  $rmenu.Add_Opening({ param($s, $e)
    $r = $script:RenameMenuRow
    if ($r -lt 0 -or $r -ge $rg.Rows.Count -or $rg.Rows[$r].Tag.Clue -eq 'bookmark' -or $rg.Rows[$r].Tag.State -eq 'multi') { $e.Cancel = $true }
  })
  $miCode.Add_Click({ Invoke-Safe {
    $row = $rg.Rows[$script:RenameMenuRow]
    Add-Type -AssemblyName Microsoft.VisualBasic
    $v = [Microsoft.VisualBasic.Interaction]::InputBox("「$($row.Tag.OldName)」の RJ番号か、DLsite の作品ページの URL:", 'RJ番号を入れる', [string]$row.Tag.Code)
    if ($v.Trim()) { & $applyCode $row $v $true }
  } })
  $lay.Controls.Add($rg, 0, 1)

  $btns = New-Flow
  $btnGo = New-Button '名前を変える' $null -Primary
  $btnGo.Enabled = $okN -gt 0
  $btnGo.Add_Click({ Invoke-Safe {
    $chosen = @($rg.Rows | Where-Object { $_.Tag.State -eq 'ok' -and [bool]$_.Cells['Do'].Value })
    if ($chosen.Count -eq 0) { Show-Info '名前を変えるフォルダにチェックを入れてください。'; return }
    if (-not (Ask-YesNo "$($chosen.Count) 件のフォルダ・ファイルの名前を変えます。`n（ゲームを起動中のものは変えられません。閉じてから進めてください）`n`nよろしいですか？" '名前を変える確認')) { return }
    foreach ($row in $rg.Rows) { if ($row.Tag.State -eq 'ok' -and -not [bool]$row.Cells['Do'].Value) { $row.Tag.State = 'skip' } }
    # Close() はこの処理が終わるまで閉じないので、先に隠して待機カーソルを出す
    $dlg.Hide(); $dlg.Close()
    $form.Cursor = 'WaitCursor'
    try { $r = Invoke-FolderRename $targets $RenameLogDir $script:Links $LinksPath } finally { $form.Cursor = 'Default' }
    $msg = "$($r.Done) 件の名前を変えました。"
    if (@($r.Failed).Count) {
      $msg += "`n`n変えられなかったもの $(@($r.Failed).Count) 件:`n" + ((@($r.Failed) | Select-Object -First 10 | ForEach-Object { "・$($_.OldName)`n  → $($_.Reason)" }) -join "`n")
      if (@($r.Failed).Count -gt 10) { $msg += "`n…ほか $(@($r.Failed).Count - 10) 件" }
    }
    if ($r.Log) { $msg += "`n`n記録: $(Split-Path $r.Log -Leaf)（「フォルダ名を戻す…」で戻せます）" }
    Show-Info $msg 'フォルダ名をそろえた結果'
    # フォルダ名が変わったので、候補を調べ直してチェックし直す。④ で外したチェックは今のまま残す
    Run-Check -KeepChecks
  } })
  $btnCancel = New-Button 'キャンセル' $null
  $btnCancel.Add_Click({ $dlg.Close() })
  $btns.Controls.Add($btnGo); $btns.Controls.Add($btnCancel)
  $lay.Controls.Add($btns, 0, 2)
  [void]$dlg.ShowDialog($form)
}

# 「フォルダ名をそろえる」の記録を選んで、名前を元に戻す
function Undo-Rename {
  if (-not (Test-Path -LiteralPath $RenameLogDir)) { Show-Info 'フォルダ名を変えた記録はまだありません。'; return }
  $od = New-Object System.Windows.Forms.OpenFileDialog
  $od.Title = '戻す記録を選ぶ'
  $od.InitialDirectory = $RenameLogDir
  $od.Filter = 'フォルダ名を変えた記録|rename-*.json'
  if ($od.ShowDialog($form) -ne 'OK') { return }
  if ($od.FileName -like '*.links.json') { Show-Error 'これは owned-links.json のバックアップです。rename-日時.json の方を選んでください。'; return }
  $entries = @((Get-Content -LiteralPath $od.FileName -Raw -Encoding UTF8 | ConvertFrom-Json).entries | Where-Object done)
  if ($entries.Count -eq 0) { Show-Info 'この記録で戻すものはありません（もう戻してあります）。'; return }
  if (-not (Ask-YesNo "$($entries.Count) 件のフォルダ・ファイルの名前を元に戻します。`n（ゲームを起動中のものは戻せません）`n`nよろしいですか？" '戻す確認')) { return }
  $u = Undo-FolderRename $od.FileName $script:Links $LinksPath
  $msg = "$($u.Done) 件を元の名前に戻しました。"
  if (@($u.Skipped).Count) {
    $msg += "`n`n戻さなかったもの $(@($u.Skipped).Count) 件:`n" + ((@($u.Skipped) | Select-Object -First 10 | ForEach-Object { "・$($_.Name)`n  → $($_.Reason)" }) -join "`n")
  }
  Show-Info $msg '戻した結果'
  if ($script:Results) { Run-Check -KeepChecks }
}

function Fill-Grid {
  $script:Filling = $true
  $grid.SuspendLayout()
  $grid.Rows.Clear()
  $order = @{ owned = 0; maybe = 1; notowned = 2 }
  $show = Get-ShownStatus
  foreach ($r in ($script:Results | Sort-Object @{ e = { $order[$_.Status] } }, @{ e = { $_.Score }; Descending = $true })) {
    if (-not $show[$r.Status]) { continue }
    $match = if ($r.Match) { "$($r.Match)`n($($r.How))" } elseif ($r.NearName) { "いちばん近い: $($r.NearName)" } else { '' }
    $st = $StatusText[$r.Status] + $(if ($r.Confirmed) { '（確かめた）' } else { '' })
    $i = $grid.Rows.Add([bool]$script:DelState[$r.Code], $st, $r.Title, $r.Code, (Get-ASText $r.Code), $match, $r.Score)
    $row = $grid.Rows[$i]
    $row.Tag = $r
    $row.DefaultCellStyle.BackColor = $StatusColor[$r.Status]
    if ($r.Status -eq 'notowned') { $row.Cells['Del'].ReadOnly = $true }
  }
  $grid.ResumeLayout()
  $script:Filling = $false
  Update-DeleteButton
}

# 「表示:」のチェックで、いま表に出している判定
function Get-ShownStatus { @{ owned = $chkOwned.Checked; maybe = $chkMaybe.Checked; notowned = $chkNot.Checked } }

# 消すチェックが付いているのに、表示の絞り込みで表に出ていない作品の数
function Get-HiddenCheckedCount {
  $show = Get-ShownStatus
  @($script:Results | Where-Object { $script:DelState[$_.Code] -and -not $show[$_.Status] }).Count
}

function Update-DeleteButton {
  $n = @($script:DelState.GetEnumerator() | Where-Object Value).Count
  $hidden = Get-HiddenCheckedCount
  $btnDel.Enabled = $n -gt 0
  $btnDel.Text = "④ チェックした $n 作品" + $(if ($hidden) { "（表示していない $hidden 作品を含む）" } else { '' }) + "をブックマークから消す"
}

function Get-BookmarkSources { @($src.List.Items | ForEach-Object { "$_" } | Where-Object { Test-BookmarksFile $_ }) }

# 書き込み先のブックマークファイル（1つならそれ、複数なら ① で選んでいるもの）
function Get-TargetBookmarks([string]$what) {
  $bmFiles = @(Get-BookmarkSources)
  if ($bmFiles.Count -eq 0) { Show-Info "① に Chrome / Edge のブックマークを追加してください。"; return $null }
  if ($bmFiles.Count -eq 1) { return $bmFiles[0] }
  if ($src.List.SelectedItem -and (Test-BookmarksFile "$($src.List.SelectedItem)")) { return "$($src.List.SelectedItem)" }
  Show-Info "ブックマークが複数あるので、① で${what}のブックマークを選んでから押してください。"
  return $null
}

# ---------- URL をまとめてフォルダに追加 ----------

function Show-BulkAdd {
  $folder = Get-SelectedFolder
  if (-not $folder) { Show-Info '先に ① の「ブックマークのフォルダ」で、追加先のフォルダを選んでください。'; return }
  $target = Get-TargetBookmarks '追加先'
  if (-not $target) { return }

  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = "URL をまとめて追加 → $folder"
  $dlg.Font = $Font; $dlg.StartPosition = 'CenterParent'
  $dlg.Size = New-Object System.Drawing.Size((px 720), (px 520))
  $dlg.MinimumSize = New-Object System.Drawing.Size((px 520), (px 380))
  $lay = New-Object System.Windows.Forms.TableLayoutPanel
  $lay.Dock = 'Fill'; $lay.ColumnCount = 1; $lay.Padding = New-Object System.Windows.Forms.Padding((px 10))
  [void]$lay.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
  foreach ($i in 1..4) { [void]$lay.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
  $lay.RowStyles[1] = New-Object System.Windows.Forms.RowStyle('Percent', 100)
  $dlg.Controls.Add($lay)

  $lay.Controls.Add((New-Label "DLsite の作品URLを貼り付けてください（1行に1つ、ほかの文字が混ざっていてもOK）。`nSession Buddy のエクスポートなどは「ファイルから読み込む」でも入れられます。"), 0, 0)
  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Multiline = $true; $tb.ScrollBars = 'Both'; $tb.WordWrap = $false; $tb.Dock = 'Fill'; $tb.AcceptsReturn = $true
  $lay.Controls.Add($tb, 0, 1)

  $opts = New-Flow; $opts.FlowDirection = 'TopDown'
  $chkFetch = New-Object System.Windows.Forms.CheckBox
  $chkFetch.Text = '作品名がわからないものは DLsite から取ってくる（送るのは RJ 番号だけ）'; $chkFetch.AutoSize = $true; $chkFetch.Checked = $true
  $chkSkipOwned = New-Object System.Windows.Forms.CheckBox
  $chkSkipOwned.Text = 'すでに持っている作品は追加しない（② のゲームフォルダで判定）'; $chkSkipOwned.AutoSize = $true; $chkSkipOwned.Checked = $true
  $opts.Controls.Add($chkFetch); $opts.Controls.Add($chkSkipOwned)
  $lay.Controls.Add($opts, 0, 2)

  $btns = New-Flow
  $btnLoad = New-Button 'ファイルから読み込む…' $null
  $btnLoad.Add_Click({ Invoke-Safe {
    $od = New-Object System.Windows.Forms.OpenFileDialog
    $od.Filter = '対応するファイル|*.json;*.csv;*.txt;*.html;*.htm|すべてのファイル|*.*'
    if ($od.ShowDialog($dlg) -eq 'OK') { $tb.AppendText((Get-Content -LiteralPath $od.FileName -Raw -Encoding UTF8) + "`r`n") }
  } })
  $btnGo = New-Button '追加する' $null -Primary
  $btnGo.Add_Click({ Invoke-Safe { if (Invoke-BulkAdd $tb.Text $target $folder $chkFetch.Checked $chkSkipOwned.Checked) { $dlg.Close() } } })
  $btnCancel = New-Button 'キャンセル' $null
  $btnCancel.Add_Click({ $dlg.Close() })
  $btns.Controls.Add($btnGo); $btns.Controls.Add($btnLoad); $btns.Controls.Add($btnCancel)
  $lay.Controls.Add($btns, 0, 3)
  [void]$dlg.ShowDialog($form)
}

# 戻り値: 追加まで終わったら $true（ダイアログを閉じる）
function Invoke-BulkAdd([string]$text, [string]$target, [string]$folder, [bool]$fetch, [bool]$skipOwned) {
  $items = @(Read-WishlistFromText $text)
  if ($items.Count -eq 0) { Show-Info 'DLsite の作品URL（RJ番号入り）が見つかりませんでした。'; return $false }
  $form.Cursor = 'WaitCursor'
  try {
    if ($fetch) {
      $need = @($items | Where-Object { -not $_.Title } | ForEach-Object Code)
      if ($need.Count) {
        $titles = Get-DLsiteTitles $need
        foreach ($it in $items) { if (-not $it.Title -and $titles[$it.Code]) { $it.Title = $titles[$it.Code] } }
      }
    }
    $ownedN = 0
    $dirs = @($gd.List.Items | ForEach-Object { "$_" })
    if ($skipOwned -and $dirs.Count) {
      $cands = Get-Candidates -Reuse
      $owned = @{}
      Compare-Owned $items $cands ([double]$numTh.Value) $script:Links | Where-Object Status -eq 'owned' | ForEach-Object { $owned[$_.Code] = 1 }
      $ownedN = $owned.Count
      $items = @($items | Where-Object { -not $owned[$_.Code] })
    }
    $plan = Add-BookmarksToFolder $target $folder $items $BackupDir -DryRun
  } finally { $form.Cursor = 'Default' }

  $noTitle = @($items | Where-Object { -not $_.Title }).Count
  $msg = "「$folder」に $($plan.Added.Count) 作品を追加します。"
  if ($plan.Skipped) { $msg += "`n・フォルダにすでにある $($plan.Skipped) 作品は追加しません" }
  if ($ownedN) { $msg += "`n・すでに持っている $ownedN 作品は追加しません" }
  if ($noTitle) { $msg += "`n・作品名がわからない $noTitle 作品は、RJ番号を名前にして追加します" }
  if ($fetch -and $need.Count -and $script:DLsiteFailedCount) {
    $msg += "`n・DLsite に接続できず、$($script:DLsiteFailedCount) 作品の作品名を取れませんでした（$($script:DLsiteLastError)）"
  }
  if ($skipOwned -and $dirs.Count -and @($script:MissingGameDirs).Count) {
    $msg += "`n・見つからないゲームフォルダ $(@($script:MissingGameDirs).Count) か所は飛ばしました（その中の作品は「持っている」と判定されません）"
  }
  if ($plan.Added.Count -eq 0) { Show-Info ($msg -replace '^.*?。', '追加するものはありません。'); return $true }
  $synced = Test-BookmarksSynced $target
  if ($synced -and -not (Get-EdgeProfileDir $target)) { Show-Info $SyncedOtherBrowserMsg; return $false }
  if (-not (Ask-YesNo ($msg + "`n`n追加の前にバックアップを取ります。よろしいですか？") '追加の確認')) { return $false }
  if ($synced) {
    $send = @($items | ForEach-Object {
      [pscustomobject]@{ Code = $_.Code; Url = $_.Url; Title = $(if ($_.Title -and $_.Title -ne '(タイトル不明)') { $_.Title } else { $_.Code }) }
    })
    $r = Invoke-BookmarkOpInEdge $target 'add' $folder $null $send ''
    if ($r -eq 'changed' -or $r -eq 'partial') { Refresh-Folders; return $true }
    return $false
  }
  if (-not (Wait-BrowserClosed $target)) { return $false }

  $r = Add-BookmarksToFolder $target $folder $items $BackupDir
  Show-Info "$($r.Added.Count) 作品を追加しました。`n（バックアップ: $(Split-Path $r.Backup -Leaf)）" '追加の結果'
  Refresh-Folders
  return $true
}

# ブラウザが閉じられるまで待つ（閉じなければ $false）
function Wait-BrowserClosed([string]$path) {
  while ($true) {
    $running = @(Get-RunningBrowser $path)
    if ($running.Count -eq 0) { return $true }
    $ans = [System.Windows.Forms.MessageBox]::Show($form,
      "ブラウザ（$($running -join ' / ')）が起動中です。`n`n起動中にブックマークを書き換えると、ブラウザが元に戻してしまいます。`nブラウザを完全に終了してから（タスクトレイに残っている場合はそこからも終了）「再試行」を押してください。",
      'ブラウザを終了してください', 'RetryCancel', 'Warning')
    if ($ans -ne 'Retry') { return $false }
  }
}

# ---------- 同期がオンのとき（拡張機能で書き換える） ----------

$ExtensionDir = Join-Path $PSScriptRoot 'edge-extension'
$script:ExtensionReady = $false

# 同期がオンの Edge のブックマークを、拡張機能「所持チェック ブックマーク係」に書き換えてもらう。
# Edge で DLsite のページを開き、ページに出る「実行する」をユーザーが押す。
# 戻り値: 'changed'（ファイルが書き換わった）・'partial'（途中でやめたが一部は書き換わった）・
#         'unchanged'（最後まで進んだが書き換わらなかった）・'cancelled'（やめた・始められなかった）
function Invoke-BookmarkOpInEdge([string]$BookmarksPath, [string]$Op, [string]$Folder, [string[]]$Codes, $Items, [string]$Sub) {
  $profileDir = Get-EdgeProfileDir $BookmarksPath
  if (-not $profileDir) { return 'cancelled' }
  if (-not $script:ExtensionReady) {
    $ans = Ask-YesNo ("このブックマークは Edge の同期がオンです。所持チェックが直接書き換えると、同期で元に戻されてしまいます。`n" +
      "そのため、Edge の拡張機能「所持チェック ブックマーク係」に書き換えてもらいます。`n`n" +
      "入れ方（最初の1回だけ）:`n1. Edge のアドレス欄に edge://extensions と入れて開く`n2. 左の「開発者モード」をオンにする`n" +
      "3. 「展開して読み込み」を押し、次のフォルダを選ぶ`n   $ExtensionDir`n`n入れましたか？（「いいえ」なら何もしません）") '拡張機能を入れる'
    if (-not $ans) { return 'cancelled' }
    $script:ExtensionReady = $true
    Save-Settings
  }
  $urls = @(New-BookmarkOpUrls -Op $Op -Folder $Folder -Codes $Codes -Items $Items -Sub $Sub -RootIndex (Get-BookmarkRootIndex $BookmarksPath $Folder))
  [void](Backup-BookmarksFile $BookmarksPath $BackupDir)
  $changed = $false
  for ($i = 0; $i -lt $urls.Count; $i++) {
    # 回ごとに、開く前の更新日時を取る（前の回の書き出しを、この回の分と取り違えないように）
    $before = (Get-Item -LiteralPath $BookmarksPath).LastWriteTimeUtc
    try { Start-Process -FilePath 'msedge.exe' -ArgumentList "--profile-directory=`"$profileDir`"", $urls[$i] }
    catch { Show-Error "Edge を開けませんでした。`n$($_.Exception.Message)"; return $(if ($changed) { 'partial' } else { 'cancelled' }) }
    $part = if ($urls.Count -gt 1) { "（$($i + 1) / $($urls.Count) 回目）" } else { '' }
    $ans = [System.Windows.Forms.MessageBox]::Show($form,
      "Edge で DLsite のページを開きました$part。`n`nページの右下に出る内容を確かめて「実行する」を押し、結果が出たら OK を押してください。`n（ページに何も出ないときは、拡張機能が入っているか確かめてください）",
      'Edge で実行する', 'OKCancel', 'Information')
    if ($ans -ne 'OK') { return $(if ($changed) { 'partial' } else { 'cancelled' }) }
    # Edge がファイルに書き出すまで待つ（最大 10 秒）
    $form.Cursor = 'WaitCursor'
    try { if (Wait-FileChanged $BookmarksPath $before 10000) { $changed = $true } } finally { $form.Cursor = 'Default' }
  }
  if ($changed) { return 'changed' }
  Show-Info "ブックマークのファイルが書き換わっていません。`n「実行する」を押していなければ、何も変わっていません。押した場合は、Edge を一度閉じてから「チェック開始」を押し直してください。"
  return 'unchanged'
}

# 同期がオンで、拡張機能でも書き換えられない（Edge 以外の）ブックマークのときの知らせ
$SyncedOtherBrowserMsg = '同期がオンの Edge 以外のブラウザ（Chrome など）のブックマークは書き換えられません（同期で元に戻されるため）。ブラウザで直接操作してください。'

function Delete-Checked {
  $codes = @($script:DelState.GetEnumerator() | Where-Object Value | ForEach-Object Key)
  if ($codes.Count -eq 0) { Show-Info '消す作品にチェックを入れてください。'; return }
  $bmFiles = @(Get-BookmarkSources)
  if ($bmFiles.Count -eq 0) {
    Show-Info "自動で消せるのは、① に Chrome / Edge のブックマークを追加しているときだけです。`n（Session Buddy などのエクスポートファイルは消せません）"
    return
  }
  $maybeRows = @($script:Results | Where-Object { $_.Status -eq 'maybe' -and $script:DelState[$_.Code] })
  $maybeN = $maybeRows.Count
  $folder = Get-SelectedFolder
  $msg = "$($codes.Count) 作品のブックマークを消します。"
  if ($maybeN) { $msg += "`n（うち「たぶん持っている」が $maybeN 作品。この手元の候補で合っていると覚えます）" }
  $hiddenN = Get-HiddenCheckedCount
  if ($hiddenN) { $msg += "`n（うち、表示の絞り込みで今は表に出ていないものが $hiddenN 作品）" }
  $msg += "`n対象: " + $(if ($folder) { "フォルダ「$folder」の中だけ" } else { 'ブックマーク全体' })
  $msg += "`n`n消す前にバックアップを取ります。よろしいですか？"
  if (-not (Ask-YesNo $msg '削除の確認')) { return }

  # 「たぶん」を消すのは、その候補で合っていると確かめたということなので覚えておく
  # （「持っている作品の更新をASで確認」で、消したあとも持っている作品として扱うため）
  if ($maybeN) {
    foreach ($r in $maybeRows) { if ($r.MatchPath) { Set-OwnedLink $script:Links $r.Code $r.MatchPath $true } }
    try { Save-OwnedLinks $LinksPath $script:Links } catch { }
  }

  $report = New-Object System.Collections.Generic.List[string]
  foreach ($bf in $bmFiles) {
    if (Test-BookmarksSynced $bf) {
      if (-not (Get-EdgeProfileDir $bf)) { $report.Add("・$bf`n  → $SyncedOtherBrowserMsg"); continue }
      switch (Invoke-BookmarkOpInEdge $bf 'delete' $folder $codes $null '') {
        'changed'   { $report.Add("・$bf`n  → 同期がオンなので、Edge の拡張機能で消しました（消した数は Edge のページに出ています）") }
        'partial'   { $report.Add("・$bf`n  → 途中でやめたため、一部だけ消しました") }
        'unchanged' { $report.Add("・$bf`n  → 変わっていません（Edge で「実行する」を押していない、または当てはまるものがありませんでした）") }
        default     { $report.Add("・$bf`n  → やめたため、消していません") }
      }
      continue
    }
    if (-not (Wait-BrowserClosed $bf)) { $report.Add("・$bf`n  → ブラウザが起動中のため、消していません"); continue }
    $r = Remove-BookmarksByCode $bf $codes $BackupDir -Folder $folder
    if ($r.Removed.Count -eq 0) { $report.Add("・$bf`n  → 該当するブックマークはありませんでした"); continue }
    $report.Add("・$bf`n  → $($r.Removed.Count) 件消しました（バックアップ: $(Split-Path $r.Backup -Leaf)）")
  }
  Show-Info ($report -join "`n`n") '削除の結果'
  # ブックマークだけ読み直す。ゲームフォルダは変わっていないので、前回の候補を使う
  Run-Check -ReuseCandidates
}

function Restore-Backup {
  $target = Get-TargetBookmarks '戻し先'
  if (-not $target) { return }
  if (-not (Test-Path -LiteralPath $BackupDir)) { Show-Info 'バックアップはまだありません。'; return }
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Title = '戻すバックアップを選ぶ'
  $dlg.InitialDirectory = $BackupDir
  $dlg.Filter = 'バックアップ|Bookmarks-*|すべてのファイル|*.*'
  if ($dlg.ShowDialog($form) -ne 'OK') { return }
  if (-not (Test-BookmarksFile $dlg.FileName)) { Show-Error 'このファイルはブックマークのバックアップではないようです。'; return }
  if (Test-BookmarksSynced $target) {
    Show-Info "同期がオンなので戻せません（ファイルを戻しても、同期で今の状態に戻されます）。`nEdge の「お気に入り」→「削除したお気に入りの復元」を使うか、同期をオフにしてから使ってください。"
    return
  }
  if (-not (Ask-YesNo "次のバックアップでブックマークを上書きします。`n`nバックアップ: $(Split-Path $dlg.FileName -Leaf)`n戻し先: $target`n`n今のブックマークも念のためバックアップしてから戻します。よろしいですか？" '復元の確認')) { return }
  if (-not (Wait-BrowserClosed $target)) { return }
  [void](Backup-BookmarksFile $target $BackupDir 'before-restore')
  Copy-Item -LiteralPath $dlg.FileName -Destination $target -Force
  Show-Info '戻しました。ブラウザを起動して確認してください。'
}

# ---------- 設定の保存と読み込み ----------

function Save-Settings {
  $o = [ordered]@{
    Sources = @($src.List.Items | ForEach-Object { "$_" })
    GameDirs = @($gd.List.Items | ForEach-Object { "$_" })
    Depth = [int]$numDepth.Value
    Threshold = [double]$numTh.Value
    BookmarkFolder = (Get-SelectedFolder)
    ExtensionReady = [bool]$script:ExtensionReady
  }
  try { [IO.File]::WriteAllText($SettingsPath, ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch { }
}

function Load-Settings {
  if (Test-Path -LiteralPath $SettingsPath) {
    try {
      $o = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($p in @($o.Sources)) { if ($p) { [void]$src.List.Items.Add($p) } }
      foreach ($p in @($o.GameDirs)) { if ($p) { [void]$gd.List.Items.Add($p) } }
      # 手で書き換えて範囲外になっていても止まらないよう、範囲内に収めてから入れる
      if ($o.Depth) { $numDepth.Value = [Math]::Max($numDepth.Minimum, [Math]::Min($numDepth.Maximum, [decimal]$o.Depth)) }
      if ($o.Threshold) { $numTh.Value = [Math]::Max($numTh.Minimum, [Math]::Min($numTh.Maximum, [decimal]$o.Threshold)) }
      $script:ExtensionReady = [bool]$o.ExtensionReady
      Refresh-Folders ([string]$o.BookmarkFolder)
      return
    } catch {
      # 設定ファイルが壊れていたら、途中まで入れたものを消して初回と同じにする（重複させない）
      $src.List.Items.Clear(); $gd.List.Items.Clear()
    }
  }
  # 初回：見つかったブラウザのブックマークを最初から入れておく
  foreach ($f in @(Find-BrowserBookmarks | Select-Object -First 1)) { [void]$src.List.Items.Add($f.Path) }
  Refresh-Folders
}

# 読み込みが先。逆にすると、読み込みの途中（フォルダ未設定のとき）に保存が走り、フォルダ指定が消える
Load-Settings
$numDepth.Add_ValueChanged({ Save-Settings })
$numTh.Add_ValueChanged({ Save-Settings })

# ---------- 起動 ----------

[void]$form.ShowDialog()
