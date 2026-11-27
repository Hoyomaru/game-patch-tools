# 所持チェックの「ブックマークにない作品の見分け・手がかり・DLsite 検索」（画面を触らない部分）のテスト。
# 実行: powershell.exe -NoProfile -Command "Invoke-Pester -Script tests -EnableExit"
# 作品名はすべて架空のものです。DLsite には問い合わせません。

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'owned-core.ps1')
. (Join-Path $root 'owned-identify.ps1')
. (Join-Path $root 'owned-stores.ps1')

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
  It 'まとめて調べても1つずつと同じ（パスごと）' {
    New-TestFile (Join-Path $g 'y.zip')
    $paths = 'a', 'b', 'c', 'd', 'y.zip' | ForEach-Object { Join-Path $g $_ }
    $r = Find-InsideCodesMany $paths
    $r.Count | Should Be 5
    @($r[$paths[0]]) -join ',' | Should Be 'RJ00000101'
    @($r[$paths[2]]) -join ',' | Should Be 'RJ00000103,RJ00000104'
    @($r[$paths[3]]).Count | Should Be 0
    @($r[$paths[4]]).Count | Should Be 0
  }
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

Describe 'ConvertFrom-DLsiteSearch' {
  $json = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\dlsite-search-sample.json'))
  $h = @(ConvertFrom-DLsiteSearch $json)
  It '上から5件、重複なし' { $h.Count | Should Be 5; $h[0].Code | Should Be 'RJ00000201'; $h[2].Code | Should Be 'RJ00000203' }
  It '文字参照を戻す' { $h[0].Title | Should Be '架空の作品 & その2'; $h[1].Title | Should Be '架空の作品 "外伝"' }
  It '形が違えば空' { @(ConvertFrom-DLsiteSearch '{"search_result":""}').Count | Should Be 0; @(ConvertFrom-DLsiteSearch 'not json').Count | Should Be 0 }
}

Describe 'Select-AutoCode' {
  $hit = { param($c, $t) [pscustomobject]@{ Code = $c; Title = $t; Floor = 'maniax' } }
  $hits = @((& $hit 'RJ00000301' '架空のRPG'), (& $hit 'RJ00000302' '架空のRPG 2'))
  It '中の作品名で、完全一致が1つならその番号' { Select-AutoCode $hits '架空の RPG' $true | Should Be 'RJ00000301' }
  It 'フォルダ名から作った言葉なら一致しても空' { Select-AutoCode $hits '架空のRPG' $false | Should Be '' }
  It '全年齢と R18 で2つ一致したら空' { Select-AutoCode @($hits + (& $hit 'RJ00000303' '架空のRPG')) '架空のRPG' $true | Should Be '' }
  It '一致がなければ空' { Select-AutoCode $hits 'べつ' $true | Should Be '' }
}

Describe 'SearchCache' {
  It '保存して読み戻せる' {
    $p = Join-Path $TestDrive 'cache.json'
    $c = @{ '架空のRPG' = @{ Ok = $true; At = '2026-11-27'; Hits = @(@{ Code = 'RJ00000301'; Title = '架空のRPG'; Floor = 'maniax' }) } }
    Save-SearchCache $p $c
    $r = Read-SearchCache $p
    $r['架空のRPG'].Ok | Should Be $true
    @($r['架空のRPG'].Hits)[0].Code | Should Be 'RJ00000301'
  }
  It 'なければ空' { (Read-SearchCache (Join-Path $TestDrive 'none.json')).Count | Should Be 0 }
}

