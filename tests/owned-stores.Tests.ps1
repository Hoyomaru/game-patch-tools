# 所持チェックの「DLsite 以外のお店」の処理（画面なし）のテスト。
# 実行: powershell.exe -NoProfile -Command "Invoke-Pester -Script tests/owned-stores.Tests.ps1 -EnableExit"
# 作品名・番号はすべて架空のものです。Pester 3.4 で動きます。

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'owned-core.ps1')
. (Join-Path $root 'owned-identify.ps1')
. (Join-Path $root 'owned-stores.ps1')
. (Join-Path $root 'owned-rename.ps1')

Describe 'ConvertTo-StoreCode' {
  It 'Steam の URL（作品名・?l= 付き）' { ConvertTo-StoreCode 'https://store.steampowered.com/app/1234560/Kakuu_Game/?l=japanese' | Should Be 'Steam 1234560' }
  It 'steam と番号' { ConvertTo-StoreCode 'steam 1234560' | Should Be 'Steam 1234560' }
  It 'FANZA 同人の URL' { ConvertTo-StoreCode 'https://www.dmm.co.jp/dc/doujin/-/detail/=/cid=d_123456/' | Should Be 'FANZA d_123456' }
  It 'FANZA GAMES の URL' { ConvertTo-StoreCode 'https://dlsoft.dmm.co.jp/detail/kakuu_0001/' | Should Be 'FANZA kakuu_0001' }
  It 'd_ の番号だけ（小文字にそろえる）' { ConvertTo-StoreCode 'D_123456' | Should Be 'FANZA d_123456' }
  It 'DLsite の URL は RJ番号' { ConvertTo-StoreCode 'https://www.dlsite.com/maniax/work/=/product_id/RJ01234567.html' | Should Be 'RJ01234567' }
  It 'RJ番号を含むものは RJ番号を先に見る' { ConvertTo-StoreCode 'https://store.steampowered.com/app/1234560/?x=RJ01234567' | Should Be 'RJ01234567' }
  It 'どれでもなければ空' { ConvertTo-StoreCode 'https://example.com/app/123' | Should Be '' }
}

Describe '自分で入れた名前の Code' {
  It 'お店と作品名を前後の空白を取って入れる' {
    $c = New-ManualCode ' BOOTH ' ' かくう '
    Get-CodePrefix $c | Should Be 'BOOTH'
    Get-ManualTitle $c | Should Be 'かくう'
  }
  It 'お店が空なら頭も空' { Get-CodePrefix (New-ManualCode '' 'かくう') | Should Be '' }
  It 'RJ・Steam・FANZA は Code そのものが頭' {
    Get-CodePrefix 'RJ01234567' | Should Be 'RJ01234567'
    Get-CodePrefix 'Steam 1234560' | Should Be 'Steam 1234560'
    Get-CodePrefix 'FANZA d_123456' | Should Be 'FANZA d_123456'
    Get-ManualTitle 'Steam 1234560' | Should Be ''
  }
}

Describe 'Get-StorePageUrl' {
  It 'DLsite' { Get-StorePageUrl 'RJ01234567' | Should Be 'https://www.dlsite.com/maniax/work/=/product_id/RJ01234567.html' }
  It 'Steam' { Get-StorePageUrl 'Steam 1234560' | Should Be 'https://store.steampowered.com/app/1234560/' }
  It 'FANZA 同人' { Get-StorePageUrl 'FANZA d_123456' | Should Be 'https://www.dmm.co.jp/dc/doujin/-/detail/=/cid=d_123456/' }
  It 'FANZA GAMES' { Get-StorePageUrl 'FANZA kakuu_0001' | Should Be 'https://dlsoft.dmm.co.jp/detail/kakuu_0001/' }
  It '自分で入れたものは空' { Get-StorePageUrl (New-ManualCode 'BOOTH' 'かくう') | Should Be '' }
}
