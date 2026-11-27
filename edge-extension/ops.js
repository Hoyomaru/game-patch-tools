// 所持チェック ブックマーク係：何を消す・足す・移すかを決める部分（画面もブラウザも触らない）。
// service worker から importScripts で、テストから require で読む。
'use strict';
(function (root) {
  const PREFIX = '#gpt-bookmarks=';
  const OPS = ['delete', 'add', 'move'];
  const CODE_RE = /(?<![A-Za-z0-9])((?:RJ|VJ|BJ|RE)\d{6,8})(?![0-9])/i;
  const DLSITE_RE = /^https?:\/\/([a-z0-9-]+\.)*dlsite\.com\//i;

  // URL の # の後ろから、所持チェックが渡した中身を読む。違う・壊れているなら null
  function parsePayload(hash) {
    if (typeof hash !== 'string' || !hash.startsWith(PREFIX)) return null;
    let p;
    try { p = JSON.parse(decodeURIComponent(hash.slice(PREFIX.length))); } catch (e) { return null; }
    if (!p || typeof p !== 'object' || p.v !== 1 || !OPS.includes(p.op)) return null;
    if (p.codes !== undefined && !Array.isArray(p.codes)) return null;
    if (p.items !== undefined && !Array.isArray(p.items)) return null;
    return {
      v: 1,
      op: p.op,
      folder: typeof p.folder === 'string' ? p.folder : '',
      root: Number.isInteger(p.root) ? p.root : -1,
      codes: (p.codes || []).filter((c) => typeof c === 'string'),
      items: (p.items || []).filter((x) => x && typeof x === 'object'),
      sub: typeof p.sub === 'string' ? p.sub : '',
    };
  }

  function codeOf(url) {
    const m = typeof url === 'string' ? url.match(CODE_RE) : null;
    return m ? m[1].toUpperCase() : '';
  }

  // DLsite の作品のブックマークなら、その RJ番号
  function dlsiteCode(node) {
    return node && node.url && DLSITE_RE.test(node.url) ? codeOf(node.url) : '';
  }

  const isFolder = (n) => n && !n.url && Array.isArray(n.children);

  // 「ルートの名前 / a / b」のフォルダを探す（所持チェックの Get-BookmarkFolderNodes と同じく、
  // 同じ道順のフォルダは全部返し、当てはまったフォルダの中はそれ以上探さない）。
  // ルートは名前で、合わなければ rootIndex の位置で。path が空ならルート全部
  function findFolders(tree, path, rootIndex) {
    const roots = (tree && tree[0] && tree[0].children || []).filter(isFolder);
    if (!path) return roots;
    const parts = path.split(' / ');
    let starts = roots.filter((r) => r.title === parts[0]);
    if (starts.length === 0 && Number.isInteger(rootIndex) && rootIndex >= 0 && roots[rootIndex]) starts = [roots[rootIndex]];
    const found = [];
    const walk = (node, depth) => {
      for (const c of node.children || []) {
        if (!isFolder(c) || c.title !== parts[depth]) continue;
        if (depth === parts.length - 1) found.push(c); else walk(c, depth + 1);
      }
    };
    for (const r of starts) {
      if (parts.length === 1) found.push(r); else walk(r, 1);
    }
    return found;
  }

  function eachBookmark(node, fn, skip) {
    for (const c of node.children || []) {
      if (c === skip) continue;
      if (isFolder(c)) eachBookmark(c, fn, skip); else fn(c);
    }
  }

  // 何をするかを決める。書き換えはしない
  function planOps(tree, payload) {
    const out = { folderLabel: payload.folder || '（ブックマーク全体）', remove: [], add: [], move: [], createSub: false };
    const folders = findFolders(tree, payload.folder, payload.root);
    if (folders.length === 0) { out.error = `フォルダ「${payload.folder}」が見つかりません。何も変えていません。`; return out; }
    const codes = new Set((payload.codes || []).map((c) => String(c).toUpperCase()));

    if (payload.op === 'delete') {
      for (const f of folders) eachBookmark(f, (b) => { if (codes.has(dlsiteCode(b))) out.remove.push(b.id); });
      return out;
    }

    const target = folders[0];
    out.parentId = target.id;

    if (payload.op === 'add') {
      const have = new Set();
      eachBookmark(target, (b) => { const c = codeOf(b.url); if (c) have.add(c); });
      for (const it of payload.items || []) {
        const c = codeOf(it.code);
        if (!c || have.has(c) || typeof it.url !== 'string' || !DLSITE_RE.test(it.url) || codeOf(it.url) !== c) continue;
        have.add(c);
        out.add.push({ title: String(it.title || c), url: it.url });
      }
      return out;
    }

    // move
    const subName = (payload.sub || '').trim();
    if (!subName) { out.error = 'まとめる先のフォルダ名が空です。何も変えていません。'; return out; }
    out.sub = subName;
    const sub = (target.children || []).find((c) => isFolder(c) && c.title === subName);
    const have = new Set();
    if (sub) { out.subId = sub.id; eachBookmark(sub, (b) => { const c = codeOf(b.url); if (c) have.add(c); }); } else out.createSub = true;
    eachBookmark(target, (b) => {
      const c = dlsiteCode(b);
      if (c && codes.has(c) && !have.has(c)) { have.add(c); out.move.push(b.id); }
    }, sub);
    return out;
  }

  const api = { parsePayload, codeOf, findFolders, planOps };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.GptBookmarkOps = api;
})(typeof self !== 'undefined' ? self : this);