Describe '最終レビューで見つかった点' {
  It 'サークルの中に作品1つとアーカイブがあれば、外側をまとめない' {
    $g = Join-Path $TestDrive 'fx1'
    New-TestFile (Join-Path $g 'circleA\gameA\Game.exe'); New-TestFile (Join-Path $g 'circleA\other.zip')
    $p = @(Get-UnknownWorks (Get-GameCandidates @($g) 2) @() @($g) | ForEach-Object Path)
    $p -contains (Join-Path $g 'circleA') | Should Be $false
    $p -contains (Join-Path $g 'circleA\gameA') | Should Be $true
  }
  It 'サークルの中に作品と「名前\Game」形の作品があれば、外側をまとめず入れ子にもしない' {
    $g = Join-Path $TestDrive 'fx2'
    New-TestFile (Join-Path $g 'circleB\b1\Game.exe'); New-TestFile (Join-Path $g 'circleB\b2\Game\Game.exe')
    $p = @(Get-UnknownWorks (Get-GameCandidates @($g) 2) @() @($g) | ForEach-Object Path)
    $p -contains (Join-Path $g 'circleB') | Should Be $false
    $p -contains (Join-Path $g 'circleB\b1') | Should Be $true
    $p -contains (Join-Path $g 'circleB\b2') | Should Be $true
  }
  It '500 件でも数秒で見分けられる' {
    $g = Join-Path $TestDrive 'fx3'
    foreach ($c in 1..100) { foreach ($w in 1..4) { New-TestFile (Join-Path $g "c$c\w$w\Game.exe") } }
    $cands = Get-GameCandidates @($g) 2
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $n = @(Get-UnknownWorks $cands @() @($g)).Count
    $sw.Stop()
    $n | Should Be 400
    $sw.Elapsed.TotalSeconds | Should BeLessThan 4
  }
  It '検索結果の読み取りは、作品名のない作品をまたいで次の作品の作品名を拾わない' {
    $json = '{"search_result":"<dd class=\"work_name\"><a href=\"https://www.dlsite.com/maniax/work/=/product_id/RJ00000701.html\">x</a></dd><dd class=\"work_name\"><a href=\"https://www.dlsite.com/maniax/work/=/product_id/RJ00000702.html\" title=\"架空B\">x</a></dd>"}'
    $h = @(ConvertFrom-DLsiteSearch $json)
    @($h | Where-Object { $_.Code -eq 'RJ00000701' -and $_.Title -eq '架空B' }).Count | Should Be 0
    @($h | Where-Object { $_.Code -eq 'RJ00000702' -and $_.Title -eq '架空B' }).Count | Should Be 1
  }
  It 'Find-InsideCodes はファイルが多くても上限までしか見ない' {
    $g = Join-Path $TestDrive 'fx4'
    New-TestDirs $g @('many')
    foreach ($i in 1..30) { New-TestFile (Join-Path $g "many\f$i.dat") }
    New-TestFile (Join-Path $g 'many\zz\RJ00000801.dat')
    $script:InsideMaxFiles = 10
    try { @(Find-InsideCodes (Join-Path $g 'many')).Count | Should Be 0 } finally { $script:InsideMaxFiles = 5000 }
  }
}

Describe 'Get-DLsiteSearchUrl' {
  # DLsite は検索の言葉の中の %20（空白）を 403 で断るので、空白は + にする
  It '空白は + にする' { Get-DLsiteSearchUrl 'maniax' 'magic girl' | Should Be 'https://www.dlsite.com/maniax/fsr/ajax/=/language/jp/keyword/magic+girl/' }
  It '+ そのものは %2B のまま' { Get-DLsiteSearchUrl 'home' 'A+B' | Should Be 'https://www.dlsite.com/home/fsr/ajax/=/language/jp/keyword/A%2BB/' }
  It '日本語と / は % で表す' { Get-DLsiteSearchUrl 'maniax' 'テスト/1' | Should Be 'https://www.dlsite.com/maniax/fsr/ajax/=/language/jp/keyword/%E3%83%86%E3%82%B9%E3%83%88%2F1/' }
}

Describe 'Search-DLsite（問い合わせを差し替えて）' {
  $json = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\dlsite-search-sample.json'))
  It '2つの売り場の URL を1回でまとめて渡し、R18 → 全年齢の順に並べる' {
    $script:seen = $null
    $r = Search-DLsite 'magic girl' -Fetch { param([string[]]$Urls) $script:seen = $Urls; @($json, $json) }
    @($script:seen).Count | Should Be 2
    $script:seen[0] | Should Be (Get-DLsiteSearchUrl 'maniax' 'magic girl')
    $script:seen[1] | Should Be (Get-DLsiteSearchUrl 'home' 'magic girl')
    $r.Ok | Should Be $true
    $n = @(ConvertFrom-DLsiteSearch $json).Count
    @($r.Hits).Count | Should Be (2 * $n)
    $r.Hits[0].Floor | Should Be 'maniax'
    $r.Hits[$n].Floor | Should Be 'home'
  }
  It '片方の返事が取れなければ Ok は偽で、取れた分は返す' {
    $r = Search-DLsite 'x' -Fetch { param([string[]]$Urls) @($null, $json) }
    $r.Ok | Should Be $false
    @($r.Hits).Count | Should Be @(ConvertFrom-DLsiteSearch $json).Count
    $r.Hits[0].Floor | Should Be 'home'
  }
}

