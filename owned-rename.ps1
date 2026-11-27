# owned-rename.ps1 — 所持チェックの「フォルダ名をそろえる」処理（画面なし）。owned-core.ps1 のあとに読み込みます。
# 「持っている」作品のうち RJ番号の入っていないフォルダ・アーカイブの名前を「RJ番号 正式な作品名 v版」にそろえ、元に戻せるようにします。

# 新しいフルパスの長さの上限（Windows の 260 文字より少し余裕を持たせる）
$script:RenameMaxPath = 240

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
# 親のパスと合わせて $script:RenameMaxPath を超えるときは、作品名を切り詰める
function New-RenameName([string]$Code, [string]$Title, [string]$OldName, [bool]$IsArchive, [string]$ParentPath) {
  $ext = ''; $base = $OldName
  if ($IsArchive) { $ext = [IO.Path]::GetExtension($OldName); $base = [IO.Path]::GetFileNameWithoutExtension($OldName) }
  $ver = Get-FolderVersion $base
  $tail = $(if ($ver) { " v$ver" } else { '' }) + $ext
  $t = ConvertTo-SafeFileName $Title
  $room = $script:RenameMaxPath - $ParentPath.TrimEnd('\').Length - 1 - ($Code.Length + 1) - $tail.Length
  if ($t.Length -gt $room) { $t = (ConvertTo-SafeFileName $t.Substring(0, [Math]::Max(1, $room))) }
  return "$Code $t$tail"
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
    if ($roots.ContainsKey(([string]$c.Path).TrimEnd('\'))) { continue }
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
    $t.NewName = New-RenameName $t.Code $title $t.OldName $t.IsArchive $parent
    $t.NewPath = Join-Path $parent $t.NewName
    $t.State = if (Test-Path -LiteralPath $t.NewPath) { 'exists' } else { 'ok' }
  }
}
