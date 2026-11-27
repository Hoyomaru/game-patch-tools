// 拡張機能「所持チェック ブックマーク係」の判定部分（edge-extension/ops.js）のテスト。
// 実行: node --test tests/
// 作品名はすべて架空のものです。
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const ops = require('../edge-extension/ops.js');

const u = (code) => `https://www.dlsite.com/maniax/work/=/product_id/${code}.html`;
const bm = (id, code, title) => ({ id, title: title || `架空 ${code}`, url: u(code) });
const folder = (id, title, children) => ({ id, title, children });

// chrome.bookmarks.getTree の形
function sampleTree() {
  return [folder('0', '', [
    folder('1', 'お気に入りバー', [
      folder('10', '気になる', [
        bm('11', 'RJ01000001'),
        bm('12', 'rj01000002'),
        folder('13', '古い', [bm('14', 'RJ01000003')]),
        folder('15', 'ASで見つかった', [bm('16', 'RJ01000004')]),
        { id: '17', title: '別サイト', url: 'https://example.com/RJ01000005' },
      ]),
      bm('20', 'RJ01000001'),
    ]),
    folder('2', 'その他のお気に入り', [
      folder('30', '気になる', [bm('31', 'RJ01000006')]),
    ]),
    folder('3', 'モバイルのお気に入り', []),
  ])];
}

const hashOf = (o) => '#gpt-bookmarks=' + encodeURIComponent(JSON.stringify(o));

test('parsePayload: 正しい中身を読む', () => {
  const p = ops.parsePayload(hashOf({ v: 1, op: 'delete', folder: 'お気に入りバー / 気になる', codes: ['RJ01000001'], items: [] }));
  assert.equal(p.op, 'delete');
  assert.deepEqual(p.codes, ['RJ01000001']);
});

test('parsePayload: 壊れた・違うものは null', () => {
  assert.equal(ops.parsePayload('#gpt-bookmarks=%7Bx'), null);
  assert.equal(ops.parsePayload('#gpt-bookmarks=%E3%81'), null);
  assert.equal(ops.parsePayload(hashOf({ v: 2, op: 'delete', codes: [] })), null);
  assert.equal(ops.parsePayload(hashOf({ v: 1, op: 'wipe', codes: [] })), null);
  assert.equal(ops.parsePayload(hashOf({ v: 1, op: 'delete', codes: 'RJ01000001' })), null);
  assert.equal(ops.parsePayload(hashOf({ v: 1, op: 'add', items: {} })), null);
  assert.equal(ops.parsePayload(''), null);
  assert.equal(ops.parsePayload('#apf-auto=1'), null);
});

test('codeOf: RJ番号を大文字で取る', () => {
  assert.equal(ops.codeOf(u('rj01000002')), 'RJ01000002');
  assert.equal(ops.codeOf('https://www.dlsite.com/maniax/'), '');
  assert.equal(ops.codeOf(undefined), '');
});

test('findFolders: 名前で探す', () => {
  const f = ops.findFolders(sampleTree(), 'お気に入りバー / 気になる', -1);
  assert.deepEqual(f.map((x) => x.id), ['10']);
});

test('findFolders: ルートの名前が違えば位置で探す', () => {
  assert.deepEqual(ops.findFolders(sampleTree(), 'Favorites bar / 気になる', 0).map((x) => x.id), ['10']);
  assert.deepEqual(ops.findFolders(sampleTree(), 'Other favorites / 気になる', 1).map((x) => x.id), ['30']);
});

test('findFolders: 空ならルート全部、見つからなければ空', () => {
  assert.deepEqual(ops.findFolders(sampleTree(), '', -1).map((x) => x.id), ['1', '2', '3']);
  assert.deepEqual(ops.findFolders(sampleTree(), 'お気に入りバー / ない', 0), []);
  assert.deepEqual(ops.findFolders(sampleTree(), 'どこにもない / 気になる', -1), []);
});

test('planOps delete: サブフォルダの中も消し、フォルダの外は消さない', () => {
  const r = ops.planOps(sampleTree(), { v: 1, op: 'delete', folder: 'お気に入りバー / 気になる', root: 0, codes: ['RJ01000001', 'RJ01000003', 'RJ01000005', 'RJ01000006'] });
  assert.equal(r.error, undefined);
  assert.deepEqual(r.remove.sort(), ['11', '14']);
  assert.equal(r.folderLabel, 'お気に入りバー / 気になる');
});

test('planOps delete: フォルダなしなら全体から消す', () => {
  const r = ops.planOps(sampleTree(), { v: 1, op: 'delete', folder: '', root: -1, codes: ['rj01000001'] });
  assert.deepEqual(r.remove.sort(), ['11', '20']);
});

test('planOps: フォルダが見つからなければ error で、何もしない', () => {
  const r = ops.planOps(sampleTree(), { v: 1, op: 'delete', folder: 'お気に入りバー / ない', root: 0, codes: ['RJ01000001'] });
  assert.ok(r.error);
  assert.deepEqual(r.remove, []);
});

test('planOps add: もうある番号と、中で重なる番号は足さない', () => {
  const items = [
    { code: 'RJ01000001', title: 'a', url: u('RJ01000001') },
    { code: 'RJ01000003', title: 'b', url: u('RJ01000003') },
    { code: 'RJ01000007', title: '架空の新作', url: u('RJ01000007') },
    { code: 'rj01000007', title: '重なり', url: u('RJ01000007') },
    { code: 'RJ01000008', title: '別サイト', url: 'https://example.com/RJ01000008' },
  ];
  const r = ops.planOps(sampleTree(), { v: 1, op: 'add', folder: 'お気に入りバー / 気になる', root: 0, items });
  assert.deepEqual(r.add, [{ title: '架空の新作', url: u('RJ01000007') }]);
  assert.equal(r.parentId, '10');
});

test('planOps move: sub の中のものは除き、sub があればそこへ', () => {
  const r = ops.planOps(sampleTree(), { v: 1, op: 'move', folder: 'お気に入りバー / 気になる', root: 0, codes: ['RJ01000001', 'RJ01000003', 'RJ01000004'], sub: 'ASで見つかった' });
  assert.deepEqual(r.move.sort(), ['11', '14']);
  assert.equal(r.createSub, false);
  assert.equal(r.subId, '15');
});

test('planOps move: sub がなければ作る', () => {
  const r = ops.planOps(sampleTree(), { v: 1, op: 'move', folder: 'お気に入りバー / 気になる', root: 0, codes: ['RJ01000002'], sub: '新しい' });
  assert.deepEqual(r.move, ['12']);
  assert.equal(r.createSub, true);
  assert.equal(r.parentId, '10');
});

test('planOps move: sub が空なら error', () => {
  const r = ops.planOps(sampleTree(), { v: 1, op: 'move', folder: 'お気に入りバー / 気になる', root: 0, codes: ['RJ01000002'], sub: ' ' });
  assert.ok(r.error);
});
