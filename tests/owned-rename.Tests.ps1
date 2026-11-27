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
