# owned-core.ps1 — 所持チェックの処理本体（GUI 版とコマンド版の両方から読み込まれます）
# すべてこのPCの中だけで処理します。ネットにアクセスするのは「URL をまとめて追加」で作品名を DLsite から取るときだけです（送るのは RJ 番号だけ）。

Add-Type -AssemblyName System.Web

$script:CodeRe = '(?<![A-Za-z0-9])((?:RJ|VJ|BJ|RE)\d{6,8})(?![0-9])'

# ---------- 文字列の正規化と似かたの計算 ----------

# 比較用に作品名を整える：全角半角統一・小文字化・[サークル名] や (Ver..) などの付加情報を除去・記号除去
function Normalize-Title([string]$s) {
  if (-not $s) { return '' }
  $s = $s.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant()
  $s = $s -replace '\s*[|｜]\s*dlsite.*$', ''
  $s = $s -replace '\[[^\]]*\]|【[^】]*】|\([^)]*\)|〔[^〕]*〕', ' '
  $s = $s -replace '(?:\bver(?:sion)?\.?\s*|\bv)\d+(?:[._\-]\d+)*[a-z]?', ' '
  $s = $s -replace '(体験版|trial|demo|完全版|製品版|dl版|パッケージ版|日本語版|english|translation|patch)', ' '
  $s = $s -replace '[^\p{L}\p{N}]', ''
  return $s
}

function Get-Bigrams([string]$s) {
  $set = New-Object 'System.Collections.Generic.HashSet[string]'
  if ($s.Length -eq 1) { [void]$set.Add($s) }
  for ($i = 0; $i -lt $s.Length - 1; $i++) { [void]$set.Add($s.Substring($i, 2)) }
  return ,$set
}

# 2文字ずつに区切った重なり具合（0〜1）
function Get-Similarity($bgA, $bgB) {
  if ($bgA.Count -eq 0 -or $bgB.Count -eq 0) { return 0.0 }
  $inter = 0
  foreach ($x in $bgA) { if ($bgB.Contains($x)) { $inter++ } }
  return (2.0 * $inter) / ($bgA.Count + $bgB.Count)
}

# ---------- 1. 気になるリストを読む ----------

# 対応: Session Buddy のエクスポート（JSON/CSV/テキスト）、Chrome/Edge の Bookmarks、
#       ブックマークの HTML エクスポート、URL を書いただけのテキスト
# $BookmarkFolder を指定すると、Chrome / Edge の Bookmarks ファイルはそのフォルダの中（サブフォルダ含む）だけを読む
function Read-Wishlist([string[]]$Files, [string]$BookmarkFolder) {
  $wish = [ordered]@{}

  $add = {
    param([string]$url, [string]$title)
    if ($url -notmatch 'dlsite\.com') { return }
    if ($url -notmatch $script:CodeRe) { return }
    $code = $Matches[1].ToUpperInvariant()
    if (-not $wish.Contains($code)) { $wish[$code] = [pscustomobject]@{ Code = $code; Url = $url; Title = '' } }
    if ($title -and -not $wish[$code].Title) { $wish[$code].Title = ($title -replace '\s*[|｜]\s*DLsite.*$', '').Trim() }
  }

  $walk = {
    param($node)
    if ($null -eq $node) { return }
    if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
      foreach ($n in $node) { & $walk $n }
      return
    }
    if ($node -is [pscustomobject]) {
      $props = $node.PSObject.Properties
      $url = ($props | Where-Object { $_.Name -match '^(url|href|link)$' } | Select-Object -First 1).Value
      $title = ($props | Where-Object { $_.Name -match '^(title|name)$' } | Select-Object -First 1).Value
      if ($url -is [string]) { & $add $url ([string]$title) }
      foreach ($p in $props) { if ($p.Value -isnot [string]) { & $walk $p.Value } }
    }
  }

  $urlRe = 'https?://[^\s"''<>,]*dlsite\.com[^\s"''<>,]*'
  foreach ($file in $Files) {
    if (-not (Test-Path -LiteralPath $file)) { throw "ファイルが見つかりません: $file" }
    $text = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    if (-not $text) { continue }
    # ブラウザの Bookmarks ファイルでフォルダ指定があるときは、そのフォルダだけをたどる
    if ($BookmarkFolder) {
      $bmJson = $null
      try { $bmJson = $text | ConvertFrom-Json } catch { }
      if ($bmJson -and $bmJson.roots) {
        foreach ($node in @(Get-BookmarkFolderNodes $bmJson $BookmarkFolder)) { & $walk $node.children }
        continue
      }
    }
    $t = $text.TrimStart()
    if ($t.StartsWith('{') -or $t.StartsWith('[')) {
      try { & $walk ($text | ConvertFrom-Json) } catch { }
    }
    $lines = $text -split "\r?\n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
      foreach ($m in [regex]::Matches($lines[$i], $urlRe)) {
        $rest = ($lines[$i] -replace [regex]::Escape($m.Value), '' -replace '^[\s,;"\-–|]+|[\s,;"\-–|]+$', '')
        $rest = [System.Web.HttpUtility]::HtmlDecode(($rest -replace '<[^>]*>', '')).Trim()
        if (-not $rest -and $i -gt 0) { $rest = $lines[$i - 1].Trim() }
        if ($rest -match 'https?://') { $rest = '' }
        & $add $m.Value $rest
      }
    }
  }
  return @($wish.Values)
}

