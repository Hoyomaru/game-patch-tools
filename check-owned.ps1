<#
  check-owned.ps1  —  所持チェックのコマンド版（普段は GUI 版「所持チェック.bat」を使ってください）

  気になるリストとゲームフォルダを照らし合わせて「もう持っているか」を判定します。
  すべてこのPCの中だけで処理します。ネットにアクセスするのは「URL をまとめて追加」で作品名を DLsite から取るときだけです（送るのは RJ 番号だけ）。

  使い方（例）:
    .\check-owned.ps1 -Export "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Bookmarks" -GameDirs "E:\Games"

  オプション:
    -Export     DLsite の URL が入ったファイル（複数可）。Session Buddy のエクスポート、
                Chrome / Edge の Bookmarks ファイル、ブックマークの HTML、URL を書いたテキスト
    -GameDirs   ゲームを置いているフォルダ（複数可）
    -Depth      何階層下までのフォルダ名を見るか（既定 2）
    -Threshold  「たぶん持っている」と判定する似かたの基準 0〜1（既定 0.6）
    -Out        結果レポートの保存先（既定: owned-report.html）
    -NoOpen     レポートを自動で開かない
    -Prune      Bookmarks ファイルから「持っている」作品を削除（ブラウザ終了中のみ・バックアップあり）
    -SkipMaybe  「たぶん持っている」は確認せず残す
    -DryRun     実際には消さず、消す予定のものを表示するだけ
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string[]]$Export,
  [Parameter(Mandatory)][string[]]$GameDirs,
  [int]$Depth = 2,
  [double]$Threshold = 0.6,
  [string]$Out = (Join-Path $PSScriptRoot 'owned-report.html'),
  [switch]$NoOpen,
  [switch]$Prune,
  [switch]$SkipMaybe,
  [switch]$DryRun,
  [switch]$SkipBrowserCheck,  # テスト用。通常は使わないでください
  [string]$BookmarkFolder     # 例: "ブックマーク バー / DLsite気になる"。指定するとそのフォルダの中だけ読む・消す
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'owned-core.ps1')

$wish = @(Read-Wishlist $Export $BookmarkFolder)
if ($wish.Count -eq 0) { Write-Warning 'DLsite の作品URL（RJ番号入り）が見つかりませんでした。'; return }
$cands = Get-GameCandidates $GameDirs $Depth
foreach ($d in @($script:MissingGameDirs)) { Write-Warning "ゲームフォルダが見つからないので飛ばしました: $d" }
Write-Host ("気になるリスト: {0} 作品 ／ ゲームフォルダ内の候補: {1} 件" -f $wish.Count, $cands.Count)

$results = @(Compare-Owned $wish $cands $Threshold)
Write-OwnedReport $results $wish.Count $cands.Count $Threshold $Out

$o = @($results | Where-Object Status -eq 'owned').Count
$mb = @($results | Where-Object Status -eq 'maybe').Count
$no = @($results | Where-Object Status -eq 'notowned').Count
Write-Host "持っている: $o ／ たぶん持っている: $mb ／ 持っていない: $no"
Write-Host "レポート: $Out"
if (-not $NoOpen) { Start-Process $Out }

if (-not $Prune) { return }

$bmFiles = @($Export | Where-Object { Test-BookmarksFile $_ })
if ($bmFiles.Count -eq 0) { Write-Warning '-Prune: Chrome / Edge の Bookmarks ファイルが指定されていないので、何も削除しません。'; return }

$codes = New-Object System.Collections.Generic.List[string]
$results | Where-Object Status -eq 'owned' | ForEach-Object { $codes.Add($_.Code) }
$maybeRows = @($results | Where-Object Status -eq 'maybe' | Sort-Object Score -Descending)
if ($maybeRows.Count -gt 0 -and -not $SkipMaybe) {
  Write-Host "`n「たぶん持っている」が $($maybeRows.Count) 件あります。消すものだけ y を押してください（Enter だけなら残す）。"
  foreach ($r in $maybeRows) {
    Write-Host "`n  気になるリスト: $($r.Title)  ($($r.Code))"
    Write-Host "  手元の候補    : $($r.Match)  （似かた $($r.Score)）"
    if ((Read-Host '  このブックマークを消しますか？ [y/N]') -match '^(y|yes|はい)$') { $codes.Add($r.Code) }
  }
}
if ($codes.Count -eq 0) { Write-Host '消すブックマークはありません。'; return }

foreach ($bf in $bmFiles) {
  if (-not $SkipBrowserCheck) {
    $running = @(Get-RunningBrowser $bf)
    if ($running.Count -gt 0) {
      Write-Warning "ブラウザ（$($running -join ' / ')）が起動中なので、$bf は削除しませんでした。ブラウザを完全に終了してから、もう一度実行してください。"
      continue
    }
  }
  $r = Remove-BookmarksByCode $bf $codes.ToArray() (Join-Path $PSScriptRoot 'bookmark-backups') -DryRun:$DryRun -Folder $BookmarkFolder
  if ($r.Removed.Count -eq 0) { Write-Host "$bf : 消すブックマークはありませんでした。"; continue }
  Write-Host "`n$bf から $($r.Removed.Count) 件$(if ($DryRun) { 'を消す予定です（-DryRun なので実際には消していません）' } else { 'を消しました' }):"
  $r.Removed | ForEach-Object { Write-Host "  - $_" }
  if ($r.Backup) { Write-Host "バックアップ: $($r.Backup)" }
}
