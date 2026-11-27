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
  It '見直し：入っている「FANZA 番号」をそのまま OK しても読める' { ConvertTo-StoreCode 'FANZA d_123456' | Should Be 'FANZA d_123456'; ConvertTo-StoreCode 'fanza Kakuu_0001' | Should Be 'FANZA kakuu_0001' }
  It '見直し：Steam の年齢確認の URL も読む' { ConvertTo-StoreCode 'https://store.steampowered.com/agecheck/app/1234560/' | Should Be 'Steam 1234560' }
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

Describe '作品名の読み取り（保存した見本で）' {
  $steam = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\steam-appdetails-sample.json'), [Text.Encoding]::UTF8)
  $fanza = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\fanza-page-sample.html'), [Text.Encoding]::UTF8)
  It 'Steam の name' { ConvertFrom-SteamAppDetails $steam '1234560' | Should Be '架空のゲーム' }
  It 'Steam の appid が違えば空' { ConvertFrom-SteamAppDetails $steam '7654321' | Should Be '' }
  It 'Steam の success が偽なら空' { ConvertFrom-SteamAppDetails '{"1234560":{"success":false}}' '1234560' | Should Be '' }
  It 'Steam の返事が壊れていれば空' { ConvertFrom-SteamAppDetails 'not json' '1234560' | Should Be '' }
  It 'FANZA は見出し（h1）を使う（og:title は長いと途中で切れるため。中のタグと &amp; を戻す）' { ConvertFrom-FanzaPage $fanza | Should Be '架空の同人ゲーム & 体験 〜長い副題の続き〜' }
  It '見直し：作品名の見出しでない h1（年齢認証など）は使わず og:title' { ConvertFrom-FanzaPage '<h1 class="logo">年齢認証</h1><meta property="og:title" content="架空の作品">' | Should Be '架空の作品' }
  It '見直し：productTitle の h1 は og:title が切れていても使う' { ConvertFrom-FanzaPage '<h1>サイトの名前</h1><h1 class="productTitle__txt">架空の作品 〜続き〜</h1><meta property="og:title" content="架空の...">' | Should Be '架空の作品 〜続き〜' }
  It '見直し：og:title と同じ書き出しの h1 は使う（切れた og:title の続きを取る）' { ConvertFrom-FanzaPage '<h1>架空の作品 〜長い副題の続き〜</h1><meta property="og:title" content="架空の作品 〜長い...">' | Should Be '架空の作品 〜長い副題の続き〜' }
  It '見直し：作品名らしい h1 も og:title もなければ空' { ConvertFrom-FanzaPage '<h1>年齢認証</h1>' | Should Be '' }
  It 'FANZA の見出しがなければ og:title' { ConvertFrom-FanzaPage '<meta property="og:title" content="架空 &amp; 作品">' | Should Be '架空 & 作品' }
  It 'FANZA の og:title がなければ空（年齢確認のページなど）' { ConvertFrom-FanzaPage '<html><head><title>年齢認証</title></head></html>' | Should Be '' }
}

Describe 'Get-StoreTitles' {
  It '自分で入れた作品名はネットに出ずに返す' {
    $c = New-ManualCode 'BOOTH' 'かくう'
    $r = Get-StoreTitles @($c)
    $r[$c] | Should Be 'かくう'
    $script:StoreFailedCount | Should Be 0
  }
}
