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

# 照合の重い部分（全候補との比較）は C# で行う。PowerShell のループだと、数百×数千件で十数秒〜1分かかるため。
# 中身は以前の PowerShell 版と同じ計算です。
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class OwnedMatch2 {
  // 2文字ずつに区切った重なり具合（0〜1）
  public static double Dice(HashSet<string> a, HashSet<string> b) {
    if (a == null || b == null || a.Count == 0 || b.Count == 0) return 0.0;
    int n = 0;
    foreach (var x in a) if (b.Contains(x)) n++;
    return 2.0 * n / (a.Count + b.Count);
  }
  // 作品名 wn にいちばん似ている候補を探す。戻り値: { 候補の番号（なければ -1）, 似かた, 完全一致なら 1 }
  //   完全一致 → 1.0 ですぐ返す
  //   片方がもう片方を含む（短い方が containMin 文字以上）→ 少なくとも containScore
  //   skip に入っている候補は見ない（「別の作品」と確かめた候補）
  public static double[] Best(string wn, HashSet<string> wb, string[] norms, HashSet<string>[] bgs,
                               int containMin, double containScore, HashSet<int> skip) {
    int idx = -1; double best = 0.0;
    if (string.IsNullOrEmpty(wn)) return new double[] { -1, 0, 0 };
    for (int i = 0; i < norms.Length; i++) {
      if (skip != null && skip.Contains(i)) continue;
      string cn = norms[i];
      if (string.IsNullOrEmpty(cn)) continue;
      if (cn == wn) return new double[] { i, 1.0, 1 };
      double s = Dice(wb, bgs[i]);
      if (Math.Min(wn.Length, cn.Length) >= containMin && (wn.Contains(cn) || cn.Contains(wn))) s = Math.Max(s, containScore);
      if (s > best) { best = s; idx = i; }
    }
    return new double[] { idx, best, 0 };
  }
}
'@

# 2文字ずつに区切った重なり具合（0〜1）
function Get-Similarity($bgA, $bgB) { [OwnedMatch2]::Dice($bgA, $bgB) }

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

# ゲームの中によくあるフォルダ。作品名ではないので候補にせず、中にも入らない
# （「Game」「audio」などが作品名の一部と一致して「たぶん持っている」になるのを防ぐ）
$script:GameInternalDirRe = '^(?:www|data|save|saves|savedata|audio|bgm|se|sound|sounds|music|movie|movies|video|img|image|images|graphics|pictures|fonts?|js|css|locales|swiftshader|system|game|lib|libs|plugins?|icons?|effects|monobleedingedge|.+_data)$'

# 戻り値: 候補の一覧。見つからなかったゲームフォルダは飛ばし、$script:MissingGameDirs に入れる（全部見つからなければエラー）
function Get-GameCandidates([string[]]$Dirs, [int]$Depth = 2) {
  $cands = New-Object System.Collections.Generic.List[object]
  $archiveExt = '.zip', '.rar', '.7z', '.lzh'
  $collect = {
    param([string]$dir, [int]$level)
    if ($level -gt $Depth) { return }
    foreach ($item in Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue) {
      $isDir = $item.PSIsContainer
      if ($isDir -and $level -gt 1 -and $item.Name -match $script:GameInternalDirRe) { continue }
      if ($isDir -or $archiveExt -contains $item.Extension.ToLowerInvariant()) {
        $name = if ($isDir) { $item.Name } else { [IO.Path]::GetFileNameWithoutExtension($item.Name) }
        $norm = Normalize-Title $name
        $code = if ($name -match $script:CodeRe) { $Matches[1].ToUpperInvariant() } else { $null }
        $cands.Add([pscustomobject]@{ Name = $name; Path = $item.FullName; Norm = $norm; Bigrams = (Get-Bigrams $norm); Code = $code })
      }
      if ($isDir) { & $collect $item.FullName ($level + 1) }
    }
  }
  # 外付けドライブのつなぎ忘れなどで1つ見つからなくても、残りは調べる
  $script:MissingGameDirs = @($Dirs | Where-Object { -not (Test-Path -LiteralPath $_) })
  if ($Dirs.Count -gt 0 -and $script:MissingGameDirs.Count -eq $Dirs.Count) {
    throw "ゲームフォルダが1つも見つかりません:`n" + ($script:MissingGameDirs -join "`n")
  }
  foreach ($d in $Dirs) {
    if (Test-Path -LiteralPath $d) { & $collect $d 1 }
  }
  return ,$cands
}

