# owned-identify.ps1 — 所持チェックの「ブックマークにない作品」の見分け・手がかり・DLsite 検索（画面なし）。owned-core.ps1 のあとに読み込みます。
# ネットに送るのは、検索する言葉（ゲームの中の作品名か、フォルダ名を整えたもの）だけです。

# ---------- 1. 作品の見分け ----------

# 直下にゲームの印があるか：.exe ファイル、*_Data フォルダ、www フォルダ、data\System.json、Game.ini、package.json
function Test-GameFolder([string]$Path) {
  if (-not [IO.Directory]::Exists($Path)) { return $false }
  foreach ($rel in 'data\System.json', 'Game.ini', 'package.json') {
    if ([IO.File]::Exists((Join-Path $Path $rel))) { return $true }
  }
  if ([IO.Directory]::Exists((Join-Path $Path 'www'))) { return $true }
  try {
    foreach ($f in [IO.Directory]::EnumerateFiles($Path, '*.exe')) { return $true }
    foreach ($d in [IO.Directory]::EnumerateDirectories($Path, '*_Data')) { return $true }
  } catch { }
  return $false
}

# パスの親を順にたどる（自分は含まない）
function Get-PathAncestors([string]$Path) {
  $p = [IO.Path]::GetDirectoryName($Path)
  while ($p) { $p.TrimEnd('\'); $p = [IO.Path]::GetDirectoryName($p) }
}

# 名前に RJ番号のない手元の作品（ブックマークに当たらないもの）を見分ける。
#   作品のもと（ユニット）：
#     ・印のあるフォルダ（外側に印のあるフォルダがないもの。その下の候補はゲームの中のフォルダとして除く）
#     ・アーカイブ（ゲームのフォルダの中にあるものは除く）
#     ・印のない候補で、下に候補の印のあるフォルダがなく、直下の子にディスクで見て印のあるフォルダがちょうど1つのもの
#       （「Game」「data」のような名前の子は Get-GameCandidates が候補から除くので、ディスクで確かめる。そのフォルダ自身を作品にする）
#   印のあるフォルダのすぐ外側が印のない候補で、その下にあるユニットがそれ1つだけなら、外側を作品にする（「作品名\Game\Game.exe」「作品\作品」）。
#   ほかにアーカイブや別の作品があるなら（サークルのフォルダ）、まとめない。最後に、作品の下にある作品は除く
#   $ExcludePaths（ブックマークで当たった候補・「たぶん」の候補）とその親、② のゲームフォルダとその親は除く
# 戻り値: Path / OldName / IsArchive の一覧
function Get-UnknownWorks($Candidates, [string[]]$ExcludePaths, [string[]]$GameDirs) {
  $byPath = @{}; $isDir = @{}
  foreach ($c in @($Candidates | ForEach-Object { $_ })) {
    $p = ([string]$c.Path).TrimEnd('\')
    $byPath[$p] = $c
    $isDir[$p] = [IO.Directory]::Exists($p)
  }
  $marker = @{}
  foreach ($p in @($byPath.Keys)) { if ($isDir[$p] -and (Test-GameFolder $p)) { $marker[$p] = $true } }
  $inMarker = { param([string]$p) foreach ($a in @(Get-PathAncestors $p)) { if ($marker.ContainsKey($a)) { return $true } }; return $false }
  $topMarkers = @($marker.Keys | Where-Object { -not (& $inMarker $_) })
  $archives = @($byPath.Keys | Where-Object { -not $isDir[$_] -and -not (& $inMarker $_) })
  # 印のある候補を下に持つフォルダ
  $hasMarkerBelow = @{}
  foreach ($m in $topMarkers) { foreach ($a in @(Get-PathAncestors $m)) { $hasMarkerBelow[$a] = $true } }
  $diskWorks = @()
  foreach ($p in @($byPath.Keys)) {
    if (-not $isDir[$p] -or $marker.ContainsKey($p) -or $hasMarkerBelow.ContainsKey($p) -or (& $inMarker $p)) { continue }
    $kids = 0
    try { foreach ($d in [IO.Directory]::EnumerateDirectories($p)) { if (Test-GameFolder $d) { $kids++; if ($kids -gt 1) { break } } } } catch { }
    if ($kids -eq 1) { $diskWorks += $p }
  }
  # ディスクで見た作品のさらに下の候補は、その作品の中のもの
  $diskSet = @{}; foreach ($d in $diskWorks) { $diskSet[$d] = $true }
  $inDisk = { param([string]$p) foreach ($a in @(Get-PathAncestors $p)) { if ($diskSet.ContainsKey($a)) { return $true } }; return $false }
  $diskWorks = @($diskWorks | Where-Object { -not (& $inDisk $_) })
  $archives = @($archives | Where-Object { -not (& $inDisk $_) })
  # フォルダごとに、その下にあるユニットの数
  $units = @($topMarkers) + @($archives) + @($diskWorks)
  $below = @{}
  foreach ($u in $units) { foreach ($a in @(Get-PathAncestors $u)) { $below[$a] = 1 + [int]$below[$a] } }
  $works = [ordered]@{}
  foreach ($m in $topMarkers) {
    $w = $m
    $parent = [IO.Path]::GetDirectoryName($m)
    if ($parent -and $byPath.ContainsKey($parent) -and $isDir[$parent] -and [int]$below[$parent] -eq 1) { $w = $parent }
    $works[$w] = $false
  }
  foreach ($d in $diskWorks) { $works[$d] = $false }
  foreach ($a in $archives) { $works[$a] = $true }
  $workSet = @{}; foreach ($w in $works.Keys) { $workSet[$w] = $true }
  $blocked = @{}
  foreach ($r in @($GameDirs) + @($ExcludePaths)) {
    if (-not $r) { continue }
    $r = $r.TrimEnd('\'); $blocked[$r] = $true
    foreach ($a in @(Get-PathAncestors $r)) { $blocked[$a] = $true }
  }
  foreach ($w in $works.Keys) {
    $name = Split-Path -Leaf $w
    if ($name -match $script:CodeRe) { continue }
    if ($blocked.ContainsKey($w)) { continue }
    $nested = $false
    foreach ($a in @(Get-PathAncestors $w)) { if ($workSet.ContainsKey($a)) { $nested = $true; break } }
    if ($nested) { continue }
    [pscustomobject]@{ Path = $w; OldName = $name; IsArchive = [bool]$works[$w] }
  }
}

# ---------- 2. 中の手がかりと検索する言葉 ----------

$script:InsideTextExt = '.txt', '.url', '.html', '.htm', '.md', '.ini', '.json', '.nfo'
# 1つの作品で見るファイルの数の上限（ゲームは数千ファイルあることがあるため。浅いところから見る）
$script:InsideMaxFiles = 5000

# フォルダの中のファイル名（$script:InsideMaxFiles 個まで）と、小さなテキストファイル（200KB 未満、50 個まで）の中身から RJ番号を探す。
# 戻り値: 見つけた順の RJ番号（大文字・重複なし）。アーカイブなら空
function Find-InsideCodes([string]$Path) {
  $found = New-Object System.Collections.Generic.List[string]
  if (-not [IO.Directory]::Exists($Path)) { return $found.ToArray() }
  $add = { param([string]$s) foreach ($m in [regex]::Matches($s, $script:CodeRe, 'IgnoreCase')) { $c = $m.Groups[1].Value.ToUpperInvariant(); if (-not $found.Contains($c)) { $found.Add($c) } } }
  # 浅い階層から順に見る（readme などは浅いところにあることが多い）
  $files = New-Object System.Collections.Generic.List[IO.FileInfo]
  $queue = New-Object System.Collections.Generic.Queue[string]
  $queue.Enqueue($Path)
  while ($queue.Count -and $files.Count -lt $script:InsideMaxFiles) {
    $d = New-Object IO.DirectoryInfo $queue.Dequeue()
    try {
      foreach ($f in $d.EnumerateFiles()) { if ($files.Count -ge $script:InsideMaxFiles) { break }; $files.Add($f) }
      foreach ($s in $d.EnumerateDirectories()) { $queue.Enqueue($s.FullName) }
    } catch { }
  }
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

# ---------- 3. DLsite の検索と保存 ----------

$script:SearchFloors = 'maniax', 'home'   # R18 と全年齢の売り場

# DLsite の検索（/fsr/ajax/）の返事（JSON の中に HTML）から、作品を上から5件（同じ番号は1つ）読む。形が違えば空
# 戻り値: Code / Title の一覧
function ConvertFrom-DLsiteSearch([string]$Json) {
  $out = New-Object System.Collections.Generic.List[object]
  try { $html = [string]($Json | ConvertFrom-Json).search_result } catch { return $out.ToArray() }
  if (-not $html) { return $out.ToArray() }
  $re = '<dd class="work_name">.*?<a [^>]*href="[^"]*/product_id/((?:RJ|VJ|BJ|RE)\d{6,8})\.html"[^>]*title="([^"]*)"'
  foreach ($m in [regex]::Matches($html, $re, 'Singleline')) {
    $code = $m.Groups[1].Value.ToUpperInvariant()
    if (@($out | Where-Object Code -eq $code).Count) { continue }
    $out.Add([pscustomobject]@{ Code = $code; Title = [System.Web.HttpUtility]::HtmlDecode($m.Groups[2].Value) })
    if ($out.Count -ge 5) { break }
  }
  return $out.ToArray()
}

# 検索する言葉で DLsite の R18 と全年齢の売り場を検索する（送るのは言葉だけ）。問い合わせの間は 800 ミリ秒あける。
# 戻り値: Ok（どちらも返事が取れたか）/ Hits（Code / Title / Floor の一覧。取れた分）
function Search-DLsite([string]$Term, [int]$TimeoutSec = 10) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $ok = $true
  $hits = New-Object System.Collections.Generic.List[object]
  $first = $true
  foreach ($floor in $script:SearchFloors) {
    if (-not $first) { Start-Sleep -Milliseconds 800 }
    $first = $false
    $url = "https://www.dlsite.com/$floor/fsr/ajax/=/language/jp/keyword/$([uri]::EscapeDataString($Term))/"
    try {
      $res = Invoke-WebRequest -Uri $url -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec $TimeoutSec
      $ms = New-Object IO.MemoryStream
      $res.RawContentStream.Position = 0; $res.RawContentStream.CopyTo($ms)
      foreach ($h in @(ConvertFrom-DLsiteSearch ([Text.Encoding]::UTF8.GetString($ms.ToArray())))) {
        $hits.Add([pscustomobject]@{ Code = $h.Code; Title = $h.Title; Floor = $floor })
      }
    } catch { $ok = $false }
  }
  return [pscustomobject]@{ Ok = $ok; Hits = $hits.ToArray() }
}

# 自動でチェックを付けてよい番号：ゲームの中の作品名で検索したときだけ、正規化した作品名が検索した言葉と同じものが全体で1つならその番号。ほかは ''
function Select-AutoCode($Hits, [string]$Term, [bool]$FromInnerTitle) {
  if (-not $FromInnerTitle) { return '' }
  $t = Normalize-Title $Term
  if (-not $t) { return '' }
  $same = @(@($Hits) | Where-Object { $_ -and (Normalize-Title $_.Title) -eq $t } | ForEach-Object Code | Select-Object -Unique)
  if ($same.Count -eq 1) { return [string]$same[0] }
  return ''
}

# 検索の結果の保存（dlsite-search-cache.json）。形: { "検索語": { "Ok": true, "At": "yyyy-MM-dd", "Hits": [ { "Code", "Title", "Floor" } ] } }
function Read-SearchCache([string]$Path) {
  $c = @{}
  if (-not (Test-Path -LiteralPath $Path)) { return $c }
  try {
    $o = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $o.PSObject.Properties) { $c[$p.Name] = [pscustomobject]@{ Ok = [bool]$p.Value.Ok; At = [string]$p.Value.At; Hits = @($p.Value.Hits | Where-Object { $_ }) } }
  } catch { }
  return $c
}

function Save-SearchCache([string]$Path, [hashtable]$Cache) {
  $o = [ordered]@{}
  foreach ($k in @($Cache.Keys | Sort-Object)) { $v = $Cache[$k]; $o[$k] = [ordered]@{ Ok = [bool]$v.Ok; At = [string]$v.At; Hits = @($v.Hits) } }
  [IO.File]::WriteAllText($Path, ($o | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
}
