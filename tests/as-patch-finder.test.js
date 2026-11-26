// AS Patch Finder の「解析」部分（画面を触らない処理）のテスト。
// 実行: node --test tests/
// タイトルはすべて架空のものです。
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// ユーザースクリプトから「解析」〜「表示」の印の間を取り出して読み込む
const src = fs.readFileSync(path.join(__dirname, '..', 'as-patch-finder.user.js'), 'utf8');
const start = src.indexOf('// ---------- 解析 ----------');
const end = src.indexOf('// ---------- 表示 ----------');
assert.ok(start >= 0 && end > start, '解析／表示の印が見つかりません');
const apf = new Function(src.slice(start, end) +
  '\nreturn { parseVersion, parseDates, cmpVersion, newer, decidedBy, rankThreads, diffResults, mergeChanges, cutCode, orphanCodes, titleKeyword, titleMatches, codeOf, isRequest, orderGroup, parseRevisions, revDateOf };')();

const T = (title, extra = {}) => Object.assign({ title, url: 'https://example.invalid/' + encodeURIComponent(title), hasCode: true, posted: 0, kind: 'thread' }, extra);
const info = (title, posted = 0) => {
  const pv = apf.parseVersion(title);
  const dates = apf.parseDates(title);
  if (pv.dateVer && !dates.includes(pv.dateVer)) dates.push(pv.dateVer), dates.sort();
  return { title, version: pv.version, dateVer: pv.dateVer, lastDate: dates[dates.length - 1] || null, posted };
};

test('バージョンの読み取り', () => {
  const cases = [
    ['Game v1.08a English', '1.08a', null],
    ['Game Ver1.10 + DLC v2.0', '1.10', null],
    ['Game Version 1.2.3', '1.2.3', null],
    ['Game v10.2.3', '10.2.3', null],          // 日付と取り違えない
    ['Game Ver11.5.2', '11.5.2', null],
    ['Game v1.0→v1.2 patch', '1.2', null],      // 範囲は後ろ側
    ['Game v1.10-1.20', '1.20', null],
    ['Game v1.0 to 1.2', '1.2', null],
    ['Game v1.2-1', '1.2.1', null],            // 後ろが小さければ枝番
    ['Game v1_02', '1.02', null],
    ['Game [r102652]', '102652', null],
    ['Game v2', '2', null],
    ['Game Ver26.11.08', null, '2026-11-08'],
    ['Game (Ver0.23.9.26) + patch.1', null, '2023-09-26'],   // 「0.」付きの日付版
    ['Game v0.23.11.13', null, '2023-11-13'],
    ['Game v0.2.3.4', '0.2.3.4', null],                     // 年が2桁でなければ普通のバージョン
    ['Game v0.99.1.2', '0.99.1.2', null],                   // 年としてありえなければ普通のバージョン
    ['Game v26-11-08', null, '2026-11-08'],
    ['Game Ver2026.11.08', null, '2026-11-08'],
    ['Game v261108', null, '2026-11-08'],
    ['Game English', null, null],
  ];
  for (const [title, version, dateVer] of cases) {
    assert.deepEqual(apf.parseVersion(title), { version, dateVer }, title);
  }
});

test('タイトル内の日付', () => {
  assert.deepEqual(apf.parseDates('Game (2023.02.14)'), ['2023-02-14']);
  assert.deepEqual(apf.parseDates('Game (23.02.14)'), ['2023-02-14']);
  assert.deepEqual(apf.parseDates('Game (230214)'), ['2023-02-14']);
  assert.deepEqual(apf.parseDates('Game [220702] [2023-01-05]'), ['2022-07-02', '2023-01-05']);
  assert.deepEqual(apf.parseDates('Game (991399)'), []);   // ありえない日付は拾わない
});

test('バージョン番号の比べ方', () => {
  assert.ok(apf.cmpVersion('1.10', '1.9') > 0);
  assert.ok(apf.cmpVersion('1.0a', '1.0') > 0);
  assert.equal(apf.cmpVersion('1.2', '1.2.0'), 0);
});

test('最新の判定は並び順で変わらない', () => {
  const items = [info('X v1.2', 100), info('X english', 200), info('X v1.0', 300), info('X (2024.01.01)', 400), info('X Ver24.05.01', 50)];
  const orders = new Set();
  for (let i = 0; i < 200; i++) {
    const s = [...items].sort(() => Math.random() - 0.5).sort((a, b) => apf.newer(b, a));
    orders.add(s.map(x => x.title).join(' > '));
  }
  assert.equal(orders.size, 1);
  assert.equal([...orders][0], 'X v1.2 > X v1.0 > X Ver24.05.01 > X (2024.01.01) > X english');
});

test('1位と2位を分けた基準', () => {
  assert.equal(apf.decidedBy(info('X v1.2'), info('X v1.0')), 'バージョン');
  assert.equal(apf.decidedBy(info('X v1.0'), info('X')), '版の表記の有無');
  assert.equal(apf.decidedBy(info('X', 2), info('X', 1)), '投稿日');
});

