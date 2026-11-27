# 所持チェックの「フォルダ名をそろえる」処理（画面を触らない部分）のテスト。
# 実行: powershell.exe -NoProfile -Command "Invoke-Pester -Script tests/owned-rename.Tests.ps1 -EnableExit"
# 作品名はすべて架空のものです。Pester 3.4（Windows に最初から入っているもの）で動きます。

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'owned-core.ps1')
. (Join-Path $root 'owned-rename.ps1')

Describe 'Get-FolderVersion' {
  It '「_」のあとの v も読む' { Get-FolderVersion 'game_v1.02' | Should Be '1.02' }
  It 'Ver.日付も読む' { Get-FolderVersion 'ゲーム Ver.23.11.13' | Should Be '23.11.13' }
  It '単語の途中の ver は読まない' { Get-FolderVersion 'Never1.0' | Should Be '' }
}

Describe 'ConvertTo-SafeFileName' {
  It '使えない文字を全角にする' { ConvertTo-SafeFileName 'A:B/C?D*E"F<G>H|I\J' | Should Be 'A：B／C？D＊E＂F＜G＞H｜I＼J' }
  It '改行・タブは空白1つにまとめる' { ConvertTo-SafeFileName "A`t`r`nB  C" | Should Be 'A B C' }
  It '末尾の点と空白を取る' { ConvertTo-SafeFileName 'ゲーム名. . ' | Should Be 'ゲーム名' }
}

function New-TestDirs([string]$base, [string[]]$rel) {
  foreach ($r in $rel) { New-Item -ItemType Directory -Force -Path (Join-Path $base $r) | Out-Null }
}
function W([string]$code, [string]$title) { [pscustomobject]@{ Code = $code; Title = $title; Url = "https://www.dlsite.com/maniax/work/=/product_id/$code.html" } }
function New-TestLinks { @{ Same = @{}; Diff = @{} } }

Describe 'Get-RenameTargets' {
  $games = Join-Path $TestDrive 'games'
  New-TestDirs $games @('かくうのげーむ', 'RJ09999999 べつのさくひん', 'にじゅう\にじゅう', 'セット', 'かくうのぼうけん')
  $cands = Get-GameCandidates @($games) 2
  $wish = @(
    (W 'RJ00000001' 'かくうのげーむ'),
    (W 'RJ09999999' 'べつのさくひん'),
    (W 'RJ00000003' 'にじゅう'),
    (W 'RJ00000041' 'セット'),
    (W 'RJ00000042' 'セット'),
    (W 'RJ00000005' 'かくうのぼうけん2')
  )
  $links = New-TestLinks
  # 確かめた対応が内側を指していても、外側を変える
  $links.Same['RJ00000003'] = (Join-Path $games 'にじゅう\にじゅう')
  $t = @(Get-RenameTargets $wish $cands 0.6 $links @($games))

  It '作品名が完全一致した候補を対象にする' { ($t | Where-Object Code -eq 'RJ00000001').Path | Should Be (Join-Path $games 'かくうのげーむ') }
  It '決め手を残す' { ($t | Where-Object Code -eq 'RJ00000001').How | Should Be '作品名が一致' }
  It 'すでにRJ番号が入っている候補は対象にしない' { @($t | Where-Object { $_.Path -like '*RJ09999999*' }).Count | Should Be 0 }
  It '2つの作品が同じ候補に当たったら multi にする' { @($t | Where-Object State -eq 'multi').Count | Should Be 2 }
  It '作品\作品 は外側を対象にする' { ($t | Where-Object Code -eq 'RJ00000003').Path | Should Be (Join-Path $games 'にじゅう') }
  It '「たぶん」は対象にしない' { @($t | Where-Object Code -eq 'RJ00000005').Count | Should Be 0 }
  It '作品名を入れる前は pending' { ($t | Where-Object Code -eq 'RJ00000001').State | Should Be 'pending' }

  It 'ゲームフォルダそのものは対象にしない' {
    $g2 = Join-Path $TestDrive 'games2'
    New-TestDirs $g2 @('さくひん\さくひん')
    $dirs = @($g2, (Join-Path $g2 'さくひん'))
    $c2 = Get-GameCandidates $dirs 2
    @(Get-RenameTargets @(W 'RJ00000006' 'さくひん') $c2 0.6 (New-TestLinks) $dirs | Where-Object { $_.Path -eq (Join-Path $g2 'さくひん') }).Count | Should Be 0
  }
}

