# owned-gui.ps1 — 所持チェック（GUI 版）。「所持チェック.bat」をダブルクリックで起動します。
# すべてこのPCの中だけで処理します。ネットにアクセスするのは「URL をまとめて追加」で作品名を DLsite から取るときだけです（送るのは RJ 番号だけ）。
param(
  [string]$SelfTestShot,      # テスト用：画面を画像に保存して終了する
  [string]$SelfTestBulkShot   # テスト用：「URL をまとめて追加」の画面を開いて画像に保存する
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'owned-core.ps1')

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace Win32 -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][Win32.Dpi]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

$SettingsPath = Join-Path $PSScriptRoot 'owned-gui-settings.json'
$BackupDir    = Join-Path $PSScriptRoot 'bookmark-backups'
$ReportPath   = Join-Path $PSScriptRoot 'owned-report.html'

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
$flt.Controls.Add((New-Label '（作品名をダブルクリックで DLsite、手元の候補をダブルクリックでフォルダを開きます）'))

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
  if ($name -eq 'Match' -and $r.MatchPath) { Start-Process explorer.exe "/select,`"$($r.MatchPath)`"" }
  elseif ($name -ne 'Del') { Start-Process $r.Url }
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
$bot.Controls.Add((New-Label '※ 消すときはブラウザを完全に終了しておいてください。消す前に毎回バックアップを取ります。'))

# ---------- 処理 ----------

$script:Results = @()
$script:DelState = @{}
$StatusText = @{ owned = '持っている'; maybe = 'たぶん持っている'; notowned = '持っていない' }
$StatusColor = @{
  owned = [System.Drawing.Color]::FromArgb(222, 244, 226)
  maybe = [System.Drawing.Color]::FromArgb(255, 243, 205)
  notowned = [System.Drawing.SystemColors]::Window
}

function Run-Check {
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
    $lblStatus.Text = 'ゲームフォルダを調べています…'; $form.Refresh()
    $cands = Get-GameCandidates $dirs ([int]$numDepth.Value)
    $lblStatus.Text = '照らし合わせています…'; $form.Refresh()
    $script:Results = @(Compare-Owned $wish $cands ([double]$numTh.Value))
    Write-OwnedReport $script:Results $wish.Count $cands.Count ([double]$numTh.Value) $ReportPath
    # 初期状態：「持っている」は消す対象、「たぶん」は自分で選ぶ
    $script:DelState = @{}
    foreach ($r in $script:Results) { $script:DelState[$r.Code] = ($r.Status -eq 'owned') }
    Fill-Grid
    $o = @($script:Results | Where-Object Status -eq 'owned').Count
    $m = @($script:Results | Where-Object Status -eq 'maybe').Count
    $n = @($script:Results | Where-Object Status -eq 'notowned').Count
    $lblStatus.Text = "気になるリスト $($wish.Count) 作品 ／ 手元 $($cands.Count) 件 → 持っている $o ・ たぶん $m ・ 持っていない $n"
    $missing = @($script:MissingGameDirs)
    if ($missing.Count) {
      $lblStatus.Text += " ／ 見つからないゲームフォルダ $($missing.Count) か所を飛ばしました"
      Show-Info ("次のゲームフォルダが見つからなかったので、飛ばして判定しました。`n（ドライブがつながっているか確かめてください。この中の作品は「持っていない」になっています）`n`n" + ($missing -join "`n"))
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

function Fill-Grid {
  $script:Filling = $true
  $grid.SuspendLayout()
  $grid.Rows.Clear()
  $order = @{ owned = 0; maybe = 1; notowned = 2 }
  $show = Get-ShownStatus
  foreach ($r in ($script:Results | Sort-Object @{ e = { $order[$_.Status] } }, @{ e = { $_.Score }; Descending = $true })) {
    if (-not $show[$r.Status]) { continue }
    $match = if ($r.Match) { "$($r.Match)`n($($r.How))" } elseif ($r.NearName) { "いちばん近い: $($r.NearName)" } else { '' }
    $i = $grid.Rows.Add([bool]$script:DelState[$r.Code], $StatusText[$r.Status], $r.Title, $r.Code, $match, $r.Score)
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
      $cands = Get-GameCandidates $dirs ([int]$numDepth.Value)
      $owned = @{}
      Compare-Owned $items $cands ([double]$numTh.Value) | Where-Object Status -eq 'owned' | ForEach-Object { $owned[$_.Code] = 1 }
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
  if (-not (Ask-YesNo ($msg + "`n`n追加の前にバックアップを取ります。よろしいですか？") '追加の確認')) { return $false }
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

function Delete-Checked {
  $codes = @($script:DelState.GetEnumerator() | Where-Object Value | ForEach-Object Key)
  if ($codes.Count -eq 0) { Show-Info '消す作品にチェックを入れてください。'; return }
  $bmFiles = @(Get-BookmarkSources)
  if ($bmFiles.Count -eq 0) {
    Show-Info "自動で消せるのは、① に Chrome / Edge のブックマークを追加しているときだけです。`n（Session Buddy などのエクスポートファイルは消せません）"
    return
  }
  $maybeN = @($script:Results | Where-Object { $_.Status -eq 'maybe' -and $script:DelState[$_.Code] }).Count
  $folder = Get-SelectedFolder
  $msg = "$($codes.Count) 作品のブックマークを消します。"
  if ($maybeN) { $msg += "`n（うち「たぶん持っている」が $maybeN 作品）" }
  $hiddenN = Get-HiddenCheckedCount
  if ($hiddenN) { $msg += "`n（うち、表示の絞り込みで今は表に出ていないものが $hiddenN 作品）" }
  $msg += "`n対象: " + $(if ($folder) { "フォルダ「$folder」の中だけ" } else { 'ブックマーク全体' })
  $msg += "`n`n消す前にバックアップを取ります。よろしいですか？"
  if (-not (Ask-YesNo $msg '削除の確認')) { return }

  $report = New-Object System.Collections.Generic.List[string]
  foreach ($bf in $bmFiles) {
    if (-not (Wait-BrowserClosed $bf)) { $report.Add("・$bf`n  → ブラウザが起動中のため、消していません"); continue }
    $r = Remove-BookmarksByCode $bf $codes $BackupDir -Folder $folder
    if ($r.Removed.Count -eq 0) { $report.Add("・$bf`n  → 該当するブックマークはありませんでした"); continue }
    $report.Add("・$bf`n  → $($r.Removed.Count) 件消しました（バックアップ: $(Split-Path $r.Backup -Leaf)）")
  }
  Show-Info ($report -join "`n`n") '削除の結果'
  Run-Check
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

if ($SelfTestShot) {
  # テスト用：画面を表示せずに描画して画像に保存
  $form.ShowInTaskbar = $false; $form.Opacity = 0
  $form.Add_Shown({
    try { Run-Check } catch { }
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save($SelfTestShot)
    if ($SelfTestBulkShot) {
      # 実際のボタンを押して開き、開いたダイアログを撮って閉じる
      $timer = New-Object System.Windows.Forms.Timer
      $timer.Interval = 800
      $timer.Add_Tick({
        $timer.Stop()
        $dlgOpen = [System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -like 'URL をまとめて追加*' } | Select-Object -First 1
        if ($dlgOpen) {
          $b2 = New-Object System.Drawing.Bitmap($dlgOpen.Width, $dlgOpen.Height)
          $dlgOpen.DrawToBitmap($b2, (New-Object System.Drawing.Rectangle(0, 0, $dlgOpen.Width, $dlgOpen.Height)))
          $b2.Save($SelfTestBulkShot)
          $dlgOpen.Close()
        }
      })
      $timer.Start()
      $btnBulk = $src.Buttons.Controls | Where-Object { $_.Text -eq 'URL をまとめて追加…' }
      $btnBulk.PerformClick()
    }
    $form.Close()
  })
}
[void]$form.ShowDialog()
