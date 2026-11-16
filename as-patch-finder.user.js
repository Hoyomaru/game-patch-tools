// ==UserScript==
// @name         AS Patch Finder（検索結果のバージョン整理）
// @namespace    local.patch-finder
// @version      1.2.0
// @description  検索結果のタイトルからバージョン・作品コード・更新日を抜き出し、作品ごとにまとめて最新版をハイライトします。
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

  function addStyle() {
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
})();
