# owned-identify.ps1 — 所持チェックの「ブックマークにない作品」の見分け・手がかり・DLsite 検索（画面なし）。owned-core.ps1 のあとに読み込みます。
# ネットに送るのは、検索する言葉（ゲームの中の作品名か、フォルダ名を整えたもの）だけです。

# ---------- 1. 作品の見分け ----------

# 直下にゲームの印があるか：.exe ファイル、*_Data フォルダ、www フォルダ、data\System.json、Game.ini、package.json
function Test-GameFolder([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
  foreach ($rel in 'data\System.json', 'Game.ini', 'package.json') {
    if (Test-Path -LiteralPath (Join-Path $Path $rel) -PathType Leaf) { return $true }
  }
  if (Test-Path -LiteralPath (Join-Path $Path 'www') -PathType Container) { return $true }
  if (@(Get-ChildItem -LiteralPath $Path -Filter '*.exe' -File -Force -ErrorAction SilentlyContinue).Count) { return $true }
  if (@(Get-ChildItem -LiteralPath $Path -Filter '*_Data' -Directory -Force -ErrorAction SilentlyContinue).Count) { return $true }
  return $false
}

# 名前に RJ番号のない手元の作品（ブックマークに当たらないもの）を見分ける。
#   ・アーカイブは作品（ゲームのフォルダの中にあるものは除く）
#   ・印のあるフォルダは作品。その下の候補は除く（ゲームの中のフォルダ）
#   ・印のあるフォルダのすぐ外側が印のないフォルダで、その中の印のあるフォルダがそれ1つだけなら、外側を作品にする（「作品名\Game\Game.exe」など）
#   ・$ExcludePaths（ブックマークで当たった候補・「たぶん」の候補）、② のゲームフォルダとその親は除く
# 戻り値: Path / OldName / IsArchive の一覧
function Get-UnknownWorks($Candidates, [string[]]$ExcludePaths, [string[]]$GameDirs) {
  $cl = @($Candidates | ForEach-Object { $_ })
  $isDir = @{}; $byPath = @{}
  foreach ($c in $cl) {
    $p = ([string]$c.Path).TrimEnd('\')
    $byPath[$p] = $c
    $isDir[$p] = Test-Path -LiteralPath $p -PathType Container
  }
  $marker = @{}
  foreach ($p in @($byPath.Keys)) { if ($isDir[$p] -and (Test-GameFolder $p)) { $marker[$p] = $true } }
  $under = { param([string]$child, [string]$parent) $child.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase) }
  $hasMarkerAncestor = { param([string]$p) foreach ($m in $marker.Keys) { if (& $under $p $m) { return $true } }; return $false }
  $topMarkers = @($marker.Keys | Where-Object { -not (& $hasMarkerAncestor $_) })
  $works = [ordered]@{}
  foreach ($m in $topMarkers) {
    $w = $m
    $parent = Split-Path -Parent $m
    if ($byPath.ContainsKey($parent) -and -not $marker.ContainsKey($parent)) {
      if (@($topMarkers | Where-Object { & $under $_ $parent }).Count -eq 1) { $w = $parent }
    }
    $works[$w] = $false
  }
  foreach ($p in @($byPath.Keys)) {
    if (-not $isDir[$p] -and -not (& $hasMarkerAncestor $p)) { $works[$p] = $true }
  }
  # 「Game」「data」のような名前の子は候補に入らない（Get-GameCandidates が除く）ので、印のない候補は直下の子もディスクで確かめる
  foreach ($p in @($byPath.Keys)) {
    if (-not $isDir[$p] -or $marker.ContainsKey($p) -or $works.Contains($p) -or (& $hasMarkerAncestor $p)) { continue }
    if (@($topMarkers | Where-Object { & $under $_ $p }).Count) { continue }
    $kids = @(Get-ChildItem -LiteralPath $p -Directory -Force -ErrorAction SilentlyContinue | Where-Object { Test-GameFolder $_.FullName })
    if ($kids.Count -eq 1) { $works[$p] = $false }
  }
  $roots = @(@($GameDirs) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })
  $excl = @{}; foreach ($e in @($ExcludePaths)) { if ($e) { $excl[$e.TrimEnd('\')] = $true } }
  foreach ($w in $works.Keys) {
    $name = Split-Path -Leaf $w
    if ($name -match $script:CodeRe) { continue }
    if ($excl.ContainsKey($w)) { continue }
    # 外側にまとめた作品は、中の印のあるフォルダが除くものなら除く
    if (@($excl.Keys | Where-Object { & $under $_ $w }).Count) { continue }
    if (@($roots | Where-Object { $_ -ieq $w -or (& $under $_ $w) }).Count) { continue }
    [pscustomobject]@{ Path = $w; OldName = $name; IsArchive = [bool]$works[$w] }
  }
}
