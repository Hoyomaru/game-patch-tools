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
