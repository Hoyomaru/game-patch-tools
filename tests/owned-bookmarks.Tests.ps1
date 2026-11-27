# 所持チェックの「同期がオンかの見分け」と「拡張機能に渡す URL」のテスト。
# 実行: powershell.exe -NoProfile -Command "Invoke-Pester -Script tests/owned-bookmarks.Tests.ps1 -EnableExit"
# 作品名はすべて架空のものです。Pester 3.4 で動きます。

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'owned-core.ps1')

function New-TestBookmarks([string]$Name, [string]$SyncPart) {
  $p = Join-Path $TestDrive $Name
  $json = '{"checksum":"x","roots":{"bookmark_bar":{"children":[],"name":"お気に入りバー","type":"folder"},"other":{"children":[],"name":"その他のお気に入り","type":"folder"}}' + $SyncPart + ',"version":1}'
  [IO.File]::WriteAllText($p, $json, (New-Object Text.UTF8Encoding $false))
  return $p
}

function Get-PayloadFromUrl([string]$Url) {
  $i = $Url.IndexOf('#gpt-bookmarks=')
  return [uri]::UnescapeDataString($Url.Substring($i + 15)) | ConvertFrom-Json
}

Describe 'Test-BookmarksSynced' {
  It 'sync_metadata があれば同期がオン' { Test-BookmarksSynced (New-TestBookmarks 'a' ',"sync_metadata":"CgQIARAB"') | Should Be $true }
  It 'sync_metadata がなければオフ' { Test-BookmarksSynced (New-TestBookmarks 'b' '') | Should Be $false }
  It 'sync_metadata が空ならオフ' { Test-BookmarksSynced (New-TestBookmarks 'c' ',"sync_metadata":""') | Should Be $false }
  It '読めないファイルはオフ' {
    $p = Join-Path $TestDrive 'broken'; Set-Content -LiteralPath $p -Value '{x'
    Test-BookmarksSynced $p | Should Be $false
  }
}

Describe 'Get-EdgeProfileDir' {
  It 'Edge の Default' { Get-EdgeProfileDir 'C:\Users\u\AppData\Local\Microsoft\Edge\User Data\Default\Bookmarks' | Should Be 'Default' }
  It 'Edge の Profile 2' { Get-EdgeProfileDir 'C:\Users\u\AppData\Local\Microsoft\Edge\User Data\Profile 2\Bookmarks' | Should Be 'Profile 2' }
  It 'Chrome は空' { Get-EdgeProfileDir 'C:\Users\u\AppData\Local\Google\Chrome\User Data\Default\Bookmarks' | Should Be '' }
  It 'コピーしたファイルは空' { Get-EdgeProfileDir 'D:\backup\Bookmarks' | Should Be '' }
}

Describe 'Get-BookmarkRootIndex' {
  It 'お気に入りバーは 0' { Get-BookmarkRootIndex (New-TestBookmarks 'r1' '') 'お気に入りバー / DLsite' | Should Be 0 }
  It 'その他は 1' { Get-BookmarkRootIndex (New-TestBookmarks 'r2' '') 'その他のお気に入り / A / B' | Should Be 1 }
  It 'フォルダなしは -1' { Get-BookmarkRootIndex (New-TestBookmarks 'r3' '') '' | Should Be -1 }
}

Describe 'New-BookmarkOpUrls' {
  It '少なければ1本で、中身が戻せる' {
    $urls = @(New-BookmarkOpUrls -Op 'move' -Folder 'お気に入りバー / 気になる' -Codes @('RJ01000001', 'RJ01000002') -Sub 'ASで見つかった' -RootIndex 0)
    $urls.Count | Should Be 1
    $urls[0].StartsWith('https://www.dlsite.com/maniax/#gpt-bookmarks=') | Should Be $true
    $p = Get-PayloadFromUrl $urls[0]
    $p.v | Should Be 1
    $p.op | Should Be 'move'
    $p.folder | Should Be 'お気に入りバー / 気になる'
    $p.sub | Should Be 'ASで見つかった'
    $p.root | Should Be 0
    ($p.codes -join ',') | Should Be 'RJ01000001,RJ01000002'
  }
  It '1件でも codes は配列' {
    $p = Get-PayloadFromUrl (@(New-BookmarkOpUrls -Op 'delete' -Folder '' -Codes @('RJ01000001'))[0])
    @($p.codes).Count | Should Be 1
    $p.codes.GetType().IsArray | Should Be $true
  }
  It '長すぎると分かれ、どれも上限以下で、番号は1回ずつ入る' {
    $codes = 1..300 | ForEach-Object { 'RJ{0:D8}' -f (1000000 + $_) }
    $urls = @(New-BookmarkOpUrls -Op 'delete' -Folder 'お気に入りバー / 気になる' -Codes $codes -MaxLen 2000)
    $urls.Count | Should BeGreaterThan 1
    foreach ($u in $urls) { $u.Length | Should Not BeGreaterThan 2000 }
    $all = foreach ($u in $urls) { (Get-PayloadFromUrl $u).codes }
    ($all -join ',') | Should Be ($codes -join ',')
  }
  It 'add は items を分ける' {
    $items = 1..40 | ForEach-Object { [pscustomobject]@{ Code = ('RJ{0:D8}' -f (1000000 + $_)); Title = "架空の作品 その$_"; Url = ('https://www.dlsite.com/maniax/work/=/product_id/RJ{0:D8}.html' -f (1000000 + $_)) } }
    $urls = @(New-BookmarkOpUrls -Op 'add' -Folder 'お気に入りバー / 気になる' -Items $items -MaxLen 3000)
    $urls.Count | Should BeGreaterThan 1
    foreach ($u in $urls) { $u.Length | Should Not BeGreaterThan 3000 }
    $all = foreach ($u in $urls) { (Get-PayloadFromUrl $u).items }
    @($all).Count | Should Be 40
    $all[0].title | Should Be '架空の作品 その1'
    $all[39].code | Should Be 'RJ01000040'
    $all[0].url | Should Be 'https://www.dlsite.com/maniax/work/=/product_id/RJ01000001.html'
  }
}

Describe 'Wait-FileChanged' {
  It '更新日時が変わればすぐ真' {
    $p = Join-Path $TestDrive 'w1'; Set-Content -LiteralPath $p -Value 'a'
    $since = (Get-Item -LiteralPath $p).LastWriteTimeUtc
    (Get-Item -LiteralPath $p).LastWriteTimeUtc = $since.AddSeconds(5)
    Wait-FileChanged $p $since 3000 | Should Be $true
  }
  It '変わらなければ待ったあと偽' {
    $p = Join-Path $TestDrive 'w2'; Set-Content -LiteralPath $p -Value 'a'
    $since = (Get-Item -LiteralPath $p).LastWriteTimeUtc
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Wait-FileChanged $p $since 600 | Should Be $false
    $sw.ElapsedMilliseconds | Should BeGreaterThan 500
  }
}
