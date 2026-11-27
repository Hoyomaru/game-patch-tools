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

# ---------- 2. 中の手がかりと検索する言葉 ----------

$script:InsideTextExt = '.txt', '.url', '.html', '.htm', '.md', '.ini', '.json', '.nfo'

# フォルダの中のファイル名と、小さなテキストファイル（200KB 未満、50 個まで）の中身から RJ番号を探す。
# 戻り値: 見つけた順の RJ番号（大文字・重複なし）。アーカイブなら空
function Find-InsideCodes([string]$Path) {
  $found = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $found.ToArray() }
  $add = { param([string]$s) foreach ($m in [regex]::Matches($s, $script:CodeRe, 'IgnoreCase')) { $c = $m.Groups[1].Value.ToUpperInvariant(); if (-not $found.Contains($c)) { $found.Add($c) } } }
  $files = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)
  foreach ($f in $files) { & $add $f.Name }
  $texts = @($files | Where-Object { $_.Length -lt 200KB -and $script:InsideTextExt -contains $_.Extension.ToLowerInvariant() } | Select-Object -First 50)
  foreach ($f in $texts) {
    try { & $add ([IO.File]::ReadAllText($f.FullName)) } catch { }
  }
  return $found.ToArray()
}

function Read-JsonFile([string]$Path) {
  try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# ゲームの中に書いてある作品名。なければ ''
#   ツクールMV/MZ の System.json の gameTitle → ツクールVX/XP の Game.ini の Title（Shift_JIS）→ package.json の window.title か name → Unity の *_Data\app.info の2行目
function Get-InnerGameTitle([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return '' }
  foreach ($rel in 'data\System.json', 'www\data\System.json') {
    $p = Join-Path $Path $rel
    if (Test-Path -LiteralPath $p -PathType Leaf) { $j = Read-JsonFile $p; if ($j -and $j.gameTitle) { return ([string]$j.gameTitle).Trim() } }
  }
  $p = Join-Path $Path 'Game.ini'
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    try {
      foreach ($l in [IO.File]::ReadAllLines($p, [Text.Encoding]::GetEncoding(932))) { if ($l -match '^\s*Title\s*=\s*(.+?)\s*$') { return $Matches[1] } }
    } catch { }
  }
  $p = Join-Path $Path 'package.json'
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    $j = Read-JsonFile $p
    if ($j -and $j.window -and $j.window.title) { return ([string]$j.window.title).Trim() }
    if ($j -and $j.name) { return ([string]$j.name).Trim() }
  }
  foreach ($d in @(Get-ChildItem -LiteralPath $Path -Filter '*_Data' -Directory -Force -ErrorAction SilentlyContinue)) {
    $p = Join-Path $d.FullName 'app.info'
    if (Test-Path -LiteralPath $p -PathType Leaf) {
      try { $l = @([IO.File]::ReadAllLines($p, [Text.Encoding]::UTF8)); if ($l.Count -ge 2 -and $l[1].Trim()) { return $l[1].Trim() } } catch { }
    }
  }
  return ''
}

# フォルダ名（アーカイブなら拡張子を除く）から検索する言葉を作る：版・括弧の中・「体験版」などを除き、記号は空白1つにまとめる
function New-SearchTerm([string]$Name, [bool]$IsArchive) {
  $s = if ($IsArchive) { [IO.Path]::GetFileNameWithoutExtension($Name) } else { $Name }
  $s = $s.Normalize([Text.NormalizationForm]::FormKC)
  $s = $s -replace '\[[^\]]*\]|【[^】]*】|\([^)]*\)|〔[^〕]*〕', ' '
  $s = $s -replace '(?i)(?:(?<![a-z0-9])ver(?:sion)?\.?\s*|(?<![a-z0-9])v)\d+(?:[._\-]\d+)*[a-z]?(?![\w.])', ' '
  $s = $s -replace '(?i)(体験版|trial|demo|完全版|製品版|dl版|パッケージ版|日本語版|english|translation|patch)', ' '
  $s = $s -replace '[^\p{L}\p{N}]+', ' '
  return $s.Trim()
}