# ---------- 2. ゲームフォルダの中の名前を集める ----------

function Get-GameCandidates([string[]]$Dirs, [int]$Depth = 2) {
  $cands = New-Object System.Collections.Generic.List[object]
  $archiveExt = '.zip', '.rar', '.7z', '.lzh'
  $collect = {
    param([string]$dir, [int]$level)
    if ($level -gt $Depth) { return }
    foreach ($item in Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue) {
      $isDir = $item.PSIsContainer
      if ($isDir -or $archiveExt -contains $item.Extension.ToLowerInvariant()) {
        $name = if ($isDir) { $item.Name } else { [IO.Path]::GetFileNameWithoutExtension($item.Name) }
        $norm = Normalize-Title $name
        $code = if ($name -match $script:CodeRe) { $Matches[1].ToUpperInvariant() } else { $null }
        $cands.Add([pscustomobject]@{ Name = $name; Path = $item.FullName; Norm = $norm; Bigrams = (Get-Bigrams $norm); Code = $code })
      }
      if ($isDir) { & $collect $item.FullName ($level + 1) }
    }
  }
  foreach ($d in $Dirs) {
    if (-not (Test-Path -LiteralPath $d)) { throw "ゲームフォルダが見つかりません: $d" }
    & $collect $d 1
  }
  return ,$cands
}

# ---------- 3. 照らし合わせ ----------

# Status: owned（持っている）/ maybe（たぶん）/ notowned（持っていない）
function Compare-Owned($Wishlist, $Candidates, [double]$Threshold = 0.6) {
  foreach ($w in $Wishlist) {
    $wn = Normalize-Title $w.Title
    $wb = Get-Bigrams $wn
    $best = $null; $bestScore = 0.0; $how = ''
    foreach ($c in $Candidates) {
      if ($c.Code -and $c.Code -eq $w.Code) { $best = $c; $bestScore = 1.0; $how = 'RJ番号が一致'; break }
      if (-not $wn -or -not $c.Norm) { continue }
      if ($c.Norm -eq $wn) { $best = $c; $bestScore = 1.0; $how = '作品名が一致'; break }
      $score = Get-Similarity $wb $c.Bigrams
      $short = [Math]::Min($wn.Length, $c.Norm.Length)
      if ($short -ge 4 -and ($wn.Contains($c.Norm) -or $c.Norm.Contains($wn))) { $score = [Math]::Max($score, 0.85) }
      if ($score -gt $bestScore) { $best = $c; $bestScore = $score; $how = '作品名が似ている' }
    }
    $status = if ($bestScore -ge 0.999) { 'owned' } elseif ($bestScore -ge $Threshold) { 'maybe' } else { 'notowned' }
    [pscustomobject]@{
      Code = $w.Code; Url = $w.Url; Title = $(if ($w.Title) { $w.Title } else { '(タイトル不明)' })
      Status = $status; Score = [Math]::Round($bestScore, 2); How = $how
      Match = $(if ($best -and $status -ne 'notowned') { $best.Name } else { '' })
      MatchPath = $(if ($best -and $status -ne 'notowned') { $best.Path } else { '' })
      NearName = $(if ($best -and $status -eq 'notowned' -and $bestScore -ge 0.4) { $best.Name } else { '' })
    }
  }
}