Describe '検索の言葉のゴミ取り（版の数字・win など）' {
  It '点で区切った版の数字と EA を除く' { New-SearchTerm 'かくうの全国大会_0.7.1EA' $false | Should Be 'かくうの全国大会' }
  It 'win と Fixed を除く' { New-SearchTerm 'Echoes of the kakuu 3.7.3 win Fixed' $false | Should Be 'Echoes of the kakuu' }
  It 'ただの数字1つは残す' { New-SearchTerm 'かくう2' $false | Should Be 'かくう2' }
  It 'ゲームの中の作品名の版も除く' { New-SearchTerm '反抗的なかくうが堕ちるまで v1.1.0' $false | Should Be '反抗的なかくうが堕ちるまで' }
}

Describe 'Get-SearchFallbacks' {
  It '記号で区切れていれば一番長い部分、その前半の順' { (Get-SearchFallbacks 'かくう 負け負け誘惑かくう') -join '|' | Should Be '負け負け誘惑かくう|負け負け誘' }
  It '1つだけなら前半だけ' { (Get-SearchFallbacks '反抗的なかくうが堕ちるまで') -join '|' | Should Be '反抗的なかくう' }
  It '短すぎるものは作らない' { @(Get-SearchFallbacks 'かくう').Count | Should Be 0 }
  It '英数字だけの言葉は短くしない（関係ない作品ばかり出るため）' { @(Get-SearchFallbacks 'TriplePairing').Count | Should Be 0; @(Get-SearchFallbacks 'Slave Princess Kakuu').Count | Should Be 0 }
}

Describe 'Search-DLsiteWithFallback（問い合わせを差し替えて）' {
  $json = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\dlsite-search-sample.json'))
  $empty = '{"search_result":"","page_info":{"count":0}}'
  It '見つかれば短くしない' {
    $script:calls = 0
    $r = Search-DLsiteWithFallback '反抗的なかくうが堕ちるまで' -GapMs 0 -Fetch { param([string[]]$Urls) $script:calls++; @($json, $json) }
    $script:calls | Should Be 1
    $r.UsedTerm | Should Be '反抗的なかくうが堕ちるまで'
  }
  It '0 件なら短くして検索し直し、使った言葉を返す' {
    $script:calls = 0
    $r = Search-DLsiteWithFallback '反抗的なかくうが堕ちるまで' -GapMs 0 -Fetch { param([string[]]$Urls) $script:calls++; if ($script:calls -eq 1) { @($empty, $empty) } else { @($json, $empty) } }
    $script:calls | Should Be 2
    $r.Ok | Should Be $true
    @($r.Hits).Count | Should BeGreaterThan 0
    $r.UsedTerm | Should Be '反抗的なかくう'
  }
  It '返事が取れなければ短くしない（Ok は偽）' {
    $script:calls = 0
    $r = Search-DLsiteWithFallback '反抗的なかくうが堕ちるまで' -GapMs 0 -Fetch { param([string[]]$Urls) $script:calls++; @($null, $null) }
    $script:calls | Should Be 1
    $r.Ok | Should Be $false
  }
}

Describe 'Test-SearchNeeded（保存した検索結果を使うか）' {
  It '保存がなければ検索する' { Test-SearchNeeded @{} 'かくう' | Should Be $true }
  It '失敗していれば検索する' { Test-SearchNeeded @{ 'かくう' = [pscustomobject]@{ Ok = $false; Hits = @(); V = 2 } } 'かくう' | Should Be $true }
  It '前のやり方で 0 件なら、短くして検索し直すために検索する' { Test-SearchNeeded @{ 'かくう' = [pscustomobject]@{ Ok = $true; Hits = @(); V = 0 } } 'かくう' | Should Be $true }
  It '今のやり方で 0 件なら検索しない' { Test-SearchNeeded @{ 'かくう' = [pscustomobject]@{ Ok = $true; Hits = @(); V = 2 } } 'かくう' | Should Be $false }
  It '見つかっていれば検索しない' { Test-SearchNeeded @{ 'かくう' = [pscustomobject]@{ Ok = $true; Hits = @([pscustomobject]@{ Code = 'RJ00000001'; Title = 'x' }); V = 0 } } 'かくう' | Should Be $false }
  It '保存して読み直しても V が残る' {
    $p = Join-Path $TestDrive 'cache.json'
    Save-SearchCache $p @{ 'かくう' = [pscustomobject]@{ Ok = $true; At = '2026-11-27'; Hits = @(); V = 2 } }
    (Read-SearchCache $p)['かくう'].V | Should Be 2
  }
}
