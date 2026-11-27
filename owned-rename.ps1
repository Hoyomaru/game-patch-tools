# owned-rename.ps1 — 所持チェックの「フォルダ名をそろえる」処理（画面なし）。owned-core.ps1 のあとに読み込みます。
# 「持っている」作品のうち RJ番号の入っていないフォルダ・アーカイブの名前を「RJ番号 正式な作品名 v版」にそろえ、元に戻せるようにします。

# 新しいフルパスの長さの上限（Windows の 260 文字より少し余裕を持たせる）
$script:RenameMaxPath = 240
# 版の文字（Get-FolderVersion と同じ形）
$script:VersionRe = '(?i)(?:(?<![a-z0-9])ver(?:sion)?\.?\s*|(?<![a-z0-9])v)\d+(?:[._\-]\d+)*[a-z]?(?![\w.])'

# ---------- 1. 新しい名前を作る ----------

# Windows のファイル名に使えない文字を全角にし、改行・タブ・続く空白を空白1つにまとめ、末尾の点と空白を取る
function ConvertTo-SafeFileName([string]$s) {
  $map = @{ '\' = '＼'; '/' = '／'; ':' = '：'; '*' = '＊'; '?' = '？'; '"' = '＂'; '<' = '＜'; '>' = '＞'; '|' = '｜' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    $k = [string]$ch
    if ($map.ContainsKey($k)) { [void]$sb.Append($map[$k]) }
    elseif ([char]::IsControl($ch)) { [void]$sb.Append(' ') }
    else { [void]$sb.Append($ch) }
  }
  return (($sb.ToString() -replace '\s+', ' ').Trim() -replace '[\s.]+$', '')
}

# 「RJ番号 正式な作品名 v版」（版は今の名前から読めたときだけ）。アーカイブは元の拡張子を付ける。
#   ・作品名の中の版の文字（「Ver2」など）は取り除く。残すと、変えたあとに Get-FolderVersion が作品名の方の版を読んでしまう
#   ・親のパスと合わせて $script:RenameMaxPath を超えるときは、作品名を切り詰める
#   ・$InnerLen（フォルダの中のいちばん長いパスの、フォルダより後ろの長さ）を渡すと、中のファイルも 259 文字に収まるようにする。
#     もともと超えていたものは、今の名前より長くしない
# 作品名が空になったら '' を返す
function New-RenameName([string]$Code, [string]$Title, [string]$OldName, [bool]$IsArchive, [string]$ParentPath, [int]$InnerLen = 0) {
  $ext = ''; $base = $OldName
  if ($IsArchive) { $ext = [IO.Path]::GetExtension($OldName); $base = [IO.Path]::GetFileNameWithoutExtension($OldName) }
  $ver = Get-FolderVersion $base
  $tail = $(if ($ver) { " v$ver" } else { '' }) + $ext
  $t = $Title -replace $script:VersionRe, ' ' -replace '\(\s*\)|\[\s*\]|（\s*）|【\s*】', ' '
  $t = ConvertTo-SafeFileName $t
  if (-not $t) { return '' }
  $p = $ParentPath.TrimEnd('\').Length + 1
  $nameMax = [Math]::Min($script:RenameMaxPath - $p, 259 - $p - $InnerLen)
  $nameMax = [Math]::Max($nameMax, $OldName.Length)
  $room = $nameMax - ($Code.Length + 1) - $tail.Length
  if ($t.Length -gt $room) { $t = (ConvertTo-SafeFileName $t.Substring(0, [Math]::Max(1, $room))) }
  if (-not $t) { return '' }
  return "$Code $t$tail"
}

# フォルダの中のいちばん長いパスの、フォルダより後ろの長さ（先頭の \ を含む）。中が空なら 0
function Get-InnerPathLength([string]$Path) {
  $max = 0
  foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)) {
    $n = $f.FullName.Length - $Path.TrimEnd('\').Length
    if ($n -gt $max) { $max = $n }
  }
  return $max
}

# ---------- 2. 名前を変える対象を選ぶ ----------