# ---------- 4. HTML レポート ----------

function Esc-Html([string]$s) { [System.Web.HttpUtility]::HtmlEncode($s) }

function Write-OwnedReport($Results, [int]$WishCount, [int]$CandCount, [double]$Threshold, [string]$OutPath) {
  $section = {
    param($title, $status, $note)
    $rows = @($Results | Where-Object Status -eq $status)
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<section><h2>$(Esc-Html $title) <span class='n'>$($rows.Count)</span></h2><p class='note'>$(Esc-Html $note)</p>")
    if ($rows.Count -eq 0) { [void]$sb.Append("<p class='empty'>なし</p></section>"); return $sb.ToString() }
    [void]$sb.Append('<table><thead><tr><th>作品</th><th>RJ番号</th><th>手元の一致候補</th><th>似かた</th></tr></thead><tbody>')
    foreach ($r in ($rows | Sort-Object Score -Descending)) {
      $m = if ($r.Match) { "<span title='$(Esc-Html $r.MatchPath)'>$(Esc-Html $r.Match)</span><br><small>$(Esc-Html $r.How)</small>" }
           elseif ($r.NearName) { "<small>いちばん近い: $(Esc-Html $r.NearName)</small>" } else { '' }
      [void]$sb.Append("<tr><td><a href='$(Esc-Html $r.Url)' target='_blank' rel='noreferrer'>$(Esc-Html $r.Title)</a></td><td>$(Esc-Html $r.Code)</td><td>$m</td><td>$($r.Score)</td></tr>")
    }
    [void]$sb.Append('</tbody></table></section>')
    return $sb.ToString()
  }

  $html = @"
<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>所持チェック結果</title>
<style>
:root{--bg:#fff;--fg:#1f2328;--mut:#656d76;--line:#d0d7de;--ok:#1a7f37;--mb:#9a6700;--no:#0969da}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--mut:#8d96a0;--line:#30363d;--ok:#3fb950;--mb:#d29922;--no:#4493f8}}
body{background:var(--bg);color:var(--fg);font:14px/1.6 system-ui,"Yu Gothic UI",sans-serif;margin:0 auto;max-width:1100px;padding:16px}
h1{font-size:20px} h2{font-size:16px;margin:28px 0 4px} .n{color:var(--mut);font-weight:normal}
.note,.empty,small{color:var(--mut)} table{border-collapse:collapse;width:100%} th,td{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top}
th{font-size:12px;color:var(--mut)} a{color:var(--no)}
section:nth-of-type(1) h2{color:var(--ok)} section:nth-of-type(2) h2{color:var(--mb)} section:nth-of-type(3) h2{color:var(--no)}
</style></head><body>
<h1>所持チェック結果</h1>
<p class="note">$(Get-Date -Format 'yyyy-MM-dd HH:mm') 作成 ／ 気になるリスト $WishCount 作品 ／ 照合したフォルダ・ファイル $CandCount 件 ／ 判定基準 $Threshold</p>
$(& $section '持っている' 'owned' 'RJ番号か作品名が完全に一致したもの')
$(& $section 'たぶん持っている（要確認）' 'maybe' '作品名が似ているもの。手元の一致候補にマウスを乗せると場所が出ます')
$(& $section '持っていない' 'notowned' '手元に似た名前が見つからなかったもの')
</body></html>
"@
  [IO.File]::WriteAllText($OutPath, $html, (New-Object Text.UTF8Encoding $true))
}

# ---------- 5. ブラウザのブックマーク ----------

# このPCにある Chrome / Edge の Bookmarks ファイルを探す（プロフィール名つき）
function Find-BrowserBookmarks {
  $browsers = @(
    @{ Name = 'Chrome'; Root = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data' },
    @{ Name = 'Edge';   Root = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data' }
  )
  foreach ($b in $browsers) {
    if (-not (Test-Path -LiteralPath $b.Root)) { continue }
    $names = @{}
    try {
      $ls = Get-Content -LiteralPath (Join-Path $b.Root 'Local State') -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($p in $ls.profile.info_cache.PSObject.Properties) { $names[$p.Name] = $p.Value.name }
    } catch { }
    foreach ($dir in Get-ChildItem -LiteralPath $b.Root -Directory -ErrorAction SilentlyContinue) {
      $bm = Join-Path $dir.FullName 'Bookmarks'
      if (Test-Path -LiteralPath $bm) {
        $label = if ($names[$dir.Name]) { "$($b.Name) - $($names[$dir.Name])" } else { "$($b.Name) - $($dir.Name)" }
        [pscustomobject]@{ Label = $label; Path = $bm }
      }
    }
  }
}

# Bookmarks の中のフォルダを「ブックマーク バー / DLsite気になる」のような道順つきで列挙する
function Get-BookmarkFolderPaths([string]$Path) {
  $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  $out = New-Object System.Collections.Generic.List[string]
  $visit = {
    param($node, [string]$prefix)
    foreach ($c in @($node.children)) {
      if ($c.type -eq 'folder') {
        $p = "$prefix / $($c.name)"
        $out.Add($p)
        & $visit $c $p
      }
    }
  }
  foreach ($r in $json.roots.PSObject.Properties) {
    if ($r.Value -is [pscustomobject] -and $r.Value.children) { & $visit $r.Value $r.Value.name }
  }
  return $out.ToArray()
}

# 道順（Get-BookmarkFolderPaths の形）に一致するフォルダのノードを返す
function Get-BookmarkFolderNodes($Json, [string]$FolderPath) {
  $found = New-Object System.Collections.Generic.List[object]
  $visit = {
    param($node, [string]$prefix)
    foreach ($c in @($node.children)) {
      if ($c.type -eq 'folder') {
        $p = "$prefix / $($c.name)"
        if ($p -eq $FolderPath) { $found.Add($c) } else { & $visit $c $p }
      }
    }
  }
  foreach ($r in $Json.roots.PSObject.Properties) {
    if ($r.Value -is [pscustomobject] -and $r.Value.children) { & $visit $r.Value $r.Value.name }
  }
  return $found.ToArray()
}

function Test-BookmarksFile([string]$Path) {
  try { $null -ne (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json).roots } catch { $false }
}

# Bookmarks ファイルを使っているブラウザが起動中なら、そのプロセス名を返す（起動していなければ空）
function Get-RunningBrowser([string]$Path) {
  $procs = if ($Path -match '\\Microsoft\\Edge\\') { 'msedge' }
           elseif ($Path -match '\\Google\\Chrome\\') { 'chrome' }
           else { 'chrome', 'msedge' }
  $running = @(Get-Process -Name $procs -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique)
  return $running
}

# 指定した RJ 番号のブックマークを削除する。フォルダや DLsite 以外のブックマークには触れない。
# 戻り値: @{ Removed = 消したブックマーク名の一覧; Backup = バックアップのパス }
# $Folder を指定すると、そのフォルダの中（サブフォルダ含む）だけから消す
function Remove-BookmarksByCode([string]$Path, [string[]]$Codes, [string]$BackupDir, [switch]$DryRun, [string]$Folder) {
  $codeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($c in $Codes) { [void]$codeSet.Add($c) }
  $removed = New-Object System.Collections.Generic.List[string]

  $prune = {
    param($node)
    if ($null -eq $node.children) { return }
    $keep = New-Object System.Collections.Generic.List[object]
    foreach ($c in $node.children) {
      if ($c.type -eq 'url' -and $c.url -match 'dlsite\.com' -and $c.url -match $script:CodeRe -and $codeSet.Contains($Matches[1])) {
        $removed.Add("$($c.name)")
        continue
      }
      if ($c.type -eq 'folder') { & $prune $c }
      $keep.Add($c)
    }
    $node.children = $keep.ToArray()
  }

  $full = (Resolve-Path -LiteralPath $Path).Path
  $json = Get-Content -LiteralPath $full -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($Folder) {
    foreach ($node in @(Get-BookmarkFolderNodes $json $Folder)) { & $prune $node }
  } else {
    foreach ($p in $json.roots.PSObject.Properties) { if ($p.Value -is [pscustomobject]) { & $prune $p.Value } }
  }

  $result = @{ Removed = $removed.ToArray(); Backup = $null }
  if ($DryRun -or $removed.Count -eq 0) { return $result }

  New-Item -ItemType Directory -Force $BackupDir | Out-Null
  $tag = if ($full -match '\\Microsoft\\Edge\\') { 'Edge' } elseif ($full -match '\\Google\\Chrome\\') { 'Chrome' } else { 'Other' }
  $bk = Join-Path $BackupDir ("Bookmarks-{0}-{1}" -f $tag, (Get-Date -Format 'yyyyMMdd-HHmmss'))
  Copy-Item -LiteralPath $full -Destination $bk
  $result.Backup = $bk

  # checksum は中身が変わると合わなくなるので外す（ブラウザが次回起動時に作り直す）
  $json.PSObject.Properties.Remove('checksum')
  [IO.File]::WriteAllText($full, ($json | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding $false))
  return $result
}

# ---------- 6. まとめて追加 ----------

# 文字列（URL の羅列、Session Buddy のテキストなど）から DLsite の作品を取り出す
function Read-WishlistFromText([string]$Text) {
  $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), "owned-paste-$([guid]::NewGuid()).txt")
  try {
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding $false))
    return @(Read-Wishlist @($tmp))
  } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}

