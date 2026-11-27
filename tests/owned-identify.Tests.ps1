# 所持チェックの「ブックマークにない作品の見分け・手がかり・DLsite 検索」（画面を触らない部分）のテスト。
# 実行: powershell.exe -NoProfile -Command "Invoke-Pester -Script tests -EnableExit"
# 作品名はすべて架空のものです。DLsite には問い合わせません。

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'owned-core.ps1')
. (Join-Path $root 'owned-identify.ps1')

function New-TestDirs([string]$base, [string[]]$rel) {
  foreach ($r in $rel) { New-Item -ItemType Directory -Force -Path (Join-Path $base $r) | Out-Null }
}
function New-TestFile([string]$path, [string]$text = 'x', $enc = (New-Object Text.UTF8Encoding $false)) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  [IO.File]::WriteAllText($path, $text, $enc)
}

Describe 'Get-UnknownWorks' {
  $g = Join-Path $TestDrive 'games'
  foreach ($f in 'かくう\Game.exe', 'かくう\www\index.html', 'サークル\あ\Game.exe', 'サークル\い\Game.exe',
                 'つつみ\Game\Game.exe', 'RJ01111111 すでに\Game.exe', 'なにもない\readme.txt', 'のぞく\Game.exe') {
    New-TestFile (Join-Path $g $f)
  }
  New-TestFile (Join-Path $g 'あーかいぶ.zip')
  $cands = Get-GameCandidates @($g) 3
  $paths = @(Get-UnknownWorks $cands @(Join-Path $g 'のぞく') @($g) | ForEach-Object Path)

  It '印のあるフォルダは作品' { $paths -contains (Join-Path $g 'かくう') | Should Be $true }
  It '作品の中のフォルダは外す' { @($paths | Where-Object { $_ -like '*かくう\*' }).Count | Should Be 0 }
  It 'サークルのフォルダは外し、中の作品を出す' {
    $paths -contains (Join-Path $g 'サークル') | Should Be $false
    $paths -contains (Join-Path $g 'サークル\あ') | Should Be $true
    $paths -contains (Join-Path $g 'サークル\い') | Should Be $true
  }
  It '印のある子が1つだけなら外側を作品にする' {
    $paths -contains (Join-Path $g 'つつみ') | Should Be $true
    $paths -contains (Join-Path $g 'つつみ\Game') | Should Be $false
  }
  It 'RJ番号のあるものは外す' { @($paths | Where-Object { $_ -like '*RJ01111111*' }).Count | Should Be 0 }
  It '印のないものは外す' { $paths -contains (Join-Path $g 'なにもない') | Should Be $false }
  It 'アーカイブは作品' { $paths -contains (Join-Path $g 'あーかいぶ.zip') | Should Be $true }
  It 'ExcludePaths の候補は外す' { $paths -contains (Join-Path $g 'のぞく') | Should Be $false }
  It '② のゲームフォルダの親は外す' {
    $g2 = Join-Path $TestDrive 'games2'
    New-TestFile (Join-Path $g2 'おや\こ\Game.exe')
    $c2 = Get-GameCandidates @($g2) 2
    @(Get-UnknownWorks $c2 @() @($g2, (Join-Path $g2 'おや\こ')) | ForEach-Object Path) -contains (Join-Path $g2 'おや') | Should Be $false
  }
}

Describe 'Find-InsideCodes' {
  $g = Join-Path $TestDrive 'inside'
  New-TestFile (Join-Path $g 'a\RJ00000101_manual.pdf')
  New-TestFile (Join-Path $g 'b\readme.txt') 'https://www.dlsite.com/maniax/work/=/product_id/RJ00000102.html'
  New-TestFile (Join-Path $g 'c\RJ00000103.txt') 'rj00000104 も見てね'
  New-TestFile (Join-Path $g 'd\big.txt') ('x' * 300KB + ' RJ00000105')
  It 'ファイル名から見つける' { @(Find-InsideCodes (Join-Path $g 'a')) -join ',' | Should Be 'RJ00000101' }
  It 'テキストの中から見つける' { @(Find-InsideCodes (Join-Path $g 'b')) -join ',' | Should Be 'RJ00000102' }
  It '2つあれば両方返す（大文字にそろえる）' { @(Find-InsideCodes (Join-Path $g 'c')) -join ',' | Should Be 'RJ00000103,RJ00000104' }
  It '大きいファイルは読まない' { @(Find-InsideCodes (Join-Path $g 'd')).Count | Should Be 0 }
  It 'アーカイブなら空' { New-TestFile (Join-Path $g 'x.zip'); @(Find-InsideCodes (Join-Path $g 'x.zip')).Count | Should Be 0 }
}

Describe 'Get-InnerGameTitle' {
  $g = Join-Path $TestDrive 'title'
  New-TestFile (Join-Path $g 'mv\www\data\System.json') '{"gameTitle":"架空のRPG","other":1}'
  New-TestFile (Join-Path $g 'vx\Game.ini') "[Game]`r`nLibrary=RGSS3.dll`r`nTitle=架空のぼうけん`r`n" ([Text.Encoding]::GetEncoding(932))
  New-TestFile (Join-Path $g 'nw\package.json') '{"name":"kakuu","window":{"title":"架空のノベル"}}'
  New-TestFile (Join-Path $g 'nw2\package.json') '{"name":"kakuu-game"}'
  New-TestFile (Join-Path $g 'un\Kakuu_Data\app.info') "Kakuu Circle`nKakuu Adventure"
  New-TestDirs $g @('none')
  It 'ツクールMV/MZ の gameTitle' { Get-InnerGameTitle (Join-Path $g 'mv') | Should Be '架空のRPG' }
  It 'Game.ini の Title（Shift_JIS）' { Get-InnerGameTitle (Join-Path $g 'vx') | Should Be '架空のぼうけん' }
  It 'package.json の window.title' { Get-InnerGameTitle (Join-Path $g 'nw') | Should Be '架空のノベル' }
  It 'package.json の name' { Get-InnerGameTitle (Join-Path $g 'nw2') | Should Be 'kakuu-game' }
  It 'Unity の app.info の2行目' { Get-InnerGameTitle (Join-Path $g 'un') | Should Be 'Kakuu Adventure' }
  It 'なければ空' { Get-InnerGameTitle (Join-Path $g 'none') | Should Be '' }
}

Describe 'New-SearchTerm' {
  It '版と括弧を除く' { New-SearchTerm 'かくうRPG_v1.02 (体験版)' $false | Should Be 'かくうRPG' }
  It 'アーカイブは拡張子を除く' { New-SearchTerm 'かくう ver2.zip' $true | Should Be 'かくう' }
  It '_ や - は空白にして1つにまとめる' { New-SearchTerm 'kakuu__game--x' $false | Should Be 'kakuu game x' }
}