test('自動検索：パッチ/翻訳を優先して最新を決める', () => {
  const rk = apf.rankThreads([
    T('RJ01 Game v1.5', { posted: 500 }),
    T('RJ01 Game v1.2 English patch', { posted: 100 }),
    T('RJ01 Game v1.3 English patch', { posted: 50 }),
    T('Other mention v9', { hasCode: false, posted: 900 }),
  ]);
  assert.equal(rk.latest.title, 'RJ01 Game v1.3 English patch');
  assert.equal(rk.patchOnly, true);
  assert.equal(rk.basis, 'バージョン');
  assert.equal(rk.list[0], rk.latest);
  assert.equal(rk.list[rk.list.length - 1].title, 'Other mention v9');
});

test('自動検索：コードありが無ければ作品名で見つかったものから選ぶ', () => {
  const rk = apf.rankThreads([
    T('Unrelated v3', { hasCode: false }),
    T('ゲーム v1.1', { hasCode: false, byTitle: true }),
    T('ゲーム v1.0', { hasCode: false, byTitle: true }),
  ]);
  assert.equal(rk.latest.title, 'ゲーム v1.1');
  assert.equal(rk.byTitle, true);
  assert.equal(apf.rankThreads([T('Unrelated', { hasCode: false })]).latest, null);
});

test('前回との違い（新着・最新の更新）', () => {
  const prev = { threads: [T('RJ01 Game v1.0 English patch')] };
  assert.equal(apf.diffResults(null, prev.threads), null);                   // 初めての検索
  assert.equal(apf.diffResults({ threads: [], error: 'x' }, prev.threads), null); // 前回エラー
  assert.equal(apf.diffResults(prev, prev.threads), null);                   // 変化なし

  const d = apf.diffResults(prev, [...prev.threads, T('RJ01 Game v1.1 English patch')]);
  assert.deepEqual(d, { newCount: 1, latestChanged: true, from: 'v1.0', to: 'v1.1' });

  const d2 = apf.diffResults(prev, [...prev.threads, T('RJ01 Game save data', { posted: 1 })]);
  assert.deepEqual(d2, { newCount: 1, latestChanged: false, from: 'v1.0', to: 'v1.0' });

  // 同じスレッドのタイトルが書き換わってバージョンが上がった
  const d3 = apf.diffResults(prev, [T('RJ01 Game v1.2 English patch', { url: prev.threads[0].url })]);
  assert.deepEqual(d3, { newCount: 0, latestChanged: true, from: 'v1.0', to: 'v1.2' });
});

test('まだ消していない印は、検索し直しても残る', () => {
  const old = { newCount: 1, latestChanged: true, from: 'v1.0', to: 'v1.1' };
  assert.deepEqual(apf.mergeChanges(old, null), old);                 // 今回は変化なし → 前の印のまま
  assert.equal(apf.mergeChanges(null, null), null);
  const now = { newCount: 2, latestChanged: true, from: 'v1.1', to: 'v1.2' };
  assert.deepEqual(apf.mergeChanges(old, now), { newCount: 3, latestChanged: true, from: 'v1.0', to: 'v1.2' });
  const onlyNew = { newCount: 1, latestChanged: false, from: 'v1.0', to: 'v1.0' };
  assert.deepEqual(apf.mergeChanges(onlyNew, now), { newCount: 3, latestChanged: true, from: 'v1.1', to: 'v1.2' });
});

test('途中で切れたタイトルのコード', () => {
  assert.ok(apf.cutCode('Some long title [RJ012345...', 'RJ01234567'));
  assert.ok(apf.cutCode('Some long title [RJ012345…', 'RJ01234567'));
  assert.ok(!apf.cutCode('Some long title [RJ01...', 'RJ01234567'));   // RJ01 だけでは決めない
  assert.ok(!apf.cutCode('Some long title [RJ012399...', 'RJ01234567'));
});

test('今のリストにない作品の結果', () => {
  const results = { RJ01000001: {}, RJ01000002: {}, RJ01000003: {} };
  const titles = { RJ01000002: 'b', RJ01000004: 'd' };
  assert.deepEqual(apf.orphanCodes(results, ['RJ01000002', 'RJ01000003'], titles).sort(), ['RJ01000001', 'RJ01000004']);
  assert.deepEqual(apf.orphanCodes(results, Object.keys(results)), []);
});

test('作品名検索のキーワード', () => {
  assert.equal(apf.titleKeyword('【10%OFF】ふしぎな森の冒険 ～はじまりの章～ [架空サークル] | DLsite'), 'ふしぎな森の冒険');
  assert.equal(apf.titleKeyword('Ｆｕｌｌ　Ｗｉｄｔｈ　Ｔｉｔｌｅ'), 'Full Width Title');
  assert.equal(apf.titleKeyword('とてもとても長い作品名のテストですよほんとうに長い 副題もある'), 'とてもとても長い作品名のテストですよほんとうに長い');
  assert.equal(apf.titleKeyword('【セール】'), '');
});