# 対象：照らし合わせで「持っている」になった作品（RJ番号の一致・作品名の完全一致・確かめた対応）の、名前に RJ番号がない手元の候補
#   ・1つの候補に2つ以上の作品が当たったら、変えずに State = 'multi'（違う RJ番号を付けないため）
#   ・候補のすぐ外側も同じ名前の候補なら（二重に展開した「作品\作品」）、外側を対象にする
#   ・② に登録したゲームフォルダそのものは対象にしない
# 戻り値: Code / Path / OldName / IsArchive / How / State（'pending' か 'multi'） / NewName / NewPath の一覧
function Get-RenameTargets($Wishlist, $Candidates, [double]$Threshold, $Links, [string[]]$GameDirs) {
  $cl = @($Candidates | ForEach-Object { $_ })
  $byPath = @{}
  foreach ($c in $cl) { if (-not $byPath.ContainsKey([string]$c.Path)) { $byPath[[string]$c.Path] = $c } }
  $roots = @{}
  foreach ($d in @($GameDirs)) { if ($d) { $roots[$d.TrimEnd('\')] = $true } }
  $groups = [ordered]@{}
  foreach ($r in @(Compare-Owned @($Wishlist) $cl $Threshold $Links)) {
    if ($r.Status -ne 'owned' -or -not $r.MatchPath) { continue }
    $c = $byPath[[string]$r.MatchPath]
    if (-not $c -or $c.Code) { continue }
    $parent = Split-Path -Parent $c.Path
    $pc = $byPath[$parent]
    if ($pc -and -not $pc.Code -and $pc.Norm -eq $c.Norm) { $c = $pc }
    # ゲームフォルダそのものと、その親にあたるもの（名前を変えると ② の登録先が見つからなくなる）は変えない
    $cp = ([string]$c.Path).TrimEnd('\')
    if ($roots.ContainsKey($cp) -or @($roots.Keys | Where-Object { $_.StartsWith($cp + '\', [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
    $key = [string]$c.Path
    if (-not $groups.Contains($key)) { $groups[$key] = @{ Cand = $c; Hits = New-Object System.Collections.Generic.List[object] } }
    if (-not @($groups[$key].Hits | Where-Object Code -eq $r.Code).Count) { $groups[$key].Hits.Add($r) }
  }
  foreach ($g in $groups.Values) {
    $c = $g.Cand
    $isArchive = -not (Test-Path -LiteralPath $c.Path -PathType Container)
    $oldName = Split-Path -Leaf $c.Path
    $state = if ($g.Hits.Count -gt 1) { 'multi' } else { 'pending' }
    foreach ($r in $g.Hits) {
      [pscustomobject]@{ Code = $r.Code; Path = [string]$c.Path; OldName = $oldName; IsArchive = $isArchive; How = $r.How; State = $state; NewName = ''; NewPath = '' }
    }
  }
}

# State = 'pending' の対象に新しい名前を入れる。$Titles: @{ RJ番号 = 正式な作品名 }（Get-DLsiteTitles の戻り値）
#   作品名が取れなかった → 'notitle'、同じ名前のものがもうある → 'exists'、それ以外 → 'ok'
function Set-RenameNames($Targets, [hashtable]$Titles) {
  foreach ($t in @($Targets)) {
    if ($t.State -ne 'pending') { continue }
    $title = $Titles[$t.Code]
    if (-not $title) { $t.State = 'notitle'; continue }
    $parent = Split-Path -Parent $t.Path
    $inner = if ($t.IsArchive) { 0 } else { Get-InnerPathLength $t.Path }
    $t.NewName = New-RenameName $t.Code $title $t.OldName $t.IsArchive $parent $inner
    if (-not $t.NewName) { $t.State = 'notitle'; continue }
    $t.NewPath = Join-Path $parent $t.NewName
    $t.State = if (Test-Path -LiteralPath $t.NewPath) { 'exists' } else { 'ok' }
  }
}

# ---------- 3. 名前を変える・戻す ----------

# owned-links.json に覚えているパスのうち、$OldPath そのものと、その下にあるパスを $NewPath に書き換える（大文字小文字は区別しない）
function Update-LinkPaths($Links, [string]$OldPath, [string]$NewPath) {
  $old = $OldPath.TrimEnd('\')
  $fix = {
    param([string]$p)
    if ($p -ieq $old) { return $NewPath }
    if ($p.StartsWith($old + '\', [StringComparison]::OrdinalIgnoreCase)) { return $NewPath + $p.Substring($old.Length) }
    return $p
  }
  foreach ($k in @($Links.Same.Keys)) { $Links.Same[$k] = & $fix ([string]$Links.Same[$k]) }
  foreach ($k in @($Links.Diff.Keys)) { $Links.Diff[$k] = @(@($Links.Diff[$k]) | ForEach-Object { & $fix ([string]$_) }) }
}

function Write-RenameLog([string]$Path, $Entries) {
  $json = [ordered]@{ entries = @($Entries) } | ConvertTo-Json -Depth 4
  [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

# State = 'ok' の対象の名前を変える。変える前に記録ファイル（$LogDir\rename-日時.json）に全件を書き、1件ごとに done を書き足す。
# owned-links.json があれば、先に同じ名前の .links.json にコピーしてから書き換える。
# 使用中などで変えられなかったものは飛ばして続ける。
# 戻り値: Log（記録ファイル）/ Done（変えた数）/ Failed（@{ OldName; Reason } の一覧）
function Invoke-FolderRename($Targets, [string]$LogDir, $Links, [string]$LinksPath) {
  # 入れ子になった別の作品があっても困らないよう、深い方から変える
  $todo = @(@($Targets) | Where-Object { $_.State -eq 'ok' } | Sort-Object { ([string]$_.Path).Split('\').Count } -Descending)
  $failed = New-Object System.Collections.Generic.List[object]
  if ($todo.Count -eq 0) { return [pscustomobject]@{ Log = ''; Done = 0; Failed = @() } }
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  $log = Join-Path $LogDir ('rename-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json')
  if ($LinksPath -and (Test-Path -LiteralPath $LinksPath)) { Copy-Item -LiteralPath $LinksPath -Destination ($log -replace '\.json$', '.links.json') }
  $entries = @($todo | ForEach-Object { [pscustomobject]@{ old = $_.Path; new = $_.NewPath; done = $false } })
  Write-RenameLog $log $entries
  $done = 0
  for ($i = 0; $i -lt $todo.Count; $i++) {
    try {
      Rename-Item -LiteralPath $todo[$i].Path -NewName $todo[$i].NewName -ErrorAction Stop
      $entries[$i].done = $true; $done++
      Update-LinkPaths $Links $todo[$i].Path $todo[$i].NewPath
      Write-RenameLog $log $entries
    } catch {
      $failed.Add([pscustomobject]@{ OldName = $todo[$i].OldName; Reason = $_.Exception.Message })
    }
  }
  if ($done -and $LinksPath) { Save-OwnedLinks $LinksPath $Links }
  return [pscustomobject]@{ Log = $log; Done = $done; Failed = $failed.ToArray() }
}

# 記録ファイルの done のものを逆の順に元の名前へ戻し、owned-links.json のパスも戻す。戻したものは done を外す（2回戻しても困らない）。
# 元の名前のものがもうある・新しい名前のものが見つからない（手で動かした）ものは飛ばす。
# 戻り値: Done（戻した数）/ Skipped（@{ Name; Reason } の一覧）
function Undo-FolderRename([string]$LogPath, $Links, [string]$LinksPath) {
  $entries = @((Get-Content -LiteralPath $LogPath -Raw -Encoding UTF8 | ConvertFrom-Json).entries)
  $skipped = New-Object System.Collections.Generic.List[object]
  $done = 0
  for ($i = $entries.Count - 1; $i -ge 0; $i--) {
    $e = $entries[$i]
    if (-not $e.done) { continue }
    $name = Split-Path -Leaf $e.new
    if (-not (Test-Path -LiteralPath $e.new)) { $skipped.Add([pscustomobject]@{ Name = $name; Reason = '見つかりません（名前を変えたか、動かした）' }); continue }
    if (Test-Path -LiteralPath $e.old) { $skipped.Add([pscustomobject]@{ Name = $name; Reason = "元の名前「$(Split-Path -Leaf $e.old)」のものがもうあります" }); continue }
    try {
      Rename-Item -LiteralPath $e.new -NewName (Split-Path -Leaf $e.old) -ErrorAction Stop
      $e.done = $false; $done++
      Update-LinkPaths $Links $e.new $e.old
      Write-RenameLog $LogPath $entries
    } catch {
      $skipped.Add([pscustomobject]@{ Name = $name; Reason = $_.Exception.Message })
    }
  }
  if ($done -and $LinksPath) { Save-OwnedLinks $LinksPath $Links }
  return [pscustomobject]@{ Done = $done; Skipped = $skipped.ToArray() }
}