# ---------- 3. 照らし合わせ ----------

# Status: owned（持っている）/ maybe（たぶん）/ notowned（持っていない）
# $Links: Read-OwnedLinks の戻り値。自分で確かめた対応を先に使う
#   Same[RJ番号] = 手元のパス … その候補で「持っている」（候補の中にそのパスがあるときだけ）
#   Diff[RJ番号] = パスの一覧 … その候補は「別の作品」なので、似ていても選ばない
function Compare-Owned($Wishlist, $Candidates, [double]$Threshold = 0.6, $Links = $null) {
  # 候補を配列にしておき、作品ごとの比較は C#（OwnedMatch2）に任せる
  # @($Candidates) は New-Object で作った List だと「引数の型が一致しません」になるので、パイプラインで配列にする
  $cl = @($Candidates | ForEach-Object { $_ })
  $norms = [string[]]::new($cl.Count)
  $bgs = [System.Collections.Generic.HashSet[string][]]::new($cl.Count)
  $byCode = @{}
  $byPath = @{}
  for ($i = 0; $i -lt $cl.Count; $i++) {
    $norms[$i] = [string]$cl[$i].Norm
    $bgs[$i] = $cl[$i].Bigrams
    if ($cl[$i].Code -and -not $byCode.ContainsKey($cl[$i].Code)) { $byCode[$cl[$i].Code] = $cl[$i] }
    $byPath[[string]$cl[$i].Path] = $i
  }
  foreach ($w in $Wishlist) {
    $best = $null; $bestScore = 0.0; $how = ''; $confirmed = $false
    $samePath = if ($Links -and $w.Code) { $Links.Same[$w.Code] } else { $null }
    if ($samePath -and $byPath.ContainsKey($samePath)) {
      $best = $cl[$byPath[$samePath]]; $bestScore = 1.0; $how = '確かめた対応'; $confirmed = $true
    } elseif ($w.Code -and $byCode.ContainsKey($w.Code)) {
      $best = $byCode[$w.Code]; $bestScore = 1.0; $how = 'RJ番号が一致'
    } else {
      $skip = $null
      if ($Links -and $w.Code -and $Links.Diff[$w.Code]) {
        $skip = New-Object 'System.Collections.Generic.HashSet[int]'
        foreach ($p in @($Links.Diff[$w.Code])) { if ($byPath.ContainsKey([string]$p)) { [void]$skip.Add($byPath[[string]$p]) } }
      }
      $wn = Normalize-Title $w.Title
      # 片方がもう片方を含む（短い方が4文字以上）なら 0.85：「たぶん持っている」に入るよう、判定の厳しさの上限 0.95 より下にしてある
      $m = [OwnedMatch2]::Best($wn, (Get-Bigrams $wn), $norms, $bgs, 4, 0.85, $skip)
      if ($m[0] -ge 0) {
        $best = $cl[[int]$m[0]]; $bestScore = $m[1]
        $how = if ($m[2]) { '作品名が一致' } else { '作品名が似ている' }
      }
    }
    # 「持っている」は RJ番号か作品名の完全一致（1.0）だけ。0.999 なのは小数の誤差よけ。似ているだけなら「たぶん」止まり
    $status = if ($bestScore -ge 0.999) { 'owned' } elseif ($bestScore -ge $Threshold) { 'maybe' } else { 'notowned' }
    [pscustomobject]@{
      Code = $w.Code; Url = $w.Url; Title = $(if ($w.Title) { $w.Title } else { '(タイトル不明)' })
      Status = $status; Score = [Math]::Round($bestScore, 2); How = $how; Confirmed = $confirmed
      Match = $(if ($best -and $status -ne 'notowned') { $best.Name } else { '' })
      MatchPath = $(if ($best -and $status -ne 'notowned') { $best.Path } else { '' })
      # 「持っていない」でも 0.4 以上なら参考に「いちばん近い」を出す（判定の厳しさを下げるかの目安。最小 0.3 より少し上）
      NearName = $(if ($best -and $status -eq 'notowned' -and $bestScore -ge 0.4) { $best.Name } else { '' })
      NearPath = $(if ($best -and $status -eq 'notowned' -and $bestScore -ge 0.4) { $best.Path } else { '' })
    }
  }
}

