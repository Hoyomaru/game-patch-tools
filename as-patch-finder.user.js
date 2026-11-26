// ==UserScript==
// @name         AS Patch Finder（検索結果のバージョン整理）
// @namespace    local.patch-finder
// @version      1.5.5
// @description  検索結果のタイトルからバージョン・作品コード・更新日を抜き出し、作品ごとにまとめて最新版をハイライトします。作品コードのリストを順番に自動検索して、見つかったスレッドのURLを集めることもできます。
// @icon         https://www.anime-sharing.com/styles/io/images/favicon.png
// @homepageURL  https://github.com/Hoyomaru/game-patch-tools
// @updateURL    https://raw.githubusercontent.com/Hoyomaru/game-patch-tools/main/as-patch-finder.user.js
// @downloadURL  https://raw.githubusercontent.com/Hoyomaru/game-patch-tools/main/as-patch-finder.user.js
// @match        https://www.anime-sharing.com/search/*
// @match        https://anime-sharing.com/search/*
// @grant        none
// @run-at       document-idle
// ==/UserScript==

(function () {
  'use strict';

  const LIST_SEL = 'ol.block-body';
  const ROW_SEL = 'li.block-row';
  const MAX_EXTRA_PAGES = 5;      // 「残りのページも読み込む」で追加取得する最大ページ数
  const PAGE_DELAY_MS = 1200;     // ページ取得の間隔（サイトに負荷をかけないため）

  // ---------- 解析 ----------
  // （ここから「表示」の印までは画面を触らない処理だけを置く。tests/ のテストがこの範囲を読み込んで試す）
  const PATCH_RE = /patch|translat|mtl|翻訳|パッチ|日本語化|english|eng\b/i;

  const VER_PREFIX = String.raw`(?:\bver(?:sion)?\.?\s*|\bv)`;
  const VER_NUM = String.raw`\d+(?:[._]\d+)*[a-z]?`;
  // Ver1.10 / v1.08 / Version 1.2.3、範囲なら v1.0→v1.2 / v1.10-1.20 / v1.0~1.2 / v1.0 to 1.2
  const VER_RE = new RegExp(
    `${VER_PREFIX}(${VER_NUM})(?:\\s*(?:->|→|-|~|～|to)\\s*v?(${VER_NUM}))?(?![\\w.])`, 'i');
  // 日付形式のバージョン：Ver26.11.08 / v26-11-08 / Ver2026.11.08 / v261108 / v20261108
  const DATE_VER_RE = new RegExp(
    `${VER_PREFIX}(?:(20\\d{2}|\\d{2})([._\\-/])(\\d{1,2})\\2(\\d{1,2})|(20\\d{2}|\\d{2})(\\d{2})(\\d{2}))(?![\\w.])`, 'i');

  const THIS_YEAR = new Date().getFullYear();

  // 年月日として妥当なら 'YYYY-MM-DD'、違えば null。
  // 2桁の年は月日も2桁のときだけ日付とみなす（v10.2.3 のような普通のバージョンを日付と取り違えないため）。
  function ymd(y, mo, d) {
    if (y.length === 2 && (mo.length !== 2 || d.length !== 2)) return null;
    const yy = y.length === 2 ? 2000 + Number(y) : Number(y);
    const m = Number(mo), dd = Number(d);
    if (yy < 2010 || yy > THIS_YEAR + 1 || m < 1 || m > 12 || dd < 1 || dd > 31) return null;
    return `${yy}-${String(m).padStart(2, '0')}-${String(dd).padStart(2, '0')}`;
  }

  // 戻り値: { version: '1.10' | null, dateVer: '2026-11-08' | null }
  function parseVersion(title) {
    let m = title.match(DATE_VER_RE);
    if (m) {
      const dv = m[1] ? ymd(m[1], m[3], m[4]) : ymd(m[5], m[6], m[7]);
      if (dv) return { version: null, dateVer: dv };
    }
    m = title.match(VER_RE);
    if (m) {
      const v1 = m[1].replace(/_/g, '.'), v2 = m[2] && m[2].replace(/_/g, '.');
      // 範囲表記（v1.0→1.2）なら後ろ側を採る。後ろの方が小さい v1.2-1 は枝番として 1.2.1 にする
      if (v2) return { version: cmpVersion(v2, v1) > 0 ? v2 : `${v1}.${v2}`, dateVer: null };
      return { version: v1, dateVer: null };
    }
    // [r102652] のようなリビジョン番号
    m = title.match(/\[r(\d{3,})\]/i);
    if (m) return { version: m[1], dateVer: null };
    return { version: null, dateVer: null };
  }

  function parseDates(title) {
    // 2023.02.14 / 2023-02-14 / [230214] (230214) / [23.02.14] (23.02.14)
    const out = [];
    const add = s => { if (s && !out.includes(s)) out.push(s); };
    for (const m of title.matchAll(/(?<![\d.])(20\d{2})[.\-/](\d{1,2})[.\-/](\d{1,2})(?![\d.])/g)) add(ymd(m[1], m[2], m[3]));
    for (const m of title.matchAll(/[\[(](\d{2})(\d{2})(\d{2})[\])]/g)) add(ymd(m[1], m[2], m[3]));
    for (const m of title.matchAll(/[\[(](\d{2})([.\-/])(\d{2})\2(\d{2})[\])]/g)) add(ymd(m[1], m[3], m[4]));
    return out.sort();
  }

  function parseCode(title) {
    // 「[RJ012345...」のように途中で切れたものは別のコードに見えるので読まない（切れたものは codeOf で扱う）
    const m = title.match(/\b(RJ|VJ|BJ|RE)(\d{6,8})\b(?!\.\.\.|…)/i);
    return m ? (m[1] + m[2]).toUpperCase() : null;
  }

  // 作品コードを決める。タイトルになければスレッドのURL（/threads/rj01234567-… のような部分）、
  // それでもなければ「… [RJ012345...」と途中で切れたタイトルを、ほかの結果や検索語のコード（known）と照らす。
  // タイトルだけで決めると、同じ作品のスレッドが別の作品として分かれてしまうため
  function codeOf(title, href = '', known = []) {
    return parseCode(title) || parseCode(href) || known.find(c => cutCode(title, c)) || null;
  }

  function baseTitle(title) {
    return title
      .replace(/\[[^\]]*\]|\([^)]*\)|【[^】]*】/g, ' ')
      .replace(/(?:\bver(?:sion)?\.?\s*|\bv)\d+(?:[._\-/]\d+)*[a-z]?/gi, ' ')
      .replace(/\+.*$/, ' ')
      .replace(/\b(english|translation|translated|patch|mtl|released|ai|all|save|own bought)\b/gi, ' ')
      .replace(/[*~～\-:：!！?？、。.,]/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
      .toLowerCase();
  }

  function cmpVersion(a, b) {
    if (a === b) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    const pa = a.split('.'), pb = b.split('.');
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
      const x = pa[i] ?? '0', y = pb[i] ?? '0';
      const nx = parseInt(x, 10), ny = parseInt(y, 10);
      if (nx !== ny) return nx - ny;
      if (x !== y) return x < y ? -1 : 1;
    }
    return 0;
  }

  function analyze(li) {
    if (li.dataset.apfDone) return li._apf;
    const a = li.querySelector('.contentRow-title a');
    if (!a) return null;
    const title = a.textContent.replace(/\s+/g, ' ').trim();
    const time = li.querySelector('time[data-timestamp]');
    const tags = [...li.querySelectorAll('.tagItem')].map(t => t.textContent.trim()).join(' ');
    const pv = parseVersion(title);
    const dates = parseDates(title);
    if (pv.dateVer) dates.push(pv.dateVer), dates.sort();
    const info = {
      li,
      title,
      version: pv.version,
      dateVer: pv.dateVer,
      dates,
      href: a.getAttribute('href') || '',
      code: codeOf(title, a.getAttribute('href') || ''),
      posted: time ? Number(time.dataset.timestamp) : 0,
      isPatch: PATCH_RE.test(title) || PATCH_RE.test(tags),
      origIndex: Number(li.dataset.apfIndex ?? 0),
    };
    info.lastDate = info.dates[info.dates.length - 1] || null;
    info.group = info.code || baseTitle(title) || title;
    li._apf = info;
    li.dataset.apfDone = '1';
    return info;
  }

  // 版の情報の強さ：2 = バージョン番号あり、1 = 日付版、0 = どちらもなし
  const tier = r => (r.version ? 2 : r.dateVer ? 1 : 0);
  const cmpStr = (a, b) => (a === b ? 0 : a < b ? -1 : 1);

  // 新しさの比較。どの組み合わせでも同じ基準で比べるので、並び順で結果が変わらない。
  //   1. 版の情報の強さ（バージョン番号あり ＞ 日付版 ＞ なし）
  //   2. 同じ強さの中で：バージョン番号 または 日付版
  //   3. タイトル内の一番新しい日付（ないものは古い扱い）
  //   4. 投稿日
  function newer(a, b) {
    const t = tier(a) - tier(b);
    if (t) return t;
    if (a.version) {
      const v = cmpVersion(a.version, b.version);
      if (v) return v;
    } else if (a.dateVer) {
      const v = cmpStr(a.dateVer, b.dateVer);
      if (v) return v;
    }
    const d = cmpStr(a.lastDate || '', b.lastDate || '');
    if (d) return d;
    return a.posted - b.posted;
  }

  // 1位と2位を分けた基準（バッジに出す）
  function decidedBy(a, b) {
    if (!b) return '';
    if (tier(a) !== tier(b)) return tier(b) === 0 ? '版の表記の有無' : '版の表記の種類';
    if (a.version && cmpVersion(a.version, b.version)) return 'バージョン';
    if (a.dateVer && a.dateVer !== b.dateVer) return '日付版';
    if ((a.lastDate || '') !== (b.lastDate || '')) return 'タイトル日付';
    return '投稿日';
  }

  // 保存済みのスレッドに、タイトルから版の情報を付け直す（古いバージョンで保存した結果にも効くよう、表示のたびに計算する）
  function threadInfo(t) {
    const pv = parseVersion(t.title);
    const dates = parseDates(t.title);
    if (pv.dateVer && !dates.includes(pv.dateVer)) dates.push(pv.dateVer), dates.sort();
    return Object.assign({}, t, {
      version: pv.version, dateVer: pv.dateVer, lastDate: dates[dates.length - 1] || null,
      isPatch: PATCH_RE.test(t.title), isLatest: false,
    });
  }

  // 1作品分のスレッドを並べ、最新を決める。
  //   最新の候補はタイトルにコードがあるもの（1件もなければ、作品名で見つかったもの）。
  //   その中にパッチ/翻訳があれば、パッチ/翻訳だけで比べる。
  //   並び：最新 → コードあり → 作品名で見つかった → そのほか（それぞれ新しい順）
  function rankThreads(threads) {
    const list = threads.map(threadInfo);
    const withCode = list.filter(t => t.hasCode);
    const byTitle = withCode.length ? [] : list.filter(t => t.byTitle);
    const pool = withCode.length ? withCode : byTitle;
    const patches = pool.filter(t => t.isPatch);
    const cands = patches.length ? patches : pool;
    const sorted = [...cands].sort((a, b) => newer(b, a));
    const latest = sorted[0] || null;
    const info = { latest, basis: '', patchOnly: patches.length > 0, byTitle: byTitle.length > 0, count: cands.length };
    if (latest) latest.isLatest = true;
    if (latest && cands.length > 1) info.basis = decidedBy(latest, sorted[1]);
    list.sort((a, b) => (b.isLatest - a.isLatest) || (b.hasCode - a.hasCode) || (!!b.byTitle - !!a.byTitle) || newer(b, a));
    return { list, ...info };
  }

  // 前回と今回の検索結果を比べる。前回がない（初めて・エラーだった）ときは null。
  //   newCount: 前回なかったスレッドの数（URLで比べる）
  //   latestChanged: 最新のスレッドか、そのバージョンが変わったか
  const verLabel = t => (t ? (t.version ? 'v' + t.version : t.dateVer || '版不明') : '');
  function diffResults(prev, next) {
    if (!prev || prev.error) return null;
    const old = new Set(prev.threads.map(t => t.url));
    const newCount = next.filter(t => !old.has(t.url)).length;
    const a = rankThreads(prev.threads).latest, b = rankThreads(next).latest;
    const latestChanged = !!b && (!a || a.url !== b.url || verLabel(a) !== verLabel(b));
    if (!newCount && !latestChanged) return null;
    return { newCount, latestChanged, from: a ? verLabel(a) : '', to: verLabel(b) };
  }

  // まだ消していない前回の印（older）に、今回の違い（newer）を足す。
  // 印を見る前に検索し直しても、印が消えたり「新着」の数が減ったりしないように。
  function mergeChanges(older, newer) {
    if (!older) return newer || null;
    if (!newer) return older;
    return {
      newCount: older.newCount + newer.newCount,
      latestChanged: older.latestChanged || newer.latestChanged,
      from: older.latestChanged ? older.from : newer.from,
      to: newer.to,
    };
  }

  // 今の検索対象（queue）に入っていない作品のコード。検索結果か作品名が保存されているもの。
  // リストを入れ替えても前の結果は残るので、ブラウザの保存領域に溜まりすぎたときに消せるようにする
  function orphanCodes(results, queue, titles = {}) {
    const inQueue = new Set(queue);
    return [...new Set([...Object.keys(results), ...Object.keys(titles)])].filter(c => !inQueue.has(c));
  }

  // 長いタイトルは「… [RJ01...」のように途中で切れて表示されるので、切れた先頭部分が一致すれば同じ作品とみなす。
  // ただし「RJ01」だけでは最近の作品ほぼすべてに当てはまるので、RJ と数字6桁以上が残っているときだけにする
  function cutCode(title, code) {
    const m = title.match(/((?:RJ|VJ|BJ|RE)\d*)(?:\.\.\.|…)$/i);
    return !!m && m[1].length >= 8 && code.startsWith(m[1].toUpperCase());
  }

  // 作品名検索用のキーワード：【】[]() などの添え書きと記号を外し、長すぎれば前の方だけ使う
  function normTitle(s) {
    return String(s || '').normalize('NFKC').toLowerCase()
      .replace(/[\s!-/:-@[-`{-~、。・「」『』〜～！？―ー…♪☆★◆◇■□●○※]/g, '');
  }
  function titleKeyword(title) {
    let s = String(title || '').normalize('NFKC')
      .replace(/\s*[|｜]\s*DLsite.*$/i, '')
      .replace(/【[^】]*】|\[[^\]]*\]|\([^)]*\)|〔[^〕]*〕|《[^》]*》/g, ' ');
    // 「～副題～」「: 副題」「 - 副題」は外して、本題だけにする
    s = s.split(/[~〜～:：]|\s[-―]\s/).map(x => x.trim()).find(x => x.length >= 2) || '';
    s = s.replace(/[\s!！?？♪☆★◆◇■□●○※、。・「」『』]+/g, ' ').trim();
    // 長い題名は検索で当たりにくいので、空白で区切った最初の部分を、合わせて20文字くらいまで使う
    const words = s.split(' ').filter(Boolean);
    let out = '';
    for (const w of words) { if (out && (out + w).length > 20) break; out = out ? out + ' ' + w : w; }
    return out.length >= 2 ? out : '';
  }
  // 作品名検索で見つかったタイトルが、本当にその作品らしいか（キーワードの文字がそのまま入っているか）
  function titleMatches(threadTitle, keyword) {
    const k = normTitle(keyword);
    return k.length >= 2 && normTitle(threadTitle).includes(k);
  }

  // ---------- 表示 ----------
  const css = `
    .apf-bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:8px 10px;margin:0 0 10px;
      border:1px solid rgba(127,127,127,.35);border-radius:6px;font-size:13px}
    .apf-bar b{margin-right:4px}
    .apf-bar button,.apf-bar select{font:inherit;padding:3px 8px;border-radius:4px;cursor:pointer;
      border:1px solid rgba(127,127,127,.5);background:transparent;color:inherit}
    .apf-bar label{display:inline-flex;gap:4px;align-items:center;cursor:pointer}
    .apf-bar input[type=text]{font:inherit;padding:3px 6px;border-radius:4px;border:1px solid rgba(127,127,127,.5);
      background:transparent;color:inherit;min-width:160px}
    .apf-status{opacity:.75}
    .apf-badges{display:flex;flex-wrap:wrap;gap:4px;margin:4px 0 2px}
    .apf-b{font-size:11px;line-height:1.6;padding:0 6px;border-radius:3px;border:1px solid rgba(127,127,127,.45);white-space:nowrap}
    .apf-ver{background:#1d4ed8;color:#fff;border-color:#1d4ed8}
    .apf-nover{opacity:.7}
    .apf-latest{background:#15803d;color:#fff;border-color:#15803d;font-weight:bold}
    .apf-old{background:#9ca3af33}
    .apf-row-latest{box-shadow:inset 4px 0 0 #16a34a}
    .apf-dim{opacity:.35}
    .apf-hidden{display:none !important}
    .apf-group-head{list-style:none;padding:6px 10px;font-size:12px;font-weight:bold;
      border-top:2px solid rgba(127,127,127,.4);background:rgba(127,127,127,.08)}
  `;

  let styled = false;
  function addStyle() {
    if (styled) return;
    styled = true;
    const s = document.createElement('style');
    s.textContent = css;
    document.head.appendChild(s);
  }

  function badge(text, cls) {
    const span = document.createElement('span');
    span.className = 'apf-b ' + (cls || '');
    span.textContent = text;
    return span;
  }

  function fmtDate(ts) {
    if (!ts) return '';
    const d = new Date(ts * 1000);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }

  function renderBadges(info, groupSize, isLatest, basis, latest) {
    info.li.querySelector('.apf-badges')?.remove();
    const box = document.createElement('div');
    box.className = 'apf-badges';
    if (groupSize > 1) {
      if (isLatest) box.appendChild(badge(`★ 最新（${groupSize}件中・${basis}で判定）`, 'apf-latest'));
      else if (tier(info) < tier(latest)) box.appendChild(badge('版不明（最新と比べられない）', 'apf-old'));
      else box.appendChild(badge('旧版', 'apf-old'));
    }
    if (info.version) box.appendChild(badge('v' + info.version, 'apf-ver'));
    else if (info.dateVer) box.appendChild(badge('日付版 ' + info.dateVer, 'apf-ver'));
    else box.appendChild(badge('バージョン表記なし', 'apf-nover'));
    if (info.lastDate) box.appendChild(badge('タイトル日付 ' + info.lastDate));
    if (info.posted) box.appendChild(badge('投稿 ' + fmtDate(info.posted)));
    if (info.code) box.appendChild(badge(info.code));
    if (info.isPatch) box.appendChild(badge('パッチ/翻訳'));
    info.li.classList.toggle('apf-row-latest', groupSize > 1 && isLatest);
    info.li.querySelector('.contentRow-title').after(box);
  }

  // ---------- メイン ----------
  let list, rows = [], state;
  try { state = JSON.parse(localStorage.getItem('apf-state')) || {}; } catch { state = {}; }
  state = Object.assign({ sort: 'group', dim: true, hideOld: false, filter: '' }, state);
  const save = () => { try { localStorage.setItem('apf-state', JSON.stringify(state)); } catch {} };

  // 検索語に入っている作品コード（RJ番号で検索したときなど）
  function queryCodes() {
    const p = new URLSearchParams(location.search);
    const q = [p.get('q'), p.get('keywords'), document.querySelector('input[name=keywords]')?.value].filter(Boolean).join(' ');
    return (q.match(/\b(?:RJ|VJ|BJ|RE)\d{6,8}\b/gi) || []).map(c => c.toUpperCase());
  }

  function collect() {
    rows = [...list.querySelectorAll(ROW_SEL)].map((li, i) => {
      if (li.dataset.apfIndex == null) li.dataset.apfIndex = String(i);
      return analyze(li);
    }).filter(Boolean);
    // 途中で切れたタイトルは、ほかの結果や検索語のコードと照らして同じ作品にまとめる
    const known = [...new Set([...queryCodes(), ...rows.map(r => r.code).filter(Boolean)])];
    for (const r of rows) {
      if (r.code) continue;
      const c = codeOf(r.title, r.href, known);
      if (c) { r.code = c; r.group = c; }
    }
  }

  function refresh() {
    // グループごとに最新を判定
    const groups = new Map();
    for (const r of rows) {
      if (!groups.has(r.group)) groups.set(r.group, []);
      groups.get(r.group).push(r);
    }
    for (const g of groups.values()) {
      g.sort((a, b) => newer(b, a));
      const basis = decidedBy(g[0], g[1]);
      g.forEach((r, i) => { r.isLatest = i === 0; r.groupSize = g.length; renderBadges(r, g.length, i === 0, basis, g[0]); });
    }

    // 並べ替え
    list.querySelectorAll('.apf-group-head').forEach(e => e.remove());
    let ordered;
    if (state.sort === 'group') {
      // 作品グループ同士は「グループ内で一番新しい投稿日」順（別作品のバージョン番号は比べられないため）
      const lastPost = g => Math.max(...g.map(r => r.posted));
      const gs = [...groups.values()].sort((a, b) => lastPost(b) - lastPost(a));
      ordered = [];
      for (const g of gs) {
        if (g.length > 1) {
          const head = document.createElement('li');
          head.className = 'apf-group-head';
          head.textContent = `▼ ${g[0].code || g[0].title.slice(0, 60)}　— ${g.length}件`;
          head._apfGroup = g;
          ordered.push(head);
        }
        ordered.push(...g.map(r => r.li));
      }
    } else if (state.sort === 'version') {
      ordered = [...rows].sort((a, b) => newer(b, a)).map(r => r.li);
    } else if (state.sort === 'posted') {
      ordered = [...rows].sort((a, b) => b.posted - a.posted).map(r => r.li);
    } else {
      ordered = [...rows].sort((a, b) => a.origIndex - b.origIndex).map(r => r.li);
    }
    for (const el of ordered) list.appendChild(el);

    // 絞り込み・薄く表示
    const q = state.filter.trim().toLowerCase();
    let shown = 0;
    for (const r of rows) {
      const hit = !q || r.title.toLowerCase().includes(q);
      const hide = !hit || (state.hideOld && r.groupSize > 1 && !r.isLatest);
      r.li.classList.toggle('apf-hidden', hide);
      r.li.classList.toggle('apf-dim', !hide && state.dim && !r.isPatch);
      if (!hide) shown++;
    }
    list.querySelectorAll('.apf-group-head').forEach(h => {
      h.classList.toggle('apf-hidden', h._apfGroup.every(r => r.li.classList.contains('apf-hidden')));
    });
    status(`${rows.length}件中 ${shown}件を表示 ／ 作品グループ ${groups.size}`);
  }

  let statusEl;
  const status = t => { if (statusEl) statusEl.textContent = t; };

  function nextPageUrl(doc) {
    const a = doc.querySelector('.pageNav-jump--next');
    return a ? new URL(a.getAttribute('href'), location.origin).href : null;
  }

  async function loadMore(btn) {
    btn.disabled = true;
    let url = nextPageUrl(document);
    let n = 0;
    while (url && n < MAX_EXTRA_PAGES) {
      status(`ページを読み込み中…（${n + 1}/${MAX_EXTRA_PAGES}）`);
      try {
        const res = await fetch(url, { credentials: 'same-origin' });
        if (!res.ok) throw new Error(res.status);
        const doc = new DOMParser().parseFromString(await res.text(), 'text/html');
        const base = rows.length;
        doc.querySelectorAll(`${LIST_SEL} > ${ROW_SEL}`).forEach((li, i) => {
          li.dataset.apfIndex = String(base + i);
          list.appendChild(document.adoptNode(li));
        });
        url = nextPageUrl(doc);
      } catch (e) {
        status('読み込みに失敗しました: ' + e.message);
        break;
      }
      n++;
      collect();
      refresh();
      if (url && n < MAX_EXTRA_PAGES) await new Promise(r => setTimeout(r, PAGE_DELAY_MS));
    }
    document.querySelectorAll('.pageNav').forEach(p => (p.style.opacity = '.4'));
    btn.textContent = url ? `さらに読み込む（あと最大${MAX_EXTRA_PAGES}ページ）` : '全ページ読み込み済み';
    btn.disabled = !url;
  }

  function buildBar() {
    const bar = document.createElement('div');
    bar.className = 'apf-bar';
    bar.innerHTML = `
      <b>パッチ整理</b>
      <label>並び順
        <select data-k="sort">
          <option value="group">作品ごと（最新を上に）</option>
          <option value="version">バージョンが新しい順</option>
          <option value="posted">投稿が新しい順</option>
          <option value="orig">元の順番</option>
        </select>
      </label>
      <label><input type="checkbox" data-k="dim"> パッチ以外を薄く</label>
      <label><input type="checkbox" data-k="hideOld"> 旧版を隠す</label>
      <input type="text" data-k="filter" placeholder="タイトル内を絞り込み">
      <button type="button" data-act="more">残りのページも読み込む</button>
      <span class="apf-status"></span>`;
    statusEl = bar.querySelector('.apf-status');
    bar.querySelector('[data-k=sort]').value = state.sort;
    bar.querySelector('[data-k=dim]').checked = state.dim;
    bar.querySelector('[data-k=hideOld]').checked = state.hideOld;
    bar.querySelector('[data-k=filter]').value = state.filter;
    bar.addEventListener('input', e => {
      const k = e.target.dataset.k;
      if (!k) return;
      state[k] = e.target.type === 'checkbox' ? e.target.checked : e.target.value;
      if (k !== 'filter') save();
      refresh();
    });
    const more = bar.querySelector('[data-act=more]');
    if (!nextPageUrl(document)) { more.textContent = '全ページ表示中'; more.disabled = true; }
    more.addEventListener('click', () => loadMore(more));
    return bar;
  }

  function init() {
    list = document.querySelector(LIST_SEL);
    if (!list || !list.querySelector(ROW_SEL)) return;
    addStyle();
    state.filter = '';
    list.closest('.block').before(buildBar());
    collect();
    refresh();
  }

  init();

  // =====================================================================
  // 自動検索：作品コード（RJ番号など）を1件ずつ検索して、見つかったスレッドのURLを集める
  //   開き方: https://www.anime-sharing.com/search/#apf-auto            … パネルだけ開く
  //           https://www.anime-sharing.com/search/#apf-auto=RJ01,RJ02 … このリストで検索対象を置き換えて開く
  //   （# より後ろはサーバーに送られないので、リストそのものがASに渡ることはありません）
  // =====================================================================
  const AUTO_KEY = 'apf-auto';
  const LOCK_KEY = 'apf-auto-lock';
  const CODE_RE_G = /\b(?:RJ|VJ|BJ|RE)\d{6,8}\b/gi;
  const MAX_RESULT_PAGES = 3;      // 1作品あたり見る検索結果のページ数
  const tabId = Math.random().toString(36).slice(2);

  let auto = loadAuto();
  let running = false, stopReq = false, panel = null, panelView = 'found', lockTimer = null;

  function loadAuto() {
    let a;
    try { a = JSON.parse(localStorage.getItem(AUTO_KEY)); } catch { a = null; }
    // titles: { 作品コード: 作品名 }（作品名検索に使う。貼り付けで読み込む）
    return Object.assign({ queue: [], results: {}, titles: {}, useTitles: true, interval: 8, staleDays: 30 }, a || {});
  }
  function saveAuto() {
    try { localStorage.setItem(AUTO_KEY, JSON.stringify(auto)); }
    catch (e) { autoMsg('保存に失敗しました（ブラウザの保存容量がいっぱいかもしれません）: ' + e.message); }
  }

  // 裏のタブでも止まりにくい待ち時間（ブラウザは裏タブの setTimeout を1分おきまで遅らせることがあるため Worker を使う）
  let sleepWorker = null, sleepSeq = 0;
  const sleepWaits = new Map();
  try {
    sleepWorker = new Worker(URL.createObjectURL(new Blob(
      ['onmessage=e=>setTimeout(()=>postMessage(e.data.id),e.data.ms)'], { type: 'text/javascript' })));
    sleepWorker.onmessage = e => { sleepWaits.get(e.data)?.(); sleepWaits.delete(e.data); };
  } catch { sleepWorker = null; }
  function sleep(ms) {
    return new Promise(res => {
      if (!sleepWorker) return setTimeout(res, ms);
      const id = ++sleepSeq;
      sleepWaits.set(id, res);
      sleepWorker.postMessage({ id, ms });
    });
  }
  // 止めるボタンにすぐ反応できるよう、1秒ずつ待つ
  async function wait(ms, label) {
    const end = Date.now() + ms;
    while (!stopReq && Date.now() < end) {
      if (label) autoMsg(`${label}（あと${Math.ceil((end - Date.now()) / 1000)}秒）`);
      await sleep(Math.min(1000, end - Date.now()));
    }
  }

  // 同じ検索を2つのタブで同時に走らせない
  function lockHeldByOther() {
    try {
      const l = JSON.parse(localStorage.getItem(LOCK_KEY));
      return l && l.id !== tabId && Date.now() - l.ts < 20000;
    } catch { return false; }
  }
  function takeLock() {
    const beat = () => { try { localStorage.setItem(LOCK_KEY, JSON.stringify({ id: tabId, ts: Date.now() })); } catch {} };
    beat();
    lockTimer = setInterval(beat, 5000);
  }
  function releaseLock() {
    clearInterval(lockTimer);
    try { if (JSON.parse(localStorage.getItem(LOCK_KEY))?.id === tabId) localStorage.removeItem(LOCK_KEY); } catch {}
  }

  function isFresh(code) {
    const r = auto.results[code];
    if (!r || r.error || Date.now() - r.at >= auto.staleDays * 86400000) return false;
    // RJ番号で見つからず、あとから作品名が読み込まれた作品は、作品名で探し直す
    if (auto.useTitles && !r.keyword && !r.threads.some(t => t.hasCode) && titleKeyword(auto.titles[code])) return false;
    return true;
  }
  const pending = () => auto.queue.filter(c => !isFresh(c));

  // ---- 1件分の検索 ----
  class Flood extends Error { constructor(sec) { super('flood'); this.sec = sec; } }

  async function fetchDoc(url) {
    const res = await fetch(url, { credentials: 'same-origin' });
    if (res.status === 429 || res.status === 503) throw new Flood(300);
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const doc = new DOMParser().parseFromString(await res.text(), 'text/html');
    // 「〇秒待ってください」はエラー表示の枠に出る（検索結果の本文に同じ文があっても反応しないように枠だけ見る）
    const notice = [...doc.querySelectorAll('.blockMessage, .overlay-content')].map(e => e.textContent).join(' ');
    const m = notice.match(/wait at least (\d+) seconds?/i);
    if (m) throw new Flood(Number(m[1]));
    return doc;
  }

  function parseResultRows(doc, code, into) {
    for (const li of doc.querySelectorAll(`${LIST_SEL} > ${ROW_SEL}`)) {
      const a = li.querySelector('.contentRow-title a');
      const href = a?.getAttribute('href') || '';
      const m = href.match(/^(\/threads\/[^/]*?\.?(\d+))\//);
      if (!m) continue;                                     // プロフィール投稿などは対象外
      const id = m[2];
      const title = (li.querySelector('a.thread-thumbnail-link')?.title || a.textContent).replace(/\s+/g, ' ').trim();
      const minor = [...li.querySelectorAll('.contentRow-minor li')].map(x => x.textContent.trim());
      const kind = minor.some(t => t === 'Thread') ? 'thread' : 'post';
      const time = li.querySelector('time[data-timestamp]');
      const forum = li.querySelector('.contentRow-minor a[href^="/forums/"]')?.textContent.trim() || '';
      const cur = into.get(id);
      const t = {
        url: location.origin + m[1] + '/',
        title,
        kind,
        forum,
        posted: kind === 'thread' && time ? Number(time.dataset.timestamp) : (cur?.posted || 0),
        hasCode: title.toUpperCase().includes(code) || href.toUpperCase().includes(code) || cutCode(title, code),
      };
      if (!cur) into.set(id, t);
      else {
        if (kind === 'thread') Object.assign(cur, { kind, posted: t.posted || cur.posted });
        cur.hasCode = cur.hasCode || t.hasCode;
        if (title.length > cur.title.length) cur.title = title;
      }
    }
  }

  async function searchCode(code) {
    const threads = new Map();
    let url = `${location.origin}/search/search?keywords=${encodeURIComponent(code)}`;
    for (let p = 0; url && p < MAX_RESULT_PAGES; p++) {
      if (p) await sleep(2000);
      const doc = await fetchDoc(url);
      parseResultRows(doc, code, threads);
      url = nextPageUrl(doc);
    }
    return [...threads.values()];
  }

  // 作品名で検索（スレッドのタイトルだけを対象に、1ページ目だけ）。すでに見つかっているURLは除く。
  async function searchTitle(keyword, code, known) {
    const found = new Map();
    const doc = await fetchDoc(`${location.origin}/search/search?keywords=${encodeURIComponent(keyword)}&c[title_only]=1`);
    parseResultRows(doc, code, found);
    const have = new Set(known.map(t => t.url));
    return [...found.values()]
      .filter(t => !have.has(t.url) && titleMatches(t.title, keyword))
      .map(t => Object.assign(t, { byTitle: true }));
  }

  function latestBadge(rk) {
    const scope = (rk.byTitle ? '作品名で見つかった' : '') + (rk.patchOnly ? 'パッチ/翻訳' : rk.byTitle ? 'スレッド' : 'コードあり');
    return rk.count > 1
      ? badge(`★ 最新（${scope}${rk.count}件中・${rk.basis}で判定）`, 'apf-latest')
      : badge(`★ 最新（${scope}はこの1件だけ）`, 'apf-latest');
  }

  async function runAuto() {
    if (running) return;
    if (lockHeldByOther()) { autoMsg('別のタブで検索中です。そちらを止めるか閉じてから開始してください。'); return; }
    running = true; stopReq = false;
    takeLock();
    renderPanel();
    let floods = 0;
    // 今回すでに試した作品。日数が0のときや、エラーが続く作品があっても、同じ作品に戻らず先へ進むため
    const tried = new Set();
    const nextCode = () => pending().find(c => !tried.has(c));
    try {
      while (!stopReq) {
        const code = nextCode();
        if (!code) {
          const errors = auto.queue.filter(c => auto.results[c]?.error).length;
          autoMsg(errors ? `すべて検索しました（エラー ${errors}件。「開始」でもう一度試せます）。` : 'すべて検索しました。');
          break;
        }
        autoMsg(`${code} を検索中…`);
        const prev = auto.results[code];
        try {
          const threads = await searchCode(code);
          // RJ番号の入ったスレッドが無ければ、作品名でも探す
          const kw = auto.useTitles && !threads.some(t => t.hasCode) ? titleKeyword(auto.titles[code]) : '';
          if (kw) {
            await wait(auto.interval * 1000, '作品名でも検索するまで待機中');
            if (stopReq) break;          // 途中で止めたら、この作品は次回やり直す
            autoMsg(`${code} を作品名でも検索中…`);
            threads.push(...await searchTitle(kw, code, threads));
          }
          const changes = mergeChanges(prev?.changes, diffResults(prev, threads));
          auto.results[code] = Object.assign({ at: Date.now(), threads }, kw ? { keyword: kw } : {}, changes ? { changes } : {});
          floods = 0;
        } catch (e) {
          if (e instanceof Flood) {
            floods++;
            // 待つ時間は言われた秒数より少し長めに。続けて言われたら間隔も広げる
            if (floods >= 2) auto.interval = Math.min(60, auto.interval + 4);
            saveAuto();
            await wait((e.sec + 5) * 1000 * floods, '検索が多すぎるとASに言われたので待っています');
            continue;
          }
          // エラーでも、まだ消していない新着・更新の印は残す
          auto.results[code] = Object.assign({ at: Date.now(), threads: [], error: String(e.message || e) },
            prev?.changes ? { changes: prev.changes } : {});
          if (/HTTP 40[13]/.test(auto.results[code].error)) {
            saveAuto();
            autoMsg('ASに断られました（' + auto.results[code].error + '）。このページを開き直して、普通に見られるか確かめてから再開してください。');
            break;
          }
        }
        tried.add(code);   // 「多すぎる」で待った作品はここに来ないので、もう一度検索される
        saveAuto();
        refreshPanel();
        if (nextCode()) await wait(auto.interval * 1000, '次の検索まで待機中');
      }
    } finally {
      running = false;
      releaseLock();
      if (stopReq) autoMsg('一時停止しました。「開始」で続きから再開します。');
      renderPanel();
    }
  }

  // ---- 書き出し ----
  const changeText = ch => [ch.newCount ? `新着${ch.newCount}件` : '', ch.latestChanged ? `最新が更新（${ch.from || 'なし'}→${ch.to}）` : '']
    .filter(Boolean).join(' ');

  // 列：作品コード・種類・見つけ方・最新・バージョン・パッチ/翻訳・新着/更新・URL・タイトル
  const TSV_HEAD = ['作品コード', '種類', '見つけ方', '最新', 'バージョン', 'パッチ/翻訳', '新着/更新', 'URL', 'タイトル'];
  function exportRows(onlyFound, onlyLatest) {
    const lines = [];
    const blank = (c, what) => [c, what, '', '', '', '', '', '', ''];
    for (const c of auto.queue) {
      const r = auto.results[c];
      if (!r) { if (!onlyFound) lines.push(blank(c, '未検索')); continue; }
      if (!r.threads.length) { if (!onlyFound) lines.push(blank(c, r.error ? 'エラー' : 'なし')); continue; }
      const ch = r.changes ? changeText(r.changes) : '';
      for (const t of rankThreads(r.threads).list) {
        if (onlyLatest && !t.isLatest) continue;
        lines.push([c, t.kind === 'thread' ? 'スレッド' : '投稿内',
          t.hasCode ? 'コード' : t.byTitle ? '作品名' : 'そのほか', t.isLatest ? '★' : '',
          t.version ? 'v' + t.version : t.dateVer || '', t.isPatch ? '○' : '', t.isLatest ? ch : '', t.url, t.title]);
      }
    }
    return lines;
  }
  async function copyUrls(onlyLatest) {
    const lines = exportRows(true, onlyLatest).map(l => `${l[0]}\t${l[7]}\t${l[8]}`);
    try {
      await navigator.clipboard.writeText(lines.join('\n'));
      autoMsg(`${onlyLatest ? '最新の' : ''}URLを${lines.length}件コピーしました（RJ番号・URL・タイトルのタブ区切り）。`);
    } catch (e) { autoMsg('コピーに失敗しました: ' + e.message); }
  }
  function saveTsv() {
    const rows = [TSV_HEAD, ...exportRows(false)];
    const tsv = rows.map(r => r.map(x => String(x).replace(/[\t\r\n]+/g, ' ')).join('\t')).join('\r\n');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob(['\uFEFF' + tsv], { type: 'text/tab-separated-values' }));
    const d = new Date();
    a.download = `as-search-${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}.tsv`;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 5000);
  }

  // ---- 画面 ----
  const autoCss = `
    .apf-auto{margin:0 0 14px;padding:10px 12px;border:1px solid rgba(127,127,127,.4);border-radius:6px;font-size:13px}
    .apf-auto h3{margin:0 0 6px;font-size:15px}
    .apf-auto .apf-row{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:6px 0}
    .apf-auto button,.apf-auto select,.apf-auto input{font:inherit;padding:3px 8px;border-radius:4px;
      border:1px solid rgba(127,127,127,.5);background:transparent;color:inherit}
    .apf-auto button{cursor:pointer}
    .apf-auto button.apf-primary{background:#15803d;color:#fff;border-color:#15803d;font-weight:bold}
    .apf-auto input[type=number]{width:4.5em}
    .apf-auto textarea{width:100%;min-height:90px;font:12px monospace;box-sizing:border-box;
      background:transparent;color:inherit;border:1px solid rgba(127,127,127,.5);border-radius:4px}
    .apf-auto .apf-prog{height:6px;border-radius:3px;background:rgba(127,127,127,.25);overflow:hidden}
    .apf-auto .apf-prog > div{height:100%;background:#16a34a}
    .apf-auto table{border-collapse:collapse;width:100%;margin-top:6px}
    .apf-auto td,.apf-auto th{border-top:1px solid rgba(127,127,127,.25);padding:4px 6px;vertical-align:top;text-align:left}
    .apf-auto td.apf-code{white-space:nowrap;font-family:monospace}
    .apf-auto .apf-t{margin:1px 0}
    .apf-auto .apf-t a{word-break:break-all}
    .apf-auto .apf-weak{opacity:.6}
    .apf-auto .apf-msg{opacity:.85}
    .apf-auto .apf-new{background:#c2410c;color:#fff;border-color:#c2410c;font-weight:bold;white-space:normal}
  `;

  function el(tag, attrs, ...kids) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (k === 'class') e.className = v;
      else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
      else if (v != null) e.setAttribute(k, v);
    }
    for (const k of kids.flat()) if (k != null) e.append(k);
    return e;
  }

  function dlsiteUrl(code) {
    const site = code.startsWith('VJ') ? 'pro' : code.startsWith('BJ') ? 'books' : 'maniax';
    return `https://www.dlsite.com/${site}/work/=/product_id/${code}.html`;
  }

  let msgText = '';
  function autoMsg(t) {
    msgText = t;
    const m = panel?.querySelector('.apf-msg');
    if (m) m.textContent = t;
  }

  // 件数の集計（パネルの見出しと、検索中の部分更新で使う）
  function panelStats() {
    const total = auto.queue.length;
    const left = pending().length;
    return {
      total, left, done: total - left,
      found: auto.queue.filter(c => auto.results[c]?.threads.length).length,
      urls: auto.queue.reduce((n, c) => n + (auto.results[c]?.threads.length || 0), 0),
      errors: auto.queue.filter(c => auto.results[c]?.error).length,
      changed: auto.queue.filter(c => auto.results[c]?.changes).length,
      etaMin: Math.ceil(left * (auto.interval + 1.5) / 60),
    };
  }
  const summaryText = s =>
    `対象 ${s.total}件 ／ 検索済み ${s.done}件 ／ 見つかった作品 ${s.found}件（スレッド ${s.urls}件）` +
    (s.changed ? ` ／ 新着・更新あり ${s.changed}件` : '') +
    (s.errors ? ` ／ エラー ${s.errors}件` : '') + (s.left ? ` ／ 残り ${s.left}件（約${s.etaMin}分）` : '');
  const progWidth = s => `${s.total ? (s.done / s.total) * 100 : 0}%`;

  // 検索中は、件数・進み具合・結果の表だけを差し替える。
  // パネル全体を作り直すと、開いていた貼り付け欄が閉じたり、入力中の欄からフォーカスが外れたりするため
  function refreshPanel() {
    const sum = panel?.querySelector('.apf-sum');
    if (!sum) { renderPanel(); return; }
    const s = panelStats();
    sum.textContent = summaryText(s);
    panel.querySelector('.apf-prog > div').style.width = progWidth(s);
    panel.querySelector('.apf-res').replaceChildren(resultTable());
  }

  // 貼り付け欄の開閉と、入力中の文字（パネルを作り直しても消えないように覚えておく）
  let pasteOpen = false, pasteText = '';

  function renderPanel() {
    if (!panel) return;
    const s = panelStats();
    const { total, left, done, changed } = s;
    const titleCount = auto.queue.filter(c => auto.titles[c]).length;
    const orphans = orphanCodes(auto.results, auto.queue, auto.titles);

    const startBtn = running
      ? el('button', { type: 'button', onclick: () => { stopReq = true; autoMsg('止めています…'); } }, '一時停止')
      : el('button', { type: 'button', class: 'apf-primary', onclick: runAuto, ...(left ? {} : { disabled: '' }) },
          done ? '続きから開始' : '開始');

    const num = (key, min, max, label, unit) => el('label', {}, label + ' ',
      el('input', { type: 'number', min, max, value: auto[key], oninput: e => {
        const v = Number(e.target.value);
        if (v >= min && v <= max) { auto[key] = v; saveAuto(); }
      } }), unit);

    const ta = el('textarea', { oninput: e => { pasteText = e.target.value; } });
    ta.value = pasteText;
    const paste = el('div', { style: pasteOpen ? '' : 'display:none' },
      el('div', {}, 'RJ番号を貼り付けてください（ほかの文字が混ざっていてもOK）。検索対象がこのリストに置き換わります。前回までの検索結果は残ります。' +
        '「RJ番号 [タブ] 作品名」の行なら作品名も読み込み、RJ番号で見つからないときに作品名でも検索します（所持チェックの「ASで検索」がこの形でコピーします）。'),
      ta,
      el('div', { class: 'apf-row' },
        el('button', { type: 'button', onclick: () => {
          const text = ta.value;
          const codes = importCodes(text);
          if (!codes.length) { autoMsg('RJ番号が見つかりませんでした。'); return; }
          if (running) { autoMsg('止めてから入れ替えてください。'); return; }
          const titles = importTitles(text);
          Object.assign(auto.titles, titles);
          pasteOpen = false; pasteText = '';
          setQueue(codes);
          const n = Object.keys(titles).length;
          if (n) autoMsg(`${msgText}（作品名 ${n}件も読み込みました）`);
        } }, 'このリストにする')));

    const view = el('select', { onchange: e => { panelView = e.target.value; renderPanel(); } },
      ...[['found', '見つかった作品'], ['changed', '新着・更新あり'], ['none', '見つからなかった作品'], ['todo', 'まだの作品'], ['all', 'すべて']]
        .map(([v, t]) => el('option', { value: v, ...(panelView === v ? { selected: '' } : {}) }, t)));

    panel.replaceChildren(
      el('h3', {}, '自動検索（作品コードで順番に検索）'),
      el('div', { class: 'apf-row apf-sum' }, summaryText(s)),
      el('div', { class: 'apf-prog' }, el('div', { style: `width:${progWidth(s)}` })),
      el('div', { class: 'apf-row' },
        startBtn,
        num('interval', 3, 60, '間隔', '秒'),
        num('staleDays', 0, 365, '', '日以内に検索した作品は飛ばす'),
        el('button', { type: 'button', onclick: () => { pasteOpen = !pasteOpen; paste.style.display = pasteOpen ? '' : 'none'; } }, 'RJ番号を貼り付け…')),
      el('div', { class: 'apf-row' },
        el('label', {},
          el('input', { type: 'checkbox', ...(auto.useTitles ? { checked: '' } : {}),
            onchange: e => { auto.useTitles = e.target.checked; saveAuto(); } }),
          ` RJ番号で見つからないときは作品名でも検索する（作品名 ${titleCount}/${total}件 読み込み済み）`)),
      paste,
      el('div', { class: 'apf-row' },
        el('button', { type: 'button', onclick: () => copyUrls(true) }, '最新のURLだけコピー'),
        el('button', { type: 'button', onclick: () => copyUrls(false) }, '見つかったURLをすべてコピー'),
        el('button', { type: 'button', onclick: saveTsv }, 'ファイルに保存（TSV）'),
        el('button', { type: 'button', onclick: () => {
          if (running) { autoMsg('止めてから押してください。'); return; }
          if (!confirm('検索結果をすべて消して、最初から検索し直せるようにします。よろしいですか？')) return;
          auto.results = {}; saveAuto(); renderPanel();
        } }, '結果を消す'),
        changed ? el('button', { type: 'button', onclick: () => {
          for (const c of auto.queue) if (auto.results[c]) delete auto.results[c].changes;
          saveAuto(); renderPanel();
        } }, '新着・更新の印を消す') : null,
        orphans.length ? el('button', { type: 'button', onclick: () => {
          if (running) { autoMsg('止めてから押してください。'); return; }
          if (!confirm(`今の検索対象に入っていない ${orphans.length}件の検索結果と作品名を消します。よろしいですか？`)) return;
          for (const c of orphans) { delete auto.results[c]; delete auto.titles[c]; }
          saveAuto(); autoMsg(`${orphans.length}件の古い結果を消しました。`); renderPanel();
        } }, `今のリストにない作品の結果を消す（${orphans.length}件）`) : null,
        el('label', {}, '表示 ', view)),
      el('div', { class: 'apf-msg' }, msgText),
      el('div', { class: 'apf-res' }, resultTable()));
  }

  function resultTable() {
    const rows = [];
    for (const c of auto.queue) {
      const r = auto.results[c];
      const has = r?.threads.length > 0;
      if (panelView === 'found' && !has) continue;
      if (panelView === 'changed' && !r?.changes) continue;
      if (panelView === 'none' && (!r || has)) continue;
      if (panelView === 'todo' && r && !r.error) continue;
      const rk = has ? rankThreads(r.threads) : null;
      const cell = !r ? el('span', { class: 'apf-weak' }, 'まだ')
        : r.error ? el('span', {}, 'エラー: ' + r.error)
        : !has ? el('span', { class: 'apf-weak' }, 'なし')
        : rk.list.map(t => el('div', { class: 'apf-t' + (t.hasCode || t.byTitle ? '' : ' apf-weak') },
            t.isLatest ? latestBadge(rk) : null, t.isLatest ? ' ' : null,
            t.byTitle ? badge('作品名で見つかった（要確認）') : null, t.byTitle ? ' ' : null,
            el('a', { href: t.url, target: '_blank', rel: 'noopener' }, t.title), ' ',
            t.version ? badge('v' + t.version, 'apf-ver') : t.dateVer ? badge('日付版 ' + t.dateVer, 'apf-ver') : null, ' ',
            t.isPatch ? badge('パッチ/翻訳') : null, ' ',
            badge(t.kind === 'thread' ? 'スレッド' : '投稿内で言及'), ' ',
            t.posted ? badge(fmtDate(t.posted)) : null, ' ',
            t.forum ? badge(t.forum) : null));
      rows.push(el('tr', {},
        el('td', { class: 'apf-code' },
          el('a', { href: dlsiteUrl(c), target: '_blank', rel: 'noopener noreferrer' }, c), el('br'),
          el('a', { href: `/search/search?keywords=${c}`, target: '_blank', class: 'apf-weak' }, 'ASで検索'),
          r ? el('div', { class: 'apf-weak' }, fmtDate(r.at / 1000)) : null,
          r?.changes ? el('div', {}, badge(changeText(r.changes), 'apf-new')) : null,
          r?.keyword ? el('div', { class: 'apf-weak' }, '作品名でも検索した') : null),
        el('td', {}, cell)));
    }
    if (!rows.length) return el('div', { class: 'apf-weak', style: 'margin-top:6px' }, '表示するものがありません。');
    return el('table', {}, el('tbody', {}, rows));
  }

  function importCodes(text) {
    return [...new Set((text.match(CODE_RE_G) || []).map(s => s.toUpperCase()))];
  }
  // 「RJ番号 [タブ] 作品名」の行から作品名を読む
  function importTitles(text) {
    const out = {};
    for (const line of text.split(/\r?\n/)) {
      const m = line.match(/^\s*((?:RJ|VJ|BJ|RE)\d{6,8})\t+(.+?)\s*$/i);
      if (m) out[m[1].toUpperCase()] = m[2];
    }
    return out;
  }
  function setQueue(codes) {
    if (running) { autoMsg('止めてから入れ替えてください。'); return; }
    auto.queue = codes;
    saveAuto();
    const left = pending().length;
    autoMsg(`${codes.length}件を読み込みました（そのうち検索が必要なのは ${left}件）。「開始」を押すと検索します。`);
    renderPanel();
  }

  function openPanel() {
    if (!panel) {
      const s = document.createElement('style');
      s.textContent = autoCss;
      document.head.appendChild(s);
      addStyle();   // バッジの見た目は整理機能と共用
      panel = el('div', { class: 'apf-auto' });
      const host = document.querySelector('.p-body-pageContent') || document.querySelector('.p-body-main') || document.body;
      host.prepend(panel);
    }
    const m = location.hash.match(/^#apf-auto=(.*)$/);
    if (m) {
      const codes = importCodes(decodeURIComponent(m[1]));
      history.replaceState(null, '', location.pathname + location.search + '#apf-auto');
      if (codes.length) { setQueue(codes); return; }
    }
    renderPanel();
  }

  function checkHash() { if (location.hash.startsWith('#apf-auto')) openPanel(); }
  window.addEventListener('hashchange', checkHash);
  checkHash();

  // 整理バーからも開けるようにする
  const bar = document.querySelector('.apf-bar');
  if (bar) {
    bar.querySelector('.apf-status').before(el('button', { type: 'button', onclick: () => { location.hash = 'apf-auto'; } }, '自動検索…'));
  }
})();
