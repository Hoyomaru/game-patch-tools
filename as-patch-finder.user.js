// ==UserScript==
// @name         AS Patch Finder（検索結果のバージョン整理）
// @namespace    local.patch-finder
// @version      1.3.0
// @description  検索結果のタイトルからバージョン・作品コード・更新日を抜き出し、作品ごとにまとめて最新版をハイライトします。作品コードのリストを順番に自動検索して、見つかったスレッドのURLを集めることもできます。
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

  const PATCH_RE = /patch|translat|mtl|翻訳|パッチ|日本語化|english|eng\b/i;

  // ---------- 解析 ----------
  const VER_RE = /(?:\bver(?:sion)?\.?\s*|\bv)(\d+(?:[._\-/]\d+)*[a-z]?)\b/i;

  // バージョン文字列が日付の形なら 'YYYY-MM-DD' を返す。違えば null。
  //   26.11.08 / 26-11-08 / 2026.11.08 / 261108 / 20261108
  function dateFromVersion(s) {
    let m = s.match(/^(\d{2}|20\d{2})[._\-/](\d{1,2})[._\-/](\d{1,2})$/) ||
            s.match(/^(20\d{2}|\d{2})(\d{2})(\d{2})$/);
    if (!m) return null;
    const y = m[1].length === 2 ? 2000 + Number(m[1]) : Number(m[1]);
    const mo = Number(m[2]), d = Number(m[3]);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
  }

  // 戻り値: { version: '1.10' | null, dateVer: '2026-11-08' | null }
  function parseVersion(title) {
    // Ver1.10 / ver2.22 / v1.08 / Version 1.2.3
    let m = title.match(VER_RE);
    if (m) {
      // Ver26.11.08 のような日付形式は「日付版」として扱う
      const dv = dateFromVersion(m[1]);
      if (dv) return { version: null, dateVer: dv };
      return { version: m[1].replace(/[_\-/]/g, '.'), dateVer: null };
    }
    // [r102652] のようなリビジョン番号
    m = title.match(/\[r(\d{3,})\]/i);
    if (m) return { version: m[1], dateVer: null };
    return { version: null, dateVer: null };
  }

  function parseDates(title) {
    // (2023.02.14) / 2023-02-14 / [220702] (YYMMDD)
    const out = [];
    for (const m of title.matchAll(/(20\d{2})[.\-/](\d{1,2})[.\-/](\d{1,2})/g)) {
      out.push(`${m[1]}-${m[2].padStart(2, '0')}-${m[3].padStart(2, '0')}`);
    }
    for (const m of title.matchAll(/\[(\d{2})(\d{2})(\d{2})\]/g)) {
      out.push(`20${m[1]}-${m[2]}-${m[3]}`);
    }
    return out.sort();
  }

  function parseCode(title) {
    const m = title.match(/\b(RJ|VJ|BJ|RE)(\d{6,8})\b/i);
    return m ? (m[1] + m[2]).toUpperCase() : null;
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
      code: parseCode(title),
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

  // 新しさの比較：バージョン → 日付版どうし → タイトル内の一番新しい日付 → 投稿日
  // （片方にしか情報がない項目は比較に使わず、次の基準へ進む）
  function newer(a, b) {
    if (a.version && b.version) {
      const v = cmpVersion(a.version, b.version);
      if (v) return v;
    }
    if (a.dateVer && b.dateVer && a.dateVer !== b.dateVer) return a.dateVer < b.dateVer ? -1 : 1;
    if (a.lastDate && b.lastDate && a.lastDate !== b.lastDate) return a.lastDate < b.lastDate ? -1 : 1;
    return a.posted - b.posted;
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

  function renderBadges(info, groupSize, isLatest) {
    info.li.querySelector('.apf-badges')?.remove();
    const box = document.createElement('div');
    box.className = 'apf-badges';
    if (groupSize > 1) {
      box.appendChild(isLatest ? badge(`★ 最新（${groupSize}件中）`, 'apf-latest') : badge('旧版', 'apf-old'));
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

  function collect() {
    rows = [...list.querySelectorAll(ROW_SEL)].map((li, i) => {
      if (li.dataset.apfIndex == null) li.dataset.apfIndex = String(i);
      return analyze(li);
    }).filter(Boolean);
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
      g.forEach((r, i) => { r.isLatest = i === 0; r.groupSize = g.length; renderBadges(r, g.length, i === 0); });
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
    return Object.assign({ queue: [], results: {}, interval: 8, staleDays: 30 }, a || {});
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
    return r && !r.error && Date.now() - r.at < auto.staleDays * 86400000;
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

  // 長いタイトルは「… [RJ01...」のように途中で切れて表示されるので、切れた先頭部分が一致すれば同じ作品とみなす
  function cutCode(title, code) {
    const m = title.match(/((?:RJ|VJ|BJ|RE)\d*)(?:\.\.\.|…)$/i);
    return !!m && m[1].length >= 4 && code.startsWith(m[1].toUpperCase());
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
    const list = [...threads.values()].map(t => {
      const pv = parseVersion(t.title);
      return Object.assign(t, { version: pv.version, dateVer: pv.dateVer, isPatch: PATCH_RE.test(t.title) });
    });
    // タイトルにコードがあるスレッド → 新しい投稿 の順
    list.sort((a, b) => (b.hasCode - a.hasCode) || (b.posted - a.posted));
    return list;
  }

  async function runAuto() {
    if (running) return;
    if (lockHeldByOther()) { autoMsg('別のタブで検索中です。そちらを止めるか閉じてから開始してください。'); return; }
    running = true; stopReq = false;
    takeLock();
    renderPanel();
    let floods = 0;
    try {
      while (!stopReq) {
        const code = pending()[0];
        if (!code) { autoMsg('すべて検索しました。'); break; }
        autoMsg(`${code} を検索中…`);
        try {
          const threads = await searchCode(code);
          auto.results[code] = { at: Date.now(), threads };
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
          auto.results[code] = { at: Date.now(), threads: [], error: String(e.message || e) };
          if (/HTTP 40[13]/.test(auto.results[code].error)) {
            saveAuto();
            autoMsg('ASに断られました（' + auto.results[code].error + '）。このページを開き直して、普通に見られるか確かめてから再開してください。');
            break;
          }
        }
        saveAuto();
        renderPanel();
        if (pending().length) await wait(auto.interval * 1000, '次の検索まで待機中');
      }
    } finally {
      running = false;
      releaseLock();
      if (stopReq) autoMsg('一時停止しました。「開始」で続きから再開します。');
      renderPanel();
    }
  }

  // ---- 書き出し ----
  function exportRows(onlyFound) {
    const lines = [];
    for (const c of auto.queue) {
      const r = auto.results[c];
      if (!r) { if (!onlyFound) lines.push([c, '未検索', '', '']); continue; }
      if (!r.threads.length) { if (!onlyFound) lines.push([c, r.error ? 'エラー' : 'なし', '', '']); continue; }
      for (const t of r.threads) lines.push([c, t.kind === 'thread' ? 'スレッド' : '投稿内', t.url, t.title]);
    }
    return lines;
  }
  async function copyUrls() {
    const lines = exportRows(true).map(l => `${l[0]}\t${l[2]}\t${l[3]}`);
    try {
      await navigator.clipboard.writeText(lines.join('\n'));
      autoMsg(`${lines.length}件のURLをコピーしました（RJ番号・URL・タイトルのタブ区切り）。`);
    } catch (e) { autoMsg('コピーに失敗しました: ' + e.message); }
  }
  function saveTsv() {
    const rows = [['作品コード', '種類', 'URL', 'タイトル'], ...exportRows(false)];
    const tsv = rows.map(r => r.map(x => String(x).replace(/[\t\r\n]+/g, ' ')).join('\t')).join('\r\n');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob(['﻿' + tsv], { type: 'text/tab-separated-values' }));
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

  function renderPanel() {
    if (!panel) return;
    const total = auto.queue.length;
    const left = pending().length;
    const done = total - left;
    const found = auto.queue.filter(c => auto.results[c]?.threads.length).length;
    const urls = auto.queue.reduce((n, c) => n + (auto.results[c]?.threads.length || 0), 0);
    const errors = auto.queue.filter(c => auto.results[c]?.error).length;
    const etaMin = Math.ceil(left * (auto.interval + 1.5) / 60);

    const startBtn = running
      ? el('button', { type: 'button', onclick: () => { stopReq = true; autoMsg('止めています…'); } }, '一時停止')
      : el('button', { type: 'button', class: 'apf-primary', onclick: runAuto, ...(left ? {} : { disabled: '' }) },
          done ? '続きから開始' : '開始');

    const num = (key, min, max, label, unit) => el('label', {}, label + ' ',
      el('input', { type: 'number', min, max, value: auto[key], oninput: e => {
        const v = Number(e.target.value);
        if (v >= min && v <= max) { auto[key] = v; saveAuto(); }
      } }), unit);

    const paste = el('div', { style: 'display:none' },
      el('div', {}, 'RJ番号を貼り付けてください（ほかの文字が混ざっていてもOK）。検索対象がこのリストに置き換わります。前回までの検索結果は残ります。'),
      el('textarea', {}),
      el('div', { class: 'apf-row' },
        el('button', { type: 'button', onclick: e => {
          const codes = importCodes(e.target.closest('div').previousElementSibling.value);
          if (!codes.length) { autoMsg('RJ番号が見つかりませんでした。'); return; }
          setQueue(codes);
        } }, 'このリストにする')));

    const view = el('select', { onchange: e => { panelView = e.target.value; renderPanel(); } },
      ...[['found', '見つかった作品'], ['none', '見つからなかった作品'], ['todo', 'まだの作品'], ['all', 'すべて']]
        .map(([v, t]) => el('option', { value: v, ...(panelView === v ? { selected: '' } : {}) }, t)));

    panel.replaceChildren(
      el('h3', {}, '自動検索（作品コードで順番に検索）'),
      el('div', { class: 'apf-row' },
        `対象 ${total}件 ／ 検索済み ${done}件 ／ 見つかった作品 ${found}件（スレッド ${urls}件）` +
        (errors ? ` ／ エラー ${errors}件` : '') + (left ? ` ／ 残り ${left}件（約${etaMin}分）` : '')),
      el('div', { class: 'apf-prog' }, el('div', { style: `width:${total ? (done / total) * 100 : 0}%` })),
      el('div', { class: 'apf-row' },
        startBtn,
        num('interval', 3, 60, '間隔', '秒'),
        num('staleDays', 0, 365, '', '日以内に検索した作品は飛ばす'),
        el('button', { type: 'button', onclick: () => { paste.style.display = paste.style.display ? '' : 'none'; } }, 'RJ番号を貼り付け…')),
      paste,
      el('div', { class: 'apf-row' },
        el('button', { type: 'button', onclick: copyUrls }, '見つかったURLをコピー'),
        el('button', { type: 'button', onclick: saveTsv }, 'ファイルに保存（TSV）'),
        el('button', { type: 'button', onclick: () => {
          if (running) { autoMsg('止めてから押してください。'); return; }
          if (!confirm('検索結果をすべて消して、最初から検索し直せるようにします。よろしいですか？')) return;
          auto.results = {}; saveAuto(); renderPanel();
        } }, '結果を消す'),
        el('label', {}, '表示 ', view)),
      el('div', { class: 'apf-msg' }, msgText),
      resultTable());
  }

  function resultTable() {
    const rows = [];
    for (const c of auto.queue) {
      const r = auto.results[c];
      const has = r?.threads.length > 0;
      if (panelView === 'found' && !has) continue;
      if (panelView === 'none' && (!r || has)) continue;
      if (panelView === 'todo' && r && !r.error) continue;
      const cell = !r ? el('span', { class: 'apf-weak' }, 'まだ')
        : r.error ? el('span', {}, 'エラー: ' + r.error)
        : !has ? el('span', { class: 'apf-weak' }, 'なし')
        : r.threads.map(t => el('div', { class: 'apf-t' + (t.hasCode ? '' : ' apf-weak') },
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
          r ? el('div', { class: 'apf-weak' }, fmtDate(r.at / 1000)) : null),
        el('td', {}, cell)));
    }
    if (!rows.length) return el('div', { class: 'apf-weak', style: 'margin-top:6px' }, '表示するものがありません。');
    return el('table', {}, el('tbody', {}, rows));
  }

  function importCodes(text) {
    return [...new Set((text.match(CODE_RE_G) || []).map(s => s.toUpperCase()))];
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