# ---------- 3b. 確かめた対応（owned-links.json） ----------

# 「たぶん持っている」を自分で確かめた結果。ファイルの形: { "same": { "RJ…": "手元のパス" }, "diff": { "RJ…": ["パス", …] } }
# 戻り値: @{ Same = @{ RJ番号 = パス }; Diff = @{ RJ番号 = @(パス…) } }
function Read-OwnedLinks([string]$Path) {
  $links = @{ Same = @{}; Diff = @{} }
  if (-not (Test-Path -LiteralPath $Path)) { return $links }
  $o = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($o.same) { foreach ($p in $o.same.PSObject.Properties) { $links.Same[$p.Name] = [string]$p.Value } }
  if ($o.diff) { foreach ($p in $o.diff.PSObject.Properties) { $links.Diff[$p.Name] = @($p.Value | ForEach-Object { [string]$_ }) } }
  return $links
}

function Save-OwnedLinks([string]$Path, $Links) {
  $same = [ordered]@{}; foreach ($k in @($Links.Same.Keys | Sort-Object)) { $same[$k] = $Links.Same[$k] }
  $diff = [ordered]@{}; foreach ($k in @($Links.Diff.Keys | Sort-Object)) { if (@($Links.Diff[$k]).Count) { $diff[$k] = @($Links.Diff[$k]) } }
  $json = [ordered]@{ same = $same; diff = $diff } | ConvertTo-Json -Depth 5
  [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

# 作品（RJ番号）と手元のパスの対応を覚える。$Same なら「同じ作品」、そうでなければ「別の作品」
function Set-OwnedLink($Links, [string]$Code, [string]$MatchPath, [bool]$Same) {
  if ($Same) {
    $Links.Same[$Code] = $MatchPath
    if ($Links.Diff[$Code]) { $Links.Diff[$Code] = @($Links.Diff[$Code] | Where-Object { $_ -ne $MatchPath }) }
  } else {
    if ($Links.Same[$Code] -eq $MatchPath) { $Links.Same.Remove($Code) }
    $Links.Diff[$Code] = @(@($Links.Diff[$Code]) + $MatchPath | Where-Object { $_ } | Select-Object -Unique)
  }
}

function Clear-OwnedLink($Links, [string]$Code) {
  $Links.Same.Remove($Code); $Links.Diff.Remove($Code)
}

# ---------- 3c. 持っている作品の一覧（AS で更新を確かめる用） ----------

# フォルダ名・ファイル名から版を読む（「v1.02」「Ver.1.0.3」「ver23.11.13」など）。なければ空
function Get-FolderVersion([string]$Name) {
  # 前は英数字以外ならよい（\b だと「game_v1.02」の _ のあとを読めない）
  if ($Name -match '(?i)(?:(?<![a-z0-9])ver(?:sion)?\.?\s*|(?<![a-z0-9])v)(\d+(?:[._\-]\d+)*[a-z]?)(?![\w.])') {
    return ($Matches[1] -replace '_', '.')
  }
  return ''
}

# 持っている作品（RJ番号がわかるもの）を集める。
#   ・今の気になるリストと、ブックマークのバックアップ（消したブックマーク＝持っている作品が残っている）を照らし合わせて
#     「持っている」になったもの（RJ番号か作品名の完全一致、または確かめた対応）
#   ・フォルダ名に RJ番号が入っているもの
# 戻り値: Code / Path / Name / Version（フォルダ名から読んだ版）の一覧
function Get-OwnedWorks([string[]]$Sources, [string]$Folder, [string]$BackupDir, $Candidates, [double]$Threshold, $Links) {
  $out = [ordered]@{}
  foreach ($r in @(Compare-Owned @(Get-OwnedWishlist $Sources $Folder $BackupDir) $Candidates $Threshold $Links)) {
    if ($r.Status -eq 'owned') { $out[$r.Code] = [pscustomobject]@{ Code = $r.Code; Path = $r.MatchPath; Name = $r.Match } }
  }
  foreach ($c in @($Candidates | ForEach-Object { $_ })) {
    if ($c.Code -and -not $out.Contains($c.Code)) { $out[$c.Code] = [pscustomobject]@{ Code = $c.Code; Path = $c.Path; Name = $c.Name } }
  }
  foreach ($o in $out.Values) { $o | Add-Member -NotePropertyName Version -NotePropertyValue (Get-FolderVersion $o.Name) }
  return @($out.Values)
}

# 持っている作品を探すための作品の一覧：今の気になるリストと、ブックマークのバックアップ（消したブックマーク＝持っている作品が残っている）
# 同じ RJ番号は1つにまとめる（作品名がわからないものは、ほかで見つかった作品名で埋める）。Read-Wishlist と同じ形
function Get-OwnedWishlist([string[]]$Sources, [string]$Folder, [string]$BackupDir) {
  $wish = [ordered]@{}
  foreach ($w in @(Read-Wishlist $Sources $Folder)) { if (-not $wish.Contains($w.Code)) { $wish[$w.Code] = $w } }
  if ($BackupDir -and (Test-Path -LiteralPath $BackupDir)) {
    $files = @(Get-ChildItem -LiteralPath $BackupDir -Filter 'Bookmarks-*' -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
    if ($files.Count) {
      foreach ($w in @(Read-Wishlist $files '')) {
        if (-not $wish.Contains($w.Code)) { $wish[$w.Code] = $w }
        elseif (-not $wish[$w.Code].Title -and $w.Title) { $wish[$w.Code].Title = $w.Title }
      }
    }
  }
  return @($wish.Values)
}

# ---------- 3d. AS Patch Finder の検索結果（TSV）を読む ----------

# 戻り値: @{ RJ番号 = [pscustomobject]@{ Found; Kind（見つかった/なし/エラー/未検索）; Version; Url; Title; Mark; Cmp; Patch; Count } }
# 列は見出しの名前で探す（AS Patch Finder の版によって列の数が違うため）
function Read-ASResults([string]$Path) {
  $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
  if ($lines.Count -eq 0) { throw 'ファイルが空です。' }
  $head = $lines[0].TrimStart([char]0xFEFF) -split "`t"
  $col = @{}; for ($i = 0; $i -lt $head.Count; $i++) { $col[$head[$i]] = $i }
  foreach ($need in '作品コード', '種類', '最新', 'URL') {
    if (-not $col.ContainsKey($need)) { throw "AS Patch Finder の TSV ではないようです（「$need」の列がありません）。" }
  }
  $get = { param($cells, $name) if ($col.ContainsKey($name) -and $col[$name] -lt $cells.Count) { $cells[$col[$name]] } else { '' } }
  $res = @{}
  foreach ($line in ($lines | Select-Object -Skip 1)) {
    if (-not $line.Trim()) { continue }
    $cells = $line -split "`t"
    $code = (& $get $cells '作品コード').Trim().ToUpperInvariant()
    if (-not $code) { continue }
    $kind = & $get $cells '種類'
    $cur = $res[$code]
    if (-not $cur) {
      $cur = [pscustomobject]@{ Found = $false; Kind = ''; Version = ''; Url = ''; Title = ''; Mark = (& $get $cells '印'); Cmp = ''; Patch = $false; Count = 0 }
      $res[$code] = $cur
    }
    if ($kind -in 'なし', 'エラー', '未検索') { if (-not $cur.Found) { $cur.Kind = $kind }; continue }
    $cur.Found = $true; $cur.Kind = '見つかった'; $cur.Count++
    if ((& $get $cells '最新') -eq '★') {
      $cur.Version = & $get $cells 'バージョン'; $cur.Url = & $get $cells 'URL'; $cur.Title = & $get $cells 'タイトル'
      $cur.Patch = ((& $get $cells 'パッチ/翻訳') -eq '○'); $cur.Cmp = & $get $cells '手元と比べて'
    } elseif (-not $cur.Url) { $cur.Url = & $get $cells 'URL' }
  }
  return $res
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

  $result.Backup = Backup-BookmarksFile $full $BackupDir
  Save-BookmarksJson $full $json
  return $result
}

# Bookmarks ファイルをバックアップのフォルダにコピーし、そのパスを返す。
# 名前は「Bookmarks-<Chrome/Edge/Other または $Tag>-<日時>」
function Backup-BookmarksFile([string]$Path, [string]$BackupDir, [string]$Tag) {
  New-Item -ItemType Directory -Force $BackupDir | Out-Null
  if (-not $Tag) { $Tag = if ($Path -match '\\Microsoft\\Edge\\') { 'Edge' } elseif ($Path -match '\\Google\\Chrome\\') { 'Chrome' } else { 'Other' } }
  $bk = Join-Path $BackupDir ("Bookmarks-{0}-{1}" -f $Tag, (Get-Date -Format 'yyyyMMdd-HHmmss'))
  Copy-Item -LiteralPath $Path -Destination $bk
  return $bk
}

# 書き換えた Bookmarks を保存する。
# checksum は中身が変わると合わなくなるので外す（ブラウザが次回起動時に作り直す）
function Save-BookmarksJson([string]$Path, $Json) {
  $Json.PSObject.Properties.Remove('checksum')
  [IO.File]::WriteAllText($Path, ($Json | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding $false))
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
# 通信に失敗した RJ 番号の数は $script:DLsiteFailedCount に、最後のエラーは $script:DLsiteLastError に入れる
function Get-DLsiteTitles([string[]]$Codes) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $titles = @{}
  $script:DLsiteFailedCount = 0; $script:DLsiteLastError = ''
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
    } catch {
      $script:DLsiteFailedCount += @($chunk).Count
      $script:DLsiteLastError = $_.Exception.Message
    }
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
  # 最大の id は、入れ子の scriptblock から書き換えられるようハッシュテーブルに入れる（呼び出し元の変数を汚さない）
  $ids = @{ Max = [long]0 }
  $scan = {
    param($node, [bool]$inTarget)
    foreach ($c in @($node.children)) {
      $n = 0; if ([long]::TryParse("$($c.id)", [ref]$n) -and $n -gt $ids.Max) { $ids.Max = $n }
      $inside = $inTarget -or ($c.type -eq 'folder' -and "$($c.id)" -eq "$($target.id)")
      if ($inside -and $c.type -eq 'url' -and $c.url -match $script:CodeRe) { [void]$have.Add($Matches[1]) }
      if ($c.type -eq 'folder') { & $scan $c $inside }
    }
  }
  foreach ($r in $json.roots.PSObject.Properties) {
    if ($r.Value -is [pscustomobject]) {
      $n = 0; if ([long]::TryParse("$($r.Value.id)", [ref]$n) -and $n -gt $ids.Max) { $ids.Max = $n }
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
    $ids.Max++
    $name = if ($it.Title -and $it.Title -ne '(タイトル不明)') { $it.Title } else { $it.Code }
    $newNodes.Add([pscustomobject][ordered]@{
      date_added = $now; date_last_used = '0'; guid = [guid]::NewGuid().ToString()
      id = [string]$ids.Max; name = $name; type = 'url'; url = $it.Url
    })
    $added.Add($name)
  }

  $result = @{ Added = $added.ToArray(); Skipped = $skipped; Backup = $null }
  if ($DryRun -or $added.Count -eq 0) { return $result }

  $result.Backup = Backup-BookmarksFile $full $BackupDir
  $target.children = @(@($target.children) + $newNodes.ToArray() | Where-Object { $null -ne $_ })
  Save-BookmarksJson $full $json
  return $result
}

# ---------- 7. フォルダの中のサブフォルダへ移す ----------

# $Folder（道順）の中にある、$Codes の作品のブックマークを、その中のサブフォルダ $SubName へ移す（なければ作る）。
# すでに $SubName の中にあるものはそのまま。DLsite 以外のブックマークやフォルダには触れない。
# 戻り値: @{ Moved = 移したブックマーク名の一覧; Created = サブフォルダを作ったか; Backup }
function Move-BookmarksToSubfolder([string]$Path, [string]$Folder, [string]$SubName, [string[]]$Codes, [string]$BackupDir, [switch]$DryRun) {
  if (-not $SubName.Trim()) { throw '移す先のフォルダ名が空です。' }
  $codeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($c in $Codes) { [void]$codeSet.Add($c) }
  $full = (Resolve-Path -LiteralPath $Path).Path
  $json = Get-Content -LiteralPath $full -Raw -Encoding UTF8 | ConvertFrom-Json
  $target = @(Get-BookmarkFolderNodes $json $Folder) | Select-Object -First 1
  if (-not $target) { throw "ブックマークのフォルダが見つかりません: $Folder" }

  # 移す先のサブフォルダ（$Folder の直下）。なければ作る
  $sub = @($target.children) | Where-Object { $_.type -eq 'folder' -and $_.name -eq $SubName } | Select-Object -First 1
  $created = $false
  if (-not $sub) {
    $ids = @{ Max = [long]0 }
    $scanId = {
      param($node)
      $n = 0; if ([long]::TryParse("$($node.id)", [ref]$n) -and $n -gt $ids.Max) { $ids.Max = $n }
      foreach ($c in @($node.children)) { if ($c) { & $scanId $c } }
    }
    foreach ($r in $json.roots.PSObject.Properties) { if ($r.Value -is [pscustomobject]) { & $scanId $r.Value } }
    $now = Get-ChromeTime
    $sub = [pscustomobject][ordered]@{
      children = @(); date_added = $now; date_last_used = '0'; date_modified = $now
      guid = [guid]::NewGuid().ToString(); id = [string]($ids.Max + 1); name = $SubName; type = 'folder'
    }
    $created = $true
  }

  # $Folder の中（$SubName の中は除く）から、対象の作品のブックマークを抜き出す
  $moved = New-Object System.Collections.Generic.List[object]
  $have = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($c in @($sub.children)) { if ($c -and $c.type -eq 'url' -and $c.url -match $script:CodeRe) { [void]$have.Add($Matches[1]) } }
  $pull = {
    param($node)
    if ($null -eq $node.children) { return }
    $keep = New-Object System.Collections.Generic.List[object]
    foreach ($c in $node.children) {
      if ($c.type -eq 'url' -and $c.url -match 'dlsite\.com' -and $c.url -match $script:CodeRe -and $codeSet.Contains($Matches[1])) {
        # サブフォルダにもうある作品（同じ作品のブックマークが2つある）は、移さずにそのまま残す
        if (-not $have.Contains($Matches[1])) { [void]$have.Add($Matches[1]); $moved.Add($c); continue }
      }
      if ($c.type -eq 'folder' -and -not [object]::ReferenceEquals($c, $sub)) { & $pull $c }
      $keep.Add($c)
    }
    $node.children = $keep.ToArray()
  }
  & $pull $target

  $result = @{ Moved = @($moved | ForEach-Object { "$($_.name)" }); Created = $created; Backup = $null }
  if ($DryRun -or $moved.Count -eq 0) { return $result }

  $sub.children = @(@($sub.children) + $moved.ToArray() | Where-Object { $null -ne $_ })
  if ($created) { $target.children = @(@($target.children) + $sub | Where-Object { $null -ne $_ }) }
  $result.Backup = Backup-BookmarksFile $full $BackupDir
  Save-BookmarksJson $full $json
  return $result
}
