// ==UserScript==
// @name         AS Patch Finder（検索結果のバージョン整理）
// @namespace    local.patch-finder
// @version      1.10.1
// @description  検索結果のタイトルからバージョン・作品コード・更新日を抜き出し、作品ごとにまとめて最新版をハイライトします。作品コードのリストを順番に自動検索して、見つかったスレッドのURLを集めることもできます。持っている作品・気になる作品の印をASのページに、検索結果を DLsite の作品ページに出します。
// @icon         https://www.anime-sharing.com/styles/io/images/favicon.png
// @homepageURL  https://github.com/Hoyomaru/game-patch-tools
// @updateURL    https://raw.githubusercontent.com/Hoyomaru/game-patch-tools/main/as-patch-finder.user.js
// @downloadURL  https://raw.githubusercontent.com/Hoyomaru/game-patch-tools/main/as-patch-finder.user.js
// @match        https://www.anime-sharing.com/search/*
// @match        https://anime-sharing.com/search/*
// @match        https://www.anime-sharing.com/forums/*
// @match        https://anime-sharing.com/forums/*
// @match        https://www.anime-sharing.com/threads/*
// @match        https://anime-sharing.com/threads/*
// @match        https://www.dlsite.com/*/work/=/product_id/*
// @grant        GM_xmlhttpRequest
// @grant        GM_getValue
// @grant        GM_setValue
// @connect      www.dlsite.com
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
  // 先頭に「0.」を付けた日付形式のバージョン：Ver0.23.9.26（月日は1桁のこともある）
  const DATE_VER0_RE = new RegExp(`${VER_PREFIX}0\\.(\\d{2})\\.(\\d{1,2})\\.(\\d{1,2})(?![\\w.])`, 'i');

  const THIS_YEAR = new Date().getFullYear();

  // 年月日として妥当なら 'YYYY-MM-DD'、違えば null。
  // 2桁の年は月日も2桁のときだけ日付とみなす（v10.2.3 のような普通のバージョンを日付と取り違えないため）。
  // loose なら月日が1桁でもよい（「0.」付きで日付だとわかるとき）
  function ymd(y, mo, d, loose = false) {
    if (!loose && y.length === 2 && (mo.length !== 2 || d.length !== 2)) return null;
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
    m = title.match(DATE_VER0_RE);
    if (m) {
      const dv = ymd(m[1], m[2], m[3], true);
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

  // リクエストスレッド：リクエスト用のフォーラム（Hentai Games Request など）にあるか、タイトルが [REQUEST] などで始まる
  function isRequest(title, forum = '') {
    return /request/i.test(forum) || /^\s*(?:[\[(【]\s*)?request\b/i.test(title);
  }

  // 1作品グループの並びと最新を決める。
  //   最新の候補は、リクエストでなく、タイトルかURLに作品コードがあるもの（なければ本文だけで当たったもの）。
  //   候補を新しい順に並べ、残り（本文だけで当たったもの・リクエスト）はその後ろに新しい順で並べる
  function orderGroup(g) {
    const ok = g.filter(r => !r.isRequest);
    const strong = ok.filter(r => !r.weak);
    const cands = strong.length ? strong : ok;
    const sorted = [...cands].sort((a, b) => newer(b, a));
    const rest = g.filter(r => !cands.includes(r)).sort((a, b) => newer(b, a));
    return { list: [...sorted, ...rest], latest: sorted[0] || null, basis: decidedBy(sorted[0], sorted[1]), mixed: isMixed(cands) };
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
    const forum = li.querySelector('.contentRow-minor a[href^="/forums/"]')?.textContent.trim() || '';
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
      isRequest: isRequest(title, forum),
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

  // ---- DLsite の更新情報 ----
  // 作品ページの「更新情報」と同じもの（/api/product/maniax/fetchRevision）の list を、
  // { date: 'YYYY-MM-DD', version: '1.0.3' | null } の配列（新しい順）にする。
  // 版の番号は、更新内容の文章に「Ver1.0.3に更新」「バージョンを1.0.0から1.0.1へ」のように書いてあるときだけ読める
  const REV_VER_RE = /(?:\bver(?:sion)?\.?\s*|バージョン\s*(?:を|が|は)?\s*)(\d+(?:\.\d+)+)|(\d+(?:\.\d+)+)\s*(?:へ|に)\s*(?:更新|アップデート|変更)/gi;
  function parseRevisions(list) {
    const out = [];
    for (const r of list || []) {
      const m = String(r.release_date || '').match(/(\d{4})\D+(\d{1,2})\D+(\d{1,2})/);
      const date = m && ymd(m[1], m[2], m[3]);
      if (!date) continue;
      let version = null;
      for (const v of String(r.info || '').normalize('NFKC').matchAll(REV_VER_RE)) {
        const x = v[1] || v[2];
        if (!version || cmpVersion(x, version) > 0) version = x;   // 「1.0.0から1.0.1へ」は大きい方
      }
      out.push({ date, version });
    }
    return out.sort((a, b) => cmpStr(b.date, a.date));
  }

  const dayOf = ts => {
    const d = new Date(ts * 1000);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  };

  // スレッドの版が DLsite で出た日（推定）。更新情報がなければ null。
  //   日付版 → その日付
  //   バージョン番号 → 更新情報に同じ番号があればその日。なければ、投稿日までに出た一番新しい更新の日。
  //                    最初の更新より前に投稿されたものは発売時の版なので、どの更新よりも古い扱い（'0000-00-00'）
  function revDateOf(t, revs) {
    if (!revs || !revs.length) return null;
    if (t.dateVer) return t.dateVer;
    if (!t.version) return null;
    const hit = revs.find(r => r.version && cmpVersion(r.version, t.version) === 0);
    if (hit) return hit.date;
    if (!t.posted) return null;
    const p = dayOf(t.posted);
    return revs.find(r => r.date <= p)?.date || '0000-00-00';
  }

  // バージョン番号のものと日付版のものが混ざっていて、そのままでは比べられないか
  const isMixed = list => list.some(r => tier(r) === 2) && list.some(r => tier(r) === 1);

  // バージョン番号と日付版を、DLsite の更新情報から推定した日で比べられるとき
  const byRevDate = (a, b) => tier(a) && tier(b) && tier(a) !== tier(b) && a.revDate && b.revDate && a.revDate !== b.revDate;

  // 新しさの比較。どの組み合わせでも同じ基準で比べるので、並び順で結果が変わらない。
  //   0. バージョン番号と日付版は、DLsite の更新情報から推定した日があればそれで比べる
  //   1. 版の情報の強さ（バージョン番号あり ＞ 日付版 ＞ なし）
  //   2. 同じ強さの中で：バージョン番号 または 日付版
  //   3. タイトル内の一番新しい日付（ないものは古い扱い）
  //   4. 投稿日
  function newer(a, b) {
    if (byRevDate(a, b)) return cmpStr(a.revDate, b.revDate);
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
    if (byRevDate(a, b)) return 'DLsite更新情報';
    if (tier(a) !== tier(b)) return tier(b) === 0 ? '版の表記の有無' : '版の表記の種類';
    if (a.version && cmpVersion(a.version, b.version)) return 'バージョン';
    if (a.dateVer && a.dateVer !== b.dateVer) return '日付版';
    if ((a.lastDate || '') !== (b.lastDate || '')) return 'タイトル日付';
    return '投稿日';
  }

  // 保存済みのスレッドに、タイトルから版の情報を付け直す（古いバージョンで保存した結果にも効くよう、表示のたびに計算する）
  function threadInfo(t, revs) {
    const pv = parseVersion(t.title);
    const dates = parseDates(t.title);
    if (pv.dateVer && !dates.includes(pv.dateVer)) dates.push(pv.dateVer), dates.sort();
    const info = Object.assign({}, t, {
      version: pv.version, dateVer: pv.dateVer, lastDate: dates[dates.length - 1] || null,
      isPatch: PATCH_RE.test(t.title), isRequest: isRequest(t.title, t.forum), isLatest: false,
    });
    info.revDate = revDateOf(info, revs);
    return info;
  }

  // 1作品分のスレッドを並べ、最新を決める。
  //   最新の候補はタイトルにコードがあるもの（1件もなければ、作品名で見つかったもの）。リクエストスレッドは候補にしない。
  //   その中にパッチ/翻訳があれば、パッチ/翻訳だけで比べる。
  //   並び：最新 → コードあり → 作品名で見つかった → そのほか（それぞれ新しい順）
  //   revs（DLsite の更新情報）があれば、バージョン番号と日付版をそれで比べる。mixed は「比べるのに更新情報がほしい」印
  function rankThreads(threads, revs = null) {
    const list = threads.map(t => threadInfo(t, revs));
    const withCode = list.filter(t => t.hasCode && !t.isRequest);
    const byTitle = withCode.length ? [] : list.filter(t => t.byTitle && !t.isRequest);
    const pool = withCode.length ? withCode : byTitle;
    const patches = pool.filter(t => t.isPatch);
    const cands = patches.length ? patches : pool;
    const sorted = [...cands].sort((a, b) => newer(b, a));
    const latest = sorted[0] || null;
    const info = { latest, basis: '', patchOnly: patches.length > 0, byTitle: byTitle.length > 0, count: cands.length, mixed: isMixed(cands) };
    if (latest) latest.isLatest = true;
    if (latest && cands.length > 1) info.basis = decidedBy(latest, sorted[1]);
    list.sort((a, b) => (b.isLatest - a.isLatest) || (b.hasCode - a.hasCode) || (!!b.byTitle - !!a.byTitle) || newer(b, a));
    return { list, ...info };
  }

  // 前回と今回の検索結果を比べる。前回がない（初めて・エラーだった）ときは null。
  //   newCount: 前回なかったスレッドの数（URLで比べる）
  //   latestChanged: 最新のスレッドか、そのバージョンが変わったか
  const verLabel = t => (t ? (t.version ? 'v' + t.version : t.dateVer || '版不明') : '');
  function diffResults(prev, next, revs = null) {
    if (!prev || prev.error) return null;
    const old = new Set(prev.threads.map(t => t.url));
    const newCount = next.filter(t => !old.has(t.url)).length;
    const a = rankThreads(prev.threads, revs).latest, b = rankThreads(next, revs).latest;
    const latestChanged = !!b && (!a || a.url !== b.url || verLabel(a) !== verLabel(b));
    if (!newCount && !latestChanged) return null;
    return { newCount, latestChanged, from: a ? verLabel(a) : '', to: verLabel(b) };
  }

  // まだ消していない前回の印（older）に、今回の違い（newer）を足す。
  // 印を見る前に検索し直しても、印が消えたり「新着」の数が減ったりしないように。
  function mergeChanges(older, newer) {
    if (!older) return newer || null;
    if (!newer) return older;
    const at = newer.at || older.at;
    return {
      newCount: older.newCount + newer.newCount,
      latestChanged: older.latestChanged || newer.latestChanged,
      from: older.latestChanged ? older.from : newer.from,
      to: newer.to,
      ...(at ? { at } : {}),
    };
  }

  // 作品に付けた「確認済み」「見送り」の印がまだ効いているか。
  // 「確認済み」は、付けたあとに新着・更新の印（changes.at）が付いたら外れる（見落とさないように）。「見送り」は外れない
  function markActive(mark, result) {
    if (!mark) return null;
    if (mark.s === 'done' && result?.changes && (result.changes.at || 0) > mark.at) return null;
    return mark.s;
  }

  // 手元の版の文字（「1.02」「v1.02」「23.11.13」「2023-11-13」など）を、スレッドと同じ形 { version, dateVer } にする
  function parseLocalVersion(s) {
    s = String(s || '').trim();
    if (!s) return null;
    const pv = parseVersion(/^v|^ver/i.test(s) ? s : 'v' + s);
    return pv.version || pv.dateVer ? pv : null;
  }

  // 手元の版と、ASの最新スレッドの版を比べる。
  //   'newer' … ASの方が新しい ／ 'same' … 同じ ／ 'older' … 手元の方が新しい ／ 'unknown' … 比べられない
  //   バージョン番号と日付版は、DLsite の更新情報（revs）で同じ版の日がわかるときだけ比べる
  function compareLocal(local, latest, revs = null) {
    const l = parseLocalVersion(local);
    if (!l || !latest || !tier(latest)) return 'unknown';
    const sign = n => (n > 0 ? 'newer' : n < 0 ? 'older' : 'same');
    if (l.version && latest.version) return sign(cmpVersion(latest.version, l.version));
    if (l.dateVer && latest.dateVer) return sign(cmpStr(latest.dateVer, l.dateVer));
    const ld = revDateOf(Object.assign({ posted: 0 }, l), revs);
    const rd = latest.revDate ?? revDateOf(latest, revs);
    return ld && rd && ld !== '0000-00-00' ? sign(cmpStr(rd, ld)) : 'unknown';
  }

  // 所持チェックから渡される「持っている作品」のリスト：「RJ01234567~1.02,RJ07654321,…」
  // 戻り値: { codes: [...], versions: { 作品コード: 手元の版 } }
  function parseOwnedList(text) {
    const codes = [], versions = {};
    for (const part of String(text || '').split(',')) {
      const m = part.trim().match(/^((?:RJ|VJ|BJ|RE)\d{6,8})(?:~(.+))?$/i);
      if (!m) continue;
      const c = m[1].toUpperCase();
      if (!codes.includes(c)) codes.push(c);
      if (m[2]) versions[c] = m[2].trim();
    }
    return { codes, versions };
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
    .apf-own{background:#7c3aed;color:#fff;border-color:#7c3aed}
    .apf-wish{background:#0e7490;color:#fff;border-color:#0e7490}
    .apf-cmp-newer{background:#c2410c;color:#fff;border-color:#c2410c;font-weight:bold}
    .apf-mk{font-size:11px;line-height:1.6;padding:0 6px;border-radius:3px;cursor:pointer;
      border:1px solid rgba(127,127,127,.5);background:transparent;color:inherit}
    .apf-mk.apf-on{background:#475569;color:#fff;border-color:#475569}
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

  const fmtDate = ts => (ts ? dayOf(ts) : '');

  function renderBadges(info, groupSize, isLatest, basis, latest) {
    info.li.querySelector('.apf-badges')?.remove();
    const box = document.createElement('div');
    box.className = 'apf-badges';
    if (info.isRequest) box.appendChild(badge('リクエスト', 'apf-old'));
    else if (groupSize > 1) {
      if (isLatest) box.appendChild(badge(`★ 最新（${groupSize}件中・${basis}で判定）`, 'apf-latest'));
      else if (info.weak) box.appendChild(badge('本文だけで一致（タイトルにコードなし）', 'apf-old'));
      else if (latest && tier(info) < tier(latest)) box.appendChild(badge('版不明（最新と比べられない）', 'apf-old'));
      else box.appendChild(badge('旧版', 'apf-old'));
    }
    if (info.version) box.appendChild(badge('v' + info.version, 'apf-ver'));
    else if (info.dateVer) box.appendChild(badge('日付版 ' + info.dateVer, 'apf-ver'));
    else box.appendChild(badge('バージョン表記なし', 'apf-nover'));
    if (info.lastDate) box.appendChild(badge('タイトル日付 ' + info.lastDate));
    if (info.posted) box.appendChild(badge('投稿 ' + fmtDate(info.posted)));
    if (info.code) box.appendChild(badge(info.code));
    if (info.isPatch) box.appendChild(badge('パッチ/翻訳'));
    if (info.code) box.append(...workBadges(info.code));
    info.li.classList.toggle('apf-row-latest', groupSize > 1 && isLatest);
    info.li.querySelector('.contentRow-title').after(box);
  }

  // ---------- 保存 ----------
  // 自動検索の結果・印・手元の版・DLsite の更新情報は Tampermonkey の保存領域に置く（AS と DLsite の両方のページから読めるように）。
  // 1.6.0 までは AS のページのブラウザ保存領域（localStorage）にあったので、AS のページで初めて読むときに移す
  const onAS = /(^|\.)anime-sharing\.com$/.test(location.hostname);
  const onSearch = onAS && location.pathname.startsWith('/search');
  const hasGM = typeof GM_getValue === 'function' && typeof GM_setValue === 'function';
  function loadStore(key) {
    if (hasGM) {
      const v = GM_getValue(key, null);
      if (v != null) return typeof v === 'string' ? JSON.parse(v) : v;
    }
    if (!onAS) return null;
    let v = null;
    try { v = JSON.parse(localStorage.getItem(key)); } catch { v = null; }
    if (v != null && hasGM) GM_setValue(key, JSON.stringify(v));
    return v;
  }
  function saveStore(key, v) {
    const s = JSON.stringify(v);
    if (hasGM) GM_setValue(key, s); else localStorage.setItem(key, s);
  }

  // 作品ごとの印 { 作品コード: { s: 'done'（確認済み）| 'skip'（見送り）, at } } と、
  // 手元の版 { 作品コード: { v: '1.02', src: 'folder'（フォルダ名から）| 'hand'（手で入力） } }。
  // 別のタブで書き換えられていても消さないよう、書くときは読み直してから1件だけ変える
  const MARKS_KEY = 'apf-marks', LOCAL_KEY = 'apf-local';
  const readMap = key => { try { return loadStore(key) || {}; } catch { return {}; } };
  function updateMap(key, code, value) {
    const m = readMap(key);
    if (value == null) delete m[code]; else m[code] = value;
    try { saveStore(key, m); } catch {}
    return m;
  }

  // ---------- DLsite の更新情報（取得と保存） ----------
  // バージョン番号と日付版が混ざっていて比べられない作品だけ取りに行く（1件500バイトほど）。結果は7日間使い回す
  const REV_KEY = 'apf-rev';
  const REV_DAYS = 7;
  const canFetchRev = typeof GM_xmlhttpRequest === 'function';
  let revStore;
  try { revStore = loadStore(REV_KEY) || {}; } catch { revStore = {}; }
  const saveRev = () => { try { saveStore(REV_KEY, revStore); } catch {} };
  // 保存済みの更新情報（古くても使う。なければ null）
  const cachedRevs = code => revStore[code]?.revs || null;
  const revFresh = code => !!revStore[code] && Date.now() - revStore[code].at < REV_DAYS * 86400000;
  const isCode = s => /^(?:RJ|VJ|BJ|RE)\d{6,8}$/.test(s);

  function gmGetJson(url) {
    return new Promise((res, rej) => GM_xmlhttpRequest({
      method: 'GET', url, timeout: 15000,
      onload: r => {
        if (r.status !== 200) return rej(new Error('HTTP ' + r.status));
        try { res(JSON.parse(r.responseText)); } catch (e) { rej(e); }
      },
      onerror: () => rej(new Error('network')),
      ontimeout: () => rej(new Error('timeout')),
    }));
  }

  // 作品コードの更新情報を取る（保存済みで新しければそれを使う）。
  // 何件頼まれても1件ずつ、DLsite への問い合わせは1秒以上あけて行う
  let revQueue = Promise.resolve(), revLast = 0;
  const pause = ms => new Promise(r => setTimeout(r, ms));
  function getRevisions(code) {
    if (revFresh(code) || !canFetchRev) return Promise.resolve(cachedRevs(code));
    const job = revQueue.then(async () => {
      if (revFresh(code)) return cachedRevs(code);
      const list = [];
      for (let page = 1; page <= 5; page++) {
        const gap = 1000 - (Date.now() - revLast);
        if (gap > 0) await pause(gap);
        revLast = Date.now();
        const j = await gmGetJson(`https://www.dlsite.com/api/product/maniax/fetchRevision?product_id=${encodeURIComponent(code)}&page=${page}&locale=ja_JP`);
        if (!j || !j.success) throw new Error('DLsite の更新情報を読めませんでした');
        list.push(...(j.list || []));
        if (!j.more) break;
      }
      const revs = parseRevisions(list);
      revStore[code] = { at: Date.now(), revs };
      saveRev();
      return revs;
    });
    revQueue = job.catch(() => {});
    return job;
  }

  // ---------- メイン ----------
  let list, rows = [], state;
  try { state = JSON.parse(localStorage.getItem('apf-state')) || {}; } catch { state = {}; }
  state = Object.assign({ sort: 'group', dim: true, hideOld: false, hideReq: true, filter: '' }, state);
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
    const qc = queryCodes();
    const known = [...new Set([...qc, ...rows.map(r => r.code).filter(Boolean)])];
    for (const r of rows) {
      if (r.code) continue;
      const c = codeOf(r.title, r.href, known);
      if (c) { r.code = c; r.group = c; r.weak = false; }
      // 作品コード1つで検索したとき、タイトルにもURLにもコードがない結果は本文で当たったもの。
      // 作品名の書き方の違いで別グループに分かれないよう、検索したコードのグループに入れる（最新の候補にはしない）
      else if (qc.length === 1) { r.group = qc[0]; r.weak = true; }
    }
  }

  // 比べるのに更新情報がほしい作品の分を DLsite から取り、取れたら判定し直す（1ページで1作品1回まで）
  const revTried = new Set();
  async function loadRevisions(codes) {
    let got = false, failed = 0;
    for (const c of codes) {
      revTried.add(c);
      status(`DLsite の更新情報を取得中…（${c}）`);
      try { if ((await getRevisions(c))?.length) got = true; } catch { failed++; }
    }
    if (got) refresh();
    else status(failed ? `DLsite の更新情報を取得できませんでした（${failed}件）` : 'DLsite に更新情報がありませんでした');
  }

  function refresh() {
    // グループごとに最新を判定
    // 「リクエストを隠す」ときは、リクエストスレッドを作品グループに数えない
    const groups = new Map();
    for (const r of rows) {
      if (state.hideReq && r.isRequest) {
        r.isLatest = false; r.groupSize = 1; renderBadges(r, 1, false, '', null);
        continue;
      }
      if (!groups.has(r.group)) groups.set(r.group, []);
      groups.get(r.group).push(r);
    }
    const wantRevs = [];
    for (const [k, g] of groups) {
      // バージョン番号と日付版は、DLsite の更新情報があればそれで比べる
      const revs = isCode(k) ? cachedRevs(k) : null;
      for (const r of g) r.revDate = revDateOf(r, revs);
      const o = orderGroup(g);
      if (o.mixed && isCode(k) && !revFresh(k) && canFetchRev && !revTried.has(k)) wantRevs.push(k);
      groups.set(k, o.list);
      o.list.forEach(r => { r.isLatest = r === o.latest; r.groupSize = g.length; renderBadges(r, g.length, r.isLatest, o.basis, o.latest); });
    }
    if (wantRevs.length) Promise.resolve().then(() => loadRevisions(wantRevs));   // 下の状態表示のあとに「取得中」を出す

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
          head.textContent = `▼ ${g.find(r => r.code)?.code || g[0].title.slice(0, 60)}　— ${g.length}件`;
          head._apfGroup = g;
          ordered.push(head);
        }
        ordered.push(...g.map(r => r.li));
      }
      ordered.push(...rows.filter(r => state.hideReq && r.isRequest).map(r => r.li));
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
      const hide = !hit || (state.hideReq && r.isRequest) || (state.hideOld && r.groupSize > 1 && !r.isLatest);
      r.li.classList.toggle('apf-hidden', hide);
      r.li.classList.toggle('apf-dim', !hide && state.dim && !r.isPatch);
      if (!hide) shown++;
    }
    list.querySelectorAll('.apf-group-head').forEach(h => {
      h.classList.toggle('apf-hidden', h._apfGroup.every(r => r.li.classList.contains('apf-hidden')));
    });
    const reqs = rows.filter(r => r.isRequest).length;
    status(`${rows.length}件中 ${shown}件を表示 ／ 作品グループ ${groups.size}` +
      (reqs ? ` ／ リクエスト ${reqs}件${state.hideReq ? '（非表示）' : ''}` : ''));
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
      <label><input type="checkbox" data-k="hideReq"> リクエストを隠す</label>
      <input type="text" data-k="filter" placeholder="タイトル内を絞り込み">
      <button type="button" data-act="more">残りのページも読み込む</button>
      <span class="apf-status"></span>`;
    statusEl = bar.querySelector('.apf-status');
    bar.querySelector('[data-k=sort]').value = state.sort;
    bar.querySelector('[data-k=dim]').checked = state.dim;
    bar.querySelector('[data-k=hideOld]').checked = state.hideOld;
    bar.querySelector('[data-k=hideReq]').checked = state.hideReq;
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
  let running = false, stopReq = false, panel = null, panelView = 'unmarked', lockTimer = null;

  function loadAuto() {
    let a;
    try { a = loadStore(AUTO_KEY); } catch { a = null; }
    // titles: { 作品コード: 作品名 }（作品名検索に使う。貼り付けで読み込む）
    // lists: 検索するリスト。wish = 気になる（持っていない）作品、owned = 持っている作品（更新の確認用）。
    //        queue は今選んでいるリスト（list）の中身
    a = Object.assign({ queue: [], results: {}, titles: {}, useTitles: true, interval: 8, staleDays: 30, list: 'wish', lists: null }, a || {});
    if (!a.lists) a.lists = { wish: a.queue, owned: [] };     // 1.6.0 までのリストは「気になる」にする
    return a;
  }
  function saveAuto() {
    auto.lists[auto.list] = auto.queue;
    try { saveStore(AUTO_KEY, auto); }
    catch (e) { autoMsg('保存に失敗しました（保存容量がいっぱいかもしれません）: ' + e.message); }
  }

  const LIST_NAMES = { wish: '気になる（持っていない）作品', owned: '持っている作品（更新の確認）' };
  // 作品がどのリストに入っているか（持っている方を優先）
  function listOf(code) {
    if (auto.lists.owned.includes(code)) return 'owned';
    if (auto.lists.wish.includes(code)) return 'wish';
    return null;
  }
  const markOf = code => markActive(readMap(MARKS_KEY)[code], auto.results[code]);
  const MARK_TEXT = { done: '✓ 確認済み', skip: '見送り' };
  // 検索結果・フォーラム・スレッドのページで、作品コードの横に出す印（どのリストか・確認済み/見送り）
  function workBadges(code) {
    const out = [];
    const l = listOf(code);
    if (l === 'owned') out.push(badge('持っている', 'apf-own'));
    else if (l === 'wish') out.push(badge('気になる', 'apf-wish'));
    const m = markOf(code);
    if (m) out.push(badge(MARK_TEXT[m], 'apf-old'));
    return out;
  }
  // 手元の版（手で入れたものを優先）
  const localOf = code => readMap(LOCAL_KEY)[code]?.v || '';
  const CMP_TEXT = { newer: '新しい版あり', same: '手元と同じ版', older: '手元の方が新しい', unknown: '手元と比べられない' };

  // 裏のタブでも止まりにくい待ち時間（ブラウザは裏タブの setTimeout を1分おきまで遅らせることがあるため Worker を使う）
  let sleepWorker = null, sleepSeq = 0;
  const sleepWaits = new Map();
  if (onSearch) try {
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
          // バージョン番号と日付版が混ざっていたら、比べるために DLsite の更新情報を取る（取れなくても検索結果は残す）
          // 手元の版と最新の版の種類が違う（バージョン番号と日付版）ときも、比べるために取る
          let revs = cachedRevs(code);
          const rk0 = rankThreads(threads, revs);
          const local = localOf(code);
          const needRev = rk0.mixed || (parseLocalVersion(local) && rk0.latest && tier(rk0.latest) &&
            compareLocal(local, rk0.latest, revs) === 'unknown');
          if (canFetchRev && !revFresh(code) && needRev) {
            autoMsg(`${code} の DLsite 更新情報を取得中…`);
            try { revs = await getRevisions(code); } catch {}
          }
          const diff = diffResults(prev, threads, revs);
          if (diff) diff.at = Date.now();     // 「確認済み」の印を、これより前に付けたものなら外すため
          const changes = mergeChanges(prev?.changes, diff);
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

  // 列：作品コード・種類・見つけ方・最新・バージョン・パッチ/翻訳・新着/更新・URL・タイトル・印・リスト・手元の版・手元と比べて
  // （所持チェックの「ASの結果を読み込む」は見出しの名前で列を探す。後ろに列を足すのはかまわない）
  const TSV_HEAD = ['作品コード', '種類', '見つけ方', '最新', 'バージョン', 'パッチ/翻訳', '新着/更新', 'URL', 'タイトル',
    '印', 'リスト', '手元の版', '手元と比べて'];
  function exportRows(onlyFound, onlyLatest) {
    const lines = [];
    const marks = readMap(MARKS_KEY), locals = readMap(LOCAL_KEY);
    const listName = { owned: '持っている', wish: '気になる' }[auto.list];
    for (const c of auto.queue) {
      const r = auto.results[c];
      const mk = markActive(marks[c], r);
      const local = locals[c]?.v || '';
      const tail = [mk ? MARK_TEXT[mk].replace('✓ ', '') : '', listName, local];
      const blank = what => [c, what, '', '', '', '', '', '', '', ...tail, ''];
      if (!r) { if (!onlyFound) lines.push(blank('未検索')); continue; }
      if (!r.threads.length) { if (!onlyFound) lines.push(blank(r.error ? 'エラー' : 'なし')); continue; }
      const ch = r.changes ? changeText(r.changes) : '';
      const revs = cachedRevs(c);
      for (const t of rankThreads(r.threads, revs).list) {
        if (onlyLatest && !t.isLatest) continue;
        lines.push([c, t.kind === 'thread' ? 'スレッド' : '投稿内',
          t.hasCode ? 'コード' : t.byTitle ? '作品名' : 'そのほか', t.isLatest ? '★' : '',
          t.version ? 'v' + t.version : t.dateVer || '', t.isPatch ? '○' : '', t.isLatest ? ch : '', t.url, t.title,
          ...tail, t.isLatest && local ? CMP_TEXT[compareLocal(local, t, revs)] : '']);
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
    .apf-auto .apf-mks{display:flex;gap:4px;margin-top:4px}
    .apf-auto input.apf-local{width:7.5em;margin-top:4px;font-size:11px;padding:1px 4px}
    .apf-auto tr.apf-marked td{opacity:.55}
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
  // 手元の版とASの最新を比べた結果（持っている作品のリストで使う）
  function localCmp(code, local) {
    const r = auto.results[code];
    if (!local || !r?.threads.length) return null;
    const revs = cachedRevs(code);
    return compareLocal(local, rankThreads(r.threads, revs).latest, revs);
  }

  function panelStats() {
    const total = auto.queue.length;
    const left = pending().length;
    const marks = readMap(MARKS_KEY), locals = readMap(LOCAL_KEY);
    const found = auto.queue.filter(c => auto.results[c]?.threads.length);
    const staleMs = auto.staleDays * 86400000;
    return {
      total, left, done: total - left,
      found: found.length,
      urls: auto.queue.reduce((n, c) => n + (auto.results[c]?.threads.length || 0), 0),
      errors: auto.queue.filter(c => auto.results[c]?.error).length,
      changed: auto.queue.filter(c => auto.results[c]?.changes).length,
      // 見つかった作品のうち、「確認済み」「見送り」の印が付いていないもの
      unmarked: found.filter(c => !markActive(marks[c], auto.results[c])).length,
      // 前に検索してから日数がたって、もう一度検索する時期になった作品
      stale: auto.queue.filter(c => { const r = auto.results[c]; return r && !r.error && Date.now() - r.at >= staleMs; }).length,
      newer: auto.list === 'owned' ? auto.queue.filter(c => localCmp(c, locals[c]?.v) === 'newer').length : 0,
      etaMin: Math.ceil(left * (auto.interval + 1.5) / 60),
    };
  }
  const summaryText = s =>
    `対象 ${s.total}件 ／ 検索済み ${s.done}件 ／ 見つかった作品 ${s.found}件（スレッド ${s.urls}件・未確認 ${s.unmarked}件）` +
    (s.newer ? ` ／ 手元より新しい版あり ${s.newer}件` : '') +
    (s.changed ? ` ／ 新着・更新あり ${s.changed}件` : '') +
    (s.errors ? ` ／ エラー ${s.errors}件` : '') +
    (s.stale ? ` ／ ${auto.staleDays}日たって再検索の時期 ${s.stale}件` : '') +
    (s.left ? ` ／ 残り ${s.left}件（約${s.etaMin}分）` : '');
  const progWidth = s => `${s.total ? (s.done / s.total) * 100 : 0}%`;

  // 検索中は、件数・進み具合・結果の表だけを差し替える。
  // パネル全体を作り直すと、開いていた貼り付け欄が閉じたり、入力中の欄からフォーカスが外れたりするため
  // force でないときは、手元の版を入力中なら表は差し替えない（入力中の文字が消えないように）
  function refreshPanel(force = false) {
    const sum = panel?.querySelector('.apf-sum');
    if (!sum) { renderPanel(); return; }
    const s = panelStats();
    sum.textContent = summaryText(s);
    panel.querySelector('.apf-prog > div').style.width = progWidth(s);
    const res = panel.querySelector('.apf-res');
    if (!force && res.contains(document.activeElement) && document.activeElement.tagName === 'INPUT') return;
    res.replaceChildren(resultTable());
  }

  // 貼り付け欄の開閉と、入力中の文字（パネルを作り直しても消えないように覚えておく）
  let pasteOpen = false, pasteText = '';

  function renderPanel() {
    if (!panel) return;
    const s = panelStats();
    const { total, left, done, changed } = s;
    const titleCount = auto.queue.filter(c => auto.titles[c]).length;
    // どちらのリストにも入っていない作品（片方のリストの結果は、もう片方を選んでいても消さない）
    const other = auto.list === 'owned' ? 'wish' : 'owned';
    const orphans = orphanCodes(auto.results, [...auto.queue, ...auto.lists[other]], auto.titles);

    const listSel = el('select', { onchange: e => switchList(e.target.value) },
      ...Object.entries(LIST_NAMES).map(([v, t]) => el('option', { value: v, ...(auto.list === v ? { selected: '' } : {}) },
        `${t}（${(v === auto.list ? auto.queue : auto.lists[v]).length}件）`)));

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

    const views = [['unmarked', '未確認の作品（見つかったもののうち印なし）'], ['found', '見つかった作品'], ['changed', '新着・更新あり'],
      ...(auto.list === 'owned' ? [['newer', '手元より新しい版あり']] : []),
      ['marked', '確認済み・見送り'], ['none', '見つからなかった作品'], ['todo', 'まだの作品'], ['all', 'すべて']];
    if (!views.some(([v]) => v === panelView)) panelView = 'unmarked';
    const view = el('select', { onchange: e => { panelView = e.target.value; renderPanel(); } },
      ...views.map(([v, t]) => el('option', { value: v, ...(panelView === v ? { selected: '' } : {}) }, t)));

    panel.replaceChildren(
      el('h3', {}, '自動検索（作品コードで順番に検索）'),
      el('div', { class: 'apf-row' }, el('label', {}, 'リスト ', listSel),
        auto.list === 'owned' ? el('span', { class: 'apf-weak' },
          '所持チェックの「持っている作品の更新をASで確認」で入ります。手元の版を入れると、ASの最新と比べます。') : null),
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
          if (!confirm(`今のリスト（${LIST_NAMES[auto.list]}）の検索結果を消して、最初から検索し直せるようにします。よろしいですか？`)) return;
          for (const c of auto.queue) delete auto.results[c];
          saveAuto(); renderPanel();
        } }, '結果を消す'),
        changed ? el('button', { type: 'button', onclick: () => {
          for (const c of auto.queue) if (auto.results[c]) delete auto.results[c].changes;
          saveAuto(); renderPanel();
        } }, '新着・更新の印を消す') : null,
        orphans.length ? el('button', { type: 'button', onclick: () => {
          if (running) { autoMsg('止めてから押してください。'); return; }
          if (!confirm(`どちらのリストにも入っていない ${orphans.length}件の検索結果・作品名・印・手元の版を消します。よろしいですか？`)) return;
          for (const c of orphans) { delete auto.results[c]; delete auto.titles[c]; }
          const marks = readMap(MARKS_KEY), locals = readMap(LOCAL_KEY);
          for (const c of orphans) { delete marks[c]; delete locals[c]; }
          try { saveStore(MARKS_KEY, marks); saveStore(LOCAL_KEY, locals); } catch {}
          saveAuto(); autoMsg(`${orphans.length}件の古い結果を消しました。`); renderPanel();
        } }, `リストにない作品の結果を消す（${orphans.length}件）`) : null,
        el('label', {}, '表示 ', view)),
      el('div', { class: 'apf-msg' }, msgText),
      el('div', { class: 'apf-res' }, resultTable()));
  }

  // 「確認済み」「見送り」のボタン。押した印をもう一度押すと外す
  function markButtons(code, cur, after) {
    const set = s => () => {
      updateMap(MARKS_KEY, code, cur === s ? null : { s, at: Date.now() });
      after();
    };
    return [
      el('button', { type: 'button', class: 'apf-mk' + (cur === 'done' ? ' apf-on' : ''), title: '見終わった作品。新着・更新が付いたら自動で外れます', onclick: set('done') }, '確認済み'),
      el('button', { type: 'button', class: 'apf-mk' + (cur === 'skip' ? ' apf-on' : ''), title: '入手しない作品。新着・更新が付いても外れません', onclick: set('skip') }, '見送り'),
    ];
  }

  // 手元の版と最新の比べた結果のバッジ
  function cmpBadge(cmp, local, latest) {
    if (!cmp) return null;
    const to = latest ? verLabel(latest) : '';
    const text = cmp === 'newer' ? `${CMP_TEXT.newer}（手元 ${local} → ${to}）` : `${CMP_TEXT[cmp]}（手元 ${local}${to ? ' ／ 最新 ' + to : ''}）`;
    return badge(text, cmp === 'newer' ? 'apf-cmp-newer' : 'apf-old');
  }

  function resultTable() {
    const rows = [];
    const marks = readMap(MARKS_KEY), locals = readMap(LOCAL_KEY);
    const owned = auto.list === 'owned';
    for (const c of auto.queue) {
      const r = auto.results[c];
      const has = r?.threads.length > 0;
      const mk = markActive(marks[c], r);
      const local = locals[c]?.v || '';
      const rk = has ? rankThreads(r.threads, cachedRevs(c)) : null;
      const cmp = has && local ? compareLocal(local, rk.latest, cachedRevs(c)) : null;
      if (panelView === 'found' && !has) continue;
      if (panelView === 'unmarked' && (!has || mk)) continue;
      if (panelView === 'marked' && !mk) continue;
      if (panelView === 'changed' && !r?.changes) continue;
      if (panelView === 'newer' && cmp !== 'newer') continue;
      if (panelView === 'none' && (!r || has)) continue;
      if (panelView === 'todo' && r && !r.error) continue;
      const cell = !r ? el('span', { class: 'apf-weak' }, 'まだ')
        : r.error ? el('span', {}, 'エラー: ' + r.error)
        : !has ? el('span', { class: 'apf-weak' }, 'なし')
        : rk.list.map(t => el('div', { class: 'apf-t' + (t.hasCode || t.byTitle ? '' : ' apf-weak') },
            t.isLatest ? latestBadge(rk) : null, t.isLatest ? ' ' : null,
            t.isLatest && cmp ? cmpBadge(cmp, local, t) : null, t.isLatest && cmp ? ' ' : null,
            t.byTitle ? badge('作品名で見つかった（要確認）') : null, t.byTitle ? ' ' : null,
            el('a', { href: t.url, target: '_blank', rel: 'noopener' }, t.title), ' ',
            t.version ? badge('v' + t.version, 'apf-ver') : t.dateVer ? badge('日付版 ' + t.dateVer, 'apf-ver') : null, ' ',
            t.isPatch ? badge('パッチ/翻訳') : null, ' ',
            badge(t.kind === 'thread' ? 'スレッド' : '投稿内で言及'), ' ',
            t.posted ? badge(fmtDate(t.posted)) : null, ' ',
            t.forum ? badge(t.forum) : null));
      // 手元の版（持っている作品のリストでは、いつでも入れられるようにする）
      const localBox = owned || local ? el('div', {},
        el('input', { type: 'text', class: 'apf-local', value: local, placeholder: '手元の版',
          title: '手元の版（1.02 / v1.02 / 23.11.13 / 2023-11-13 など）。空にすると消します',
          onchange: e => {
            const v = e.target.value.trim();
            updateMap(LOCAL_KEY, c, v ? { v, src: 'hand' } : null);
            refreshPanel(true);
          } })) : null;
      rows.push(el('tr', { class: mk ? 'apf-marked' : '' },
        el('td', { class: 'apf-code' },
          el('a', { href: dlsiteUrl(c), target: '_blank', rel: 'noopener noreferrer' }, c), el('br'),
          el('a', { href: `/search/search?keywords=${c}`, target: '_blank', class: 'apf-weak' }, 'ASで検索'),
          r ? el('div', { class: 'apf-weak' }, fmtDate(r.at / 1000)) : null,
          r?.changes ? el('div', {}, badge(changeText(r.changes), 'apf-new')) : null,
          r?.keyword ? el('div', { class: 'apf-weak' }, '作品名でも検索した') : null,
          has || mk ? el('div', { class: 'apf-mks' }, markButtons(c, mk, () => refreshPanel(true))) : null,
          localBox),
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
  // 選んでいるリストを切り替える（それぞれのリストの中身は残る）
  function switchList(name) {
    if (running) { autoMsg('止めてから切り替えてください。'); renderPanel(); return false; }
    if (name !== auto.list) {
      auto.lists[auto.list] = auto.queue;
      auto.list = name;
      auto.queue = auto.lists[name] || [];
      saveAuto();
      autoMsg(`「${LIST_NAMES[name]}」のリストにしました（${auto.queue.length}件）。`);
    }
    renderPanel();
    return true;
  }
  function setQueue(codes, list) {
    if (running) { autoMsg('止めてから入れ替えてください。'); return; }
    if (list && list !== auto.list) { auto.lists[auto.list] = auto.queue; auto.list = list; }
    auto.queue = codes;
    saveAuto();
    const left = pending().length;
    autoMsg(`「${LIST_NAMES[auto.list]}」に ${codes.length}件を読み込みました（そのうち検索が必要なのは ${left}件）。「開始」を押すと検索します。`);
    renderPanel();
  }

  // 所持チェックから渡された、フォルダ名から読んだ手元の版を入れる。手で入れた版は上書きしない。
  // フォルダ名から版が読めなくなった作品は、前にフォルダ名から入れた版を消す
  function setFolderVersions(codes, versions) {
    const m = readMap(LOCAL_KEY);
    for (const c of codes) {
      if (m[c]?.src === 'hand') continue;
      if (versions[c]) m[c] = { v: versions[c], src: 'folder' };
      else if (m[c]?.src === 'folder') delete m[c];
    }
    try { saveStore(LOCAL_KEY, m); } catch {}
    return Object.keys(versions).length;
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
    const m = location.hash.match(/^#apf-(auto|owned)=(.*)$/);
    if (m) {
      history.replaceState(null, '', location.pathname + location.search + '#apf-auto');
      if (m[1] === 'owned') {
        const o = parseOwnedList(decodeURIComponent(m[2]));
        if (o.codes.length) {
          const n = running ? 0 : setFolderVersions(o.codes, o.versions);
          setQueue(o.codes, 'owned');
          if (!running) autoMsg(`${msgText}（フォルダ名から手元の版を ${n}件 読み取りました）`);
          return;
        }
      } else {
        const codes = importCodes(decodeURIComponent(m[2]));
        if (codes.length) { setQueue(codes, 'wish'); return; }
      }
    }
    renderPanel();
    // 前に検索してから日数がたった作品があれば知らせる
    const s = panelStats();
    if (!running && s.stale && !msgText) {
      autoMsg(`前の検索から${auto.staleDays}日以上たった作品が ${s.stale}件あります。「開始」で検索し直すと、新着・更新がわかります。`);
    }
  }

  // ---------- AS のフォーラム・スレッドのページ：持っている／気になる作品に印を付ける ----------
  function markForumPage() {
    addStyle();
    const codeIn = (...ss) => { for (const s of ss) { const c = s && parseCode(s); if (c) return c; } return null; };
    const safeDecode = s => { try { return decodeURIComponent(s); } catch { return s; } };
    // スレッドの一覧
    for (const item of document.querySelectorAll('.structItem--thread')) {
      const t = item.querySelector('.structItem-title');
      const a = t?.querySelector('a[href^="/threads/"]');
      if (!t || !a || t.querySelector('.apf-fb')) continue;
      const code = codeIn(a.textContent, item.querySelector('a.thread-thumbnail-link')?.title, safeDecode(a.getAttribute('href')));
      const bs = code ? workBadges(code) : [];
      if (bs.length) t.append(el('span', { class: 'apf-fb' }, ' ', ...bs));
    }
    // スレッドのページ：見出しの横に印と、「確認済み」「見送り」のボタン
    const h1 = document.querySelector('h1.p-title-value');
    if (h1 && !document.querySelector('.apf-fb-thread')) {
      const code = codeIn(h1.textContent, safeDecode(location.pathname));
      if (!code || (!listOf(code) && !auto.results[code])) return;
      const box = el('div', { class: 'apf-fb-thread apf-badges' });
      const draw = () => box.replaceChildren(...workBadges(code), ...markButtons(code, markOf(code), draw));
      draw();
      h1.after(box);
    }
  }

  // ---------- DLsite の作品ページ：ASの検索結果を出す ----------
  const dlsiteCss = `
    .apf-dl{position:fixed;right:12px;bottom:12px;z-index:2147483000;max-width:420px;padding:8px 10px;
      background:#fff;color:#111;border:1px solid #9ca3af;border-radius:8px;box-shadow:0 4px 16px rgba(0,0,0,.25);
      font:12px/1.6 system-ui,"Yu Gothic UI",sans-serif}
    .apf-dl a{color:#1d4ed8;word-break:break-all}
    .apf-dl .apf-dl-head{display:flex;gap:6px;align-items:center;font-weight:bold;margin-bottom:4px}
    .apf-dl .apf-dl-x{margin-left:auto;cursor:pointer;border:0;background:transparent;font-size:16px;line-height:1;color:inherit}
    .apf-dl .apf-weak{opacity:.65}
    .apf-dl .apf-new{background:#c2410c;color:#fff;border-color:#c2410c;font-weight:bold}
  `;
  function showDlsiteBox() {
    const m = location.pathname.match(/product_id\/((?:RJ|VJ|BJ|RE)\d{6,8})/i);
    if (!m) return;
    const code = m[1].toUpperCase();
    const r = auto.results[code];
    // どちらのリストにも入っておらず、検索もしていない作品では何も出さない
    if (!listOf(code) && !r) return;
    addStyle();
    const s = document.createElement('style');
    s.textContent = dlsiteCss;
    document.head.appendChild(s);
    const mk = markOf(code), local = localOf(code);
    const revs = cachedRevs(code);
    const rk = r?.threads.length ? rankThreads(r.threads, revs) : null;
    const t = rk?.latest;
    const box = el('div', { class: 'apf-dl' },
      el('div', { class: 'apf-dl-head' }, 'AS Patch Finder', ...workBadges(code),
        el('button', { type: 'button', class: 'apf-dl-x', title: '閉じる', onclick: () => box.remove() }, '×')),
      !r ? el('div', {}, 'まだASで検索していません。')
        : r.error ? el('div', {}, `前回の検索はエラーでした（${fmtDate(r.at / 1000)}）。`)
        : !rk ? el('div', {}, `ASで見つかりませんでした（${fmtDate(r.at / 1000)}に検索）。`)
        : el('div', {}, `ASのスレッド ${r.threads.length}件（${fmtDate(r.at / 1000)}に検索）`),
      r?.changes ? el('div', {}, badge(changeText(r.changes), 'apf-new')) : null,
      t ? el('div', {}, '最新: ', el('a', { href: t.url, target: '_blank', rel: 'noopener noreferrer' }, t.title), ' ',
        t.version ? badge('v' + t.version, 'apf-ver') : t.dateVer ? badge('日付版 ' + t.dateVer, 'apf-ver') : null, ' ',
        t.isPatch ? badge('パッチ/翻訳') : null) : null,
      t && local ? el('div', {}, cmpBadge(compareLocal(local, t, revs), local, t)) : null,
      !t && local ? el('div', { class: 'apf-weak' }, `手元の版: ${local}`) : null,
      el('div', {}, el('a', { href: `https://www.anime-sharing.com/search/search?keywords=${code}`, target: '_blank', rel: 'noopener noreferrer' }, 'ASで検索'),
        el('span', { class: 'apf-weak' }, mk ? `　${MARK_TEXT[mk]}` : '')));
    document.body.appendChild(box);
  }

  // ---------- 起動 ----------
  if (onSearch) {
    init();
    const checkHash = () => { if (/^#apf-(auto|owned)/.test(location.hash)) openPanel(); };
    window.addEventListener('hashchange', checkHash);
    checkHash();
    // 整理バーからも開けるようにする
    const bar = document.querySelector('.apf-bar');
    if (bar) {
      bar.querySelector('.apf-status').before(el('button', { type: 'button', onclick: () => { location.hash = 'apf-auto'; } }, '自動検索…'));
    }
  } else if (onAS) {
    markForumPage();
  } else if (/(^|\.)dlsite\.com$/.test(location.hostname)) {
    showDlsiteBox();
  }
})();
