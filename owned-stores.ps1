# 所持チェック：DLsite 以外のお店（Steam・FANZA）と、自分で入れた作品名の扱い（画面なし）
# owned-core.ps1・owned-identify.ps1 のあと、owned-rename.ps1 の前に dot-source する
#
# 名前を変える対象の Code には、次のどれかを入れる
#   RJ01234567              DLsite
#   Steam 1234560           Steam（appid）
#   FANZA d_123456          FANZA（作品の番号）
#   Manual:<お店>:<作品名>  自分で入れた作品名（お店は空でもよい）

# ---------- 1. 番号の読み取り ----------

# 貼られた URL や文字から Code を読む。RJ番号を最初に見る。読めなければ ''
function ConvertTo-StoreCode([string]$Text) {
  if (-not $Text) { return '' }
  if ($Text -match $script:CodeRe) { return $Matches[1].ToUpperInvariant() }
  if ($Text -match '(?i)store\.steampowered\.com/app/(\d+)') { return "Steam $($Matches[1])" }
  if ($Text -match '(?i)^\s*steam\s*(\d+)\s*$') { return "Steam $($Matches[1])" }
  if ($Text -match '(?i)dlsoft\.dmm\.co\.jp/detail/([a-z0-9_]+)') { return "FANZA $($Matches[1].ToLowerInvariant())" }
  if ($Text -match '(?i)dmm\.co\.jp/.*[/?&]cid=([a-z0-9_]+)') { return "FANZA $($Matches[1].ToLowerInvariant())" }
  if ($Text -match '(?i)^\s*(d_\d+)\s*$') { return "FANZA $($Matches[1].ToLowerInvariant())" }
  return ''
}

function New-ManualCode([string]$Store, [string]$Title) {
  return "Manual:$($Store.Trim()):$($Title.Trim())"
}

# 名前の頭に付けるもの。自分で入れたものはお店の名前（空もあり）
function Get-CodePrefix([string]$Code) {
  if ($Code -match '^Manual:([^:]*):') { return $Matches[1] }
  return $Code
}

function Get-ManualTitle([string]$Code) {
  if ($Code -match '^Manual:[^:]*:(.*)$') { return $Matches[1] }
  return ''
}

# 作品のページの URL。自分で入れたものは ''
function Get-StorePageUrl([string]$Code) {
  if ($Code -match '^(?:RJ|VJ|BJ|RE)\d+$') { return "https://www.dlsite.com/maniax/work/=/product_id/$Code.html" }
  if ($Code -match '^Steam (\d+)$') { return "https://store.steampowered.com/app/$($Matches[1])/" }
  if ($Code -match '^FANZA (d_\d+)$') { return "https://www.dmm.co.jp/dc/doujin/-/detail/=/cid=$($Matches[1])/" }
  if ($Code -match '^FANZA ([a-z0-9_]+)$') { return "https://dlsoft.dmm.co.jp/detail/$($Matches[1])/" }
  return ''
}

# ---------- 2. 正式な作品名を取る（送るのは番号だけ） ----------

# Steam の appdetails の返事から作品名。success が偽・形が違えば ''
function ConvertFrom-SteamAppDetails([string]$Json, [string]$AppId) {
  try {
    $o = ($Json | ConvertFrom-Json).$AppId
    if ($o -and $o.success -and $o.data.name) { return ([string]$o.data.name).Trim() }
  } catch { }
  return ''
}

# FANZA の作品ページの作品名。見出し（h1）を使い、なければ og:title（長いと途中で切れる）。どちらもなければ ''（年齢確認のページなど）
function ConvertFrom-FanzaPage([string]$Html) {
  $m = [regex]::Match($Html, '<h1[^>]*>(.*?)</h1>', 'Singleline')
  if ($m.Success) {
    $t = [System.Web.HttpUtility]::HtmlDecode(($m.Groups[1].Value -replace '<[^>]+>', '' -replace '\s+', ' ')).Trim()
    if ($t) { return $t }
  }
  if ($Html -match '<meta\s+property="og:title"\s+content="([^"]*)"') { return [System.Web.HttpUtility]::HtmlDecode($Matches[1]).Trim() }
  return ''
}

# URL の本文を UTF-8 で取る。取れなければ $null。$Session を渡すと cookie を付ける
function Get-WebTextUtf8([string]$Url, $Session = $null) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  try {
    $p = @{ Uri = $Url; UseBasicParsing = $true; UserAgent = 'Mozilla/5.0'; TimeoutSec = 10 }
    if ($Session) { $p.WebSession = $Session }
    $res = Invoke-WebRequest @p
    $ms = New-Object IO.MemoryStream
    $res.RawContentStream.Position = 0; $res.RawContentStream.CopyTo($ms)
    return [Text.Encoding]::UTF8.GetString($ms.ToArray())
  } catch { return $null }
}

# Code ごとの正式な作品名（Code → 作品名）。取れなかった数を $script:StoreFailedCount に入れる
#   RJ はまとめて DLsite、Steam・FANZA は1件ずつ（間は 800 ミリ秒）、自分で入れたものはネットに出ない
function Get-StoreTitles([string[]]$Codes) {
  $titles = @{}
  $script:StoreFailedCount = 0
  $list = @($Codes | Where-Object { $_ } | Select-Object -Unique)
  $rj = @($list | Where-Object { $_ -match '^(?:RJ|VJ|BJ|RE)\d+$' })
  if ($rj.Count) {
    $got = Get-DLsiteTitles $rj
    foreach ($k in $got.Keys) { $titles[$k] = $got[$k] }
    $script:StoreFailedCount += [int]$script:DLsiteFailedCount
  }
  $session = $null
  $first = $true
  foreach ($c in $list) {
    if ($c -match '^Manual:') { $titles[$c] = Get-ManualTitle $c; continue }
    if ($c -notmatch '^(Steam|FANZA) ') { continue }
    if (-not $first) { Start-Sleep -Milliseconds 800 }
    $first = $false
    $t = ''
    if ($c -match '^Steam (\d+)$') {
      $id = $Matches[1]
      $body = Get-WebTextUtf8 "https://store.steampowered.com/api/appdetails?appids=$id&l=japanese"
      if ($body) { $t = ConvertFrom-SteamAppDetails $body $id }
    } else {
      if (-not $session) {
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $session.Cookies.Add((New-Object Net.Cookie('age_check_done', '1', '/', '.dmm.co.jp')))
      }
      $body = Get-WebTextUtf8 (Get-StorePageUrl $c) $session
      if ($body) { $t = ConvertFrom-FanzaPage $body }
    }
    if ($t) { $titles[$c] = $t } else { $script:StoreFailedCount++ }
  }
  return $titles
}