# DLsite から作品名を取ってくる（送るのは RJ 番号だけ）。戻り値: @{ RJ番号 = 作品名 }
function Get-DLsiteTitles([string[]]$Codes) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $titles = @{}
  $list = @($Codes | Select-Object -Unique)
  for ($i = 0; $i -lt $list.Count; $i += 30) {
    $chunk = $list[$i..([Math]::Min($i + 29, $list.Count - 1))]
    $url = 'https://www.dlsite.com/maniax/product/info/ajax?cdn_cache_min=1&product_id=' + ($chunk -join ',')
    try {
      $res = Invoke-WebRequest -Uri $url -UseBasicParsing -UserAgent 'Mozilla/5.0' -TimeoutSec 30
      $ms = New-Object IO.MemoryStream
      $res.RawContentStream.Position = 0; $res.RawContentStream.CopyTo($ms)
      $json = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
      foreach ($p in $json.PSObject.Properties) { if ($p.Value.work_name) { $titles[$p.Name.ToUpperInvariant()] = [string]$p.Value.work_name } }
    } catch { }
    if ($i + 30 -lt $list.Count) { Start-Sleep -Milliseconds 800 }
  }
  return $titles
}

# Chrome / Edge の時刻（1601-01-01 からのマイクロ秒）
function Get-ChromeTime {
  # 100ナノ秒単位の Ticks の末尾1桁を落としてマイクロ秒にする（割り算すると小数・指数表記になるため文字列で処理）
  $t = ([DateTime]::UtcNow - [DateTime]::new(1601, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).Ticks.ToString()
  return $t.Substring(0, $t.Length - 1)
}

# 指定フォルダに作品のブックマークを追加する。フォルダの中にすでにある作品は追加しない。
# $Items: Code / Url / Title を持つもの。戻り値: @{ Added = 追加した名前; Skipped = 既にあった数; Backup }
function Add-BookmarksToFolder([string]$Path, [string]$Folder, $Items, [string]$BackupDir, [switch]$DryRun) {
  $full = (Resolve-Path -LiteralPath $Path).Path
  $json = Get-Content -LiteralPath $full -Raw -Encoding UTF8 | ConvertFrom-Json
  $target = @(Get-BookmarkFolderNodes $json $Folder) | Select-Object -First 1
  if (-not $target) { throw "ブックマークのフォルダが見つかりません: $Folder" }

  # すでにフォルダ（サブフォルダ含む）にある RJ 番号と、全体で使われている最大の id を調べる
  $have = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $script:maxId = 0
  $scan = {
    param($node, [bool]$inTarget)
    foreach ($c in @($node.children)) {
      $n = 0; if ([long]::TryParse("$($c.id)", [ref]$n) -and $n -gt $script:maxId) { $script:maxId = $n }
      $inside = $inTarget -or ($c.type -eq 'folder' -and "$($c.id)" -eq "$($target.id)")
      if ($inside -and $c.type -eq 'url' -and $c.url -match $script:CodeRe) { [void]$have.Add($Matches[1]) }
      if ($c.type -eq 'folder') { & $scan $c $inside }
    }
  }
  foreach ($r in $json.roots.PSObject.Properties) {
    if ($r.Value -is [pscustomobject]) {
      $n = 0; if ([long]::TryParse("$($r.Value.id)", [ref]$n) -and $n -gt $script:maxId) { $script:maxId = $n }
      & $scan $r.Value $false
    }
  }

  $added = New-Object System.Collections.Generic.List[string]
  $newNodes = New-Object System.Collections.Generic.List[object]
  $skipped = 0
  $now = Get-ChromeTime
  foreach ($it in $Items) {
    if ($have.Contains($it.Code)) { $skipped++; continue }
    [void]$have.Add($it.Code)
    $script:maxId++
    $name = if ($it.Title -and $it.Title -ne '(タイトル不明)') { $it.Title } else { $it.Code }
    $newNodes.Add([pscustomobject][ordered]@{
      date_added = $now; date_last_used = '0'; guid = [guid]::NewGuid().ToString()
      id = [string]$script:maxId; name = $name; type = 'url'; url = $it.Url
    })
    $added.Add($name)
  }

  $result = @{ Added = $added.ToArray(); Skipped = $skipped; Backup = $null }
  if ($DryRun -or $added.Count -eq 0) { return $result }

  New-Item -ItemType Directory -Force $BackupDir | Out-Null
  $tag = if ($full -match '\\Microsoft\\Edge\\') { 'Edge' } elseif ($full -match '\\Google\\Chrome\\') { 'Chrome' } else { 'Other' }
  $bk = Join-Path $BackupDir ("Bookmarks-{0}-{1}" -f $tag, (Get-Date -Format 'yyyyMMdd-HHmmss'))
  Copy-Item -LiteralPath $full -Destination $bk
  $result.Backup = $bk

  $target.children = @(@($target.children) + $newNodes.ToArray() | Where-Object { $null -ne $_ })
  $json.PSObject.Properties.Remove('checksum')
  [IO.File]::WriteAllText($full, ($json | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding $false))
  return $result
}