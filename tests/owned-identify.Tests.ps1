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