test('作品名検索の当たり判定', () => {
  assert.ok(apf.titleMatches('[RJ00000000] ふしぎな森の冒険 v1.0 English', 'ふしぎな森の冒険'));
  assert.ok(apf.titleMatches('Full-Width Title v2', 'Full Width Title'));
  assert.ok(!apf.titleMatches('まったく別の作品', 'ふしぎな森の冒険'));
});

test('作品コードはタイトル・URL・切れたタイトルから決める', () => {
  assert.equal(apf.codeOf('[RJ01234567] Game v1.0'), 'RJ01234567');
  assert.equal(apf.codeOf('Game v1.0 English', '/threads/rj01234567-game-v1-0-english.123/'), 'RJ01234567');
  assert.equal(apf.codeOf('Some long title [RJ012345...', '/threads/some-long-title.123/', ['RJ01234567']), 'RJ01234567');
  assert.equal(apf.codeOf('Some long title [RJ01...', '/threads/some-long-title.123/', ['RJ01234567']), null);
  assert.equal(apf.codeOf('Game v1.0 English', '/threads/game-v1-0-english.123/'), null);
});

test('リクエストスレッドの見分け', () => {
  assert.ok(apf.isRequest('[REQUEST][RJ01234567]ふしぎな森の冒険'));
  assert.ok(apf.isRequest('Request: Some Game'));
  assert.ok(apf.isRequest('ふしぎな森の冒険', 'Hentai Games Request'));
  assert.ok(!apf.isRequest('[RJ01234567] ふしぎな森の冒険 v1.0', 'Hentai Games'));
});

test('作品グループの最新は、リクエストと本文だけで当たったものを候補にしない', () => {
  const R = (title, extra = {}) => Object.assign(info(title), extra);
  const code = R('[RJ01234567] Game v1.0');
  const weak = R('Game v2.0 English', { weak: true });
  const req = R('[REQUEST][RJ01234567] Game v3.0', { isRequest: true });
  const o = apf.orderGroup([weak, req, code]);
  assert.equal(o.latest, code);
  assert.deepEqual(o.list, [code, req, weak]);
  // コードありが無ければ、本文だけで当たったものから選ぶ
  assert.equal(apf.orderGroup([weak, req]).latest, weak);
  // リクエストしかなければ最新なし
  assert.equal(apf.orderGroup([req]).latest, null);
});

test('DLsite の更新情報の読み取り', () => {
  const revs = apf.parseRevisions([
    { release_date: '2026年09月23日', info: '・バージョンを1.0.0から1.0.1へ更新' },
    { release_date: '2026年10月03日', info: '・Ver1.0.3に更新\r\n・不具合修正' },
    { release_date: '2026年09月26日', info: '・Ｖｅｒ 1.0.2に更新' },   // 全角でも読む
    { release_date: '2026年08月01日', info: '・誤字修正' },
  ]);
  assert.deepEqual(revs, [
    { date: '2026-10-03', version: '1.0.3' },
    { date: '2026-09-26', version: '1.0.2' },
    { date: '2026-09-23', version: '1.0.1' },
    { date: '2026-08-01', version: null },
  ]);
});

test('バージョン番号と日付版を DLsite の更新情報で比べる', () => {
  const ts = s => Date.parse(s + 'T12:00:00') / 1000;
  const revs = [
    { date: '2026-10-03', version: '1.0.3' },
    { date: '2026-09-26', version: null },
    { date: '2026-09-01', version: null },
  ];
  // 番号が更新情報にあればその日、なければ投稿日までに出た一番新しい更新の日
  assert.equal(apf.revDateOf(info('Game v1.0.3'), revs), '2026-10-03');
  assert.equal(apf.revDateOf(info('Game v1.0.2', ts('2026-09-28')), revs), '2026-09-26');
  assert.equal(apf.revDateOf(info('Game Ver26.09.26'), revs), '2026-09-26');
  assert.equal(apf.revDateOf(info('Game v1.0.2', ts('2026-09-28')), []), null);
  assert.equal(apf.revDateOf(info('Game v1.0.0', ts('2026-08-20')), revs), '0000-00-00');   // 最初の更新より前は発売時の版   // 更新情報がなければ使わない

  const T2 = (title, posted) => T(title, { posted: ts(posted) });
  const threads = [T2('RJ01 Game v1.0.2', '2026-09-28'), T2('RJ01 Game Ver26.10.03', '2026-10-04')];
  // 更新情報がなければ今までどおりバージョン番号が勝つ
  assert.equal(apf.rankThreads(threads).latest.title, 'RJ01 Game v1.0.2');
  assert.ok(apf.rankThreads(threads).mixed);
  // 更新情報があれば、新しい日付版が勝つ
  const rk = apf.rankThreads(threads, revs);
  assert.equal(rk.latest.title, 'RJ01 Game Ver26.10.03');
  assert.equal(rk.basis, 'DLsite更新情報');
  // 番号が更新情報と一致する新しい版なら、古い日付版に勝つ
  const rk2 = apf.rankThreads([T2('RJ01 Game v1.0.3', '2026-10-05'), T2('RJ01 Game Ver26.09.26', '2026-09-27')], revs);
  assert.equal(rk2.latest.title, 'RJ01 Game v1.0.3');
});