Describe 'Get-OwnedWishlist / Get-OwnedWorks' {
  $g = Join-Path $TestDrive 'ow'
  New-TestDirs $g @('games\かくうのげーむ v1.1', 'games\RJ00000022 ふぉるだ', 'bk')
  $now = Join-Path $g 'now.txt'
  [IO.File]::WriteAllText($now, "https://www.dlsite.com/maniax/work/=/product_id/RJ00000021.html`n")
  # バックアップは消したブックマーク。Read-Wishlist はテキストも読めるので URL を書いたファイルで代わりにする
  [IO.File]::WriteAllText((Join-Path $g 'bk\Bookmarks-test.txt'), "https://www.dlsite.com/maniax/work/=/product_id/RJ00000023.html`n")
  It '今のリストとバックアップを1つにまとめる' {
    @(Get-OwnedWishlist @($now) '' (Join-Path $g 'bk') | ForEach-Object Code | Sort-Object) -join ',' | Should Be 'RJ00000021,RJ00000023'
  }
  It 'Get-OwnedWorks はフォルダ名に RJ番号があるものも返す' {
    $c = Get-GameCandidates @(Join-Path $g 'games') 1
    @(Get-OwnedWorks @($now) '' (Join-Path $g 'bk') $c 0.6 (New-TestLinks) | ForEach-Object Code) -contains 'RJ00000022' | Should Be $true
  }
}

Describe 'Set-RenameNames' {
  $g = Join-Path $TestDrive 'names'
  New-TestDirs $g @('a_v1.0', 'b', 'c', 'RJ00000013 すでにある')
  $mk = { param($code, $name) [pscustomobject]@{ Code = $code; Path = (Join-Path $g $name); OldName = $name; IsArchive = $false; How = '作品名が一致'; State = 'pending'; NewName = ''; NewPath = '' } }
  $ts = @((& $mk 'RJ00000011' 'a_v1.0'), (& $mk 'RJ00000012' 'b'), (& $mk 'RJ00000013' 'c'))
  Set-RenameNames $ts @{ 'RJ00000011' = '架空の作品'; 'RJ00000013' = 'すでにある' }

  It '作品名が取れたら ok' { $ts[0].State | Should Be 'ok'; $ts[0].NewName | Should Be 'RJ00000011 架空の作品 v1.0'; $ts[0].NewPath | Should Be (Join-Path $g 'RJ00000011 架空の作品 v1.0') }
  It '作品名が取れなければ notitle' { $ts[1].State | Should Be 'notitle' }
  It '同じ名前がもうあれば exists' { $ts[2].State | Should Be 'exists' }
}

Describe 'New-RenameName' {
  It '版があれば最後に付ける' { New-RenameName 'RJ01234567' '架空の作品' 'kakuu_game_v1.02' $false 'E:\Games' | Should Be 'RJ01234567 架空の作品 v1.02' }
  It '版がなければ付けない' { New-RenameName 'RJ01234567' '架空の作品' 'てきとう' $false 'E:\Games' | Should Be 'RJ01234567 架空の作品' }
  It 'アーカイブは拡張子を残す' { New-RenameName 'RJ01234567' '架空の作品' 'kakuu ver2.0.zip' $true 'E:\Games' | Should Be 'RJ01234567 架空の作品 v2.0.zip' }
  It 'フルパスが240文字を超えるなら作品名を切り詰める' {
    $parent = 'E:\' + ('x' * 200)
    $n = New-RenameName 'RJ01234567' ('あ' * 100) 'old_v1.0' $false $parent
    (Join-Path $parent $n).Length | Should Not BeGreaterThan 240
    $n | Should Match '^RJ01234567 あ+ v1\.0$'
  }
}
