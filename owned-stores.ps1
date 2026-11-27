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
