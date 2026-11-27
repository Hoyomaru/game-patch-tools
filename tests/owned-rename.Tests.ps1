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

Describe 'Update-LinkPaths' {
  $links = New-TestLinks
  $links.Same['RJ00000001'] = 'E:\G\架空'
  $links.Same['RJ00000002'] = 'E:\G\架空\中'
  $links.Same['RJ00000003'] = 'E:\G\架空2'
  $links.Diff['RJ00000004'] = @('E:\G\べつ', 'e:\g\架空')
  Update-LinkPaths $links 'E:\G\架空' 'E:\G\RJ00000001 架空'
  It 'same のパスを書き換える' { $links.Same['RJ00000001'] | Should Be 'E:\G\RJ00000001 架空' }
  It '下にあるパスも書き換える' { $links.Same['RJ00000002'] | Should Be 'E:\G\RJ00000001 架空\中' }
  It 'diff の要素も大文字小文字を区別せずに書き換える' { $links.Diff['RJ00000004'][1] | Should Be 'E:\G\RJ00000001 架空' }
  It '名前の先頭が同じだけの別フォルダは書き換えない' { $links.Same['RJ00000003'] | Should Be 'E:\G\架空2' }
}

Describe 'Invoke-FolderRename / Undo-FolderRename' {
  $g = Join-Path $TestDrive 'rn'
  $logDir = Join-Path $TestDrive 'logs'
  $linksPath = Join-Path $TestDrive 'owned-links.json'
  $mk = { param($code, $old, $new) [pscustomobject]@{ Code = $code; Path = (Join-Path $g $old); OldName = $old; IsArchive = $false; How = '作品名が一致'; State = 'ok'; NewName = $new; NewPath = (Join-Path $g $new) } }

  It '名前を変えて記録に done を付け、owned-links.json も新しいパスになる' {
    New-TestDirs $g @('あ')
    $links = New-TestLinks; $links.Same['RJ00000031'] = (Join-Path $g 'あ')
    $r = Invoke-FolderRename @(& $mk 'RJ00000031' 'あ' 'RJ00000031 あ') $logDir $links $linksPath
    $r.Done | Should Be 1
    Test-Path -LiteralPath (Join-Path $g 'RJ00000031 あ') | Should Be $true
    (Get-Content -LiteralPath $r.Log -Raw -Encoding UTF8 | ConvertFrom-Json).entries[0].done | Should Be $true
    (Read-OwnedLinks $linksPath).Same['RJ00000031'] | Should Be (Join-Path $g 'RJ00000031 あ')
    $script:log1 = $r.Log
  }
  It '戻すと元の名前とリンクに戻る' {
    $links = Read-OwnedLinks $linksPath
    $u = Undo-FolderRename $script:log1 $links $linksPath
    $u.Done | Should Be 1
    Test-Path -LiteralPath (Join-Path $g 'あ') | Should Be $true
    (Read-OwnedLinks $linksPath).Same['RJ00000031'] | Should Be (Join-Path $g 'あ')
  }
  It 'ok 以外は変えない' {
    New-TestDirs $g @('え')
    $t = & $mk 'RJ00000035' 'え' 'RJ00000035 え'; $t.State = 'skip'
    (Invoke-FolderRename @($t) $logDir (New-TestLinks) $linksPath).Done | Should Be 0
    Test-Path -LiteralPath (Join-Path $g 'え') | Should Be $true
  }
  It '1件失敗しても残りは変える' {
    New-TestDirs $g @('い', 'う')
    $lockFile = Join-Path $g 'い\lock.txt'
    [IO.File]::WriteAllText($lockFile, 'x')
    $fs = [IO.File]::Open($lockFile, 'Open', 'Read', 'None')
    try {
      $r = Invoke-FolderRename @((& $mk 'RJ00000032' 'い' 'RJ00000032 い'), (& $mk 'RJ00000033' 'う' 'RJ00000033 う')) $logDir (New-TestLinks) $linksPath
    } finally { $fs.Close() }
    $r.Done | Should Be 1
    @($r.Failed).Count | Should Be 1
    $r.Failed[0].OldName | Should Be 'い'
    $e = (Get-Content -LiteralPath $r.Log -Raw -Encoding UTF8 | ConvertFrom-Json).entries
    @($e | Where-Object done).Count | Should Be 1
    $script:log2 = $r.Log
  }
  It '戻すとき元の名前がもうあれば飛ばす' {
    New-TestDirs $g @('う')   # 元の名前のものを作っておく
    $u = Undo-FolderRename $script:log2 (New-TestLinks) $linksPath
    $u.Done | Should Be 0
    @($u.Skipped).Count | Should Be 1
  }
  It '戻すとき新しい名前のものがなければ飛ばす' {
    New-TestDirs $g @('お')
    $r = Invoke-FolderRename @(& $mk 'RJ00000036' 'お' 'RJ00000036 お') $logDir (New-TestLinks) $linksPath
    Rename-Item -LiteralPath (Join-Path $g 'RJ00000036 お') -NewName 'てうごかし'
    $u = Undo-FolderRename $r.Log (New-TestLinks) $linksPath
    $u.Done | Should Be 0
    @($u.Skipped).Count | Should Be 1
  }
}
