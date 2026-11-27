// 所持チェック ブックマーク係：DLsite のページで、所持チェックから渡された中身を読み、
// 右下に「何をするか」と「実行する」ボタンを出す。押されたときだけ書き換えを頼む。
'use strict';
(function () {
  const hash = location.hash;
  const payload = self.GptBookmarkOps.parsePayload(hash);
  if (!payload) return;
  // ページを再読み込みしても、もう一度出ないように # を消す
  history.replaceState(null, '', location.pathname + location.search);

  // ページのスクリプトから触れないように、閉じた shadow root の中に出す
  const host = document.createElement('div');
  host.style.cssText = 'position:fixed;right:16px;bottom:16px;z-index:2147483647;';
  const shadow = host.attachShadow({ mode: 'closed' });
  shadow.innerHTML = `
    <style>
      .box { font: 14px/1.6 "Yu Gothic UI", "Meiryo", sans-serif; color: #1f2328; background: #fff;
        border: 1px solid #8c959f; border-radius: 8px; box-shadow: 0 4px 16px rgba(0,0,0,.25);
        padding: 12px 14px; width: 340px; }
      .title { font-weight: bold; margin-bottom: 6px; }
      .msg { white-space: pre-wrap; margin-bottom: 10px; }
      .err { color: #cf222e; }
      .row { display: flex; gap: 8px; justify-content: flex-end; }
      button { font: inherit; padding: 4px 14px; border-radius: 6px; border: 1px solid #8c959f; background: #f6f8fa; cursor: pointer; }
      button.go { background: #1f6feb; border-color: #1f6feb; color: #fff; }
      button[hidden] { display: none; }
    </style>
    <div class="box">
      <div class="title">所持チェック ブックマーク係</div>
      <div class="msg">お気に入りを調べています…</div>
      <div class="row"><button class="go" hidden>実行する</button><button class="no">やめる</button></div>
    </div>`;
  const msg = shadow.querySelector('.msg');
  const go = shadow.querySelector('.go');
  const no = shadow.querySelector('.no');
  document.documentElement.appendChild(host);

  const close = () => host.remove();
  const show = (text, isErr) => { msg.textContent = text; msg.classList.toggle('err', !!isErr); };
  no.addEventListener('click', (e) => { if (e.isTrusted) close(); });

  const describe = (p) => {
    const where = `お気に入り「${p.folderLabel}」`;
    if (payload.op === 'delete') return [p.remove.length, `${where}から ${p.remove.length} 件を消します。`];
    if (payload.op === 'add') return [p.add.length, `${where}に ${p.add.length} 件を足します。`];
    return [p.move.length, `${where}の中の ${p.move.length} 件を「${p.sub}」に移します。` + (p.createSub ? `\n（「${p.sub}」は新しく作ります）` : '')];
  };

  chrome.runtime.sendMessage({ type: 'plan', hash }, (res) => {
    if (chrome.runtime.lastError || !res || res.error) { show('お気に入りを読めませんでした。何も変えていません。', true); no.textContent = '閉じる'; return; }
    const p = res.plan;
    if (p.error) { show(p.error, true); no.textContent = '閉じる'; return; }
    const [n, text] = describe(p);
    if (n === 0) { show(`お気に入り「${p.folderLabel}」に当てはまるものはありません。何も変えていません。`); no.textContent = '閉じる'; return; }
    show(text + '\n押すまでは何も変わりません。');
    go.hidden = false;
  });

  go.addEventListener('click', (e) => {
    if (!e.isTrusted) return; // ページのスクリプトからの「押した」は受け付けない
    go.hidden = true; no.hidden = true;
    show('書き換えています…');
    chrome.runtime.sendMessage({ type: 'apply', hash }, (res) => {
      no.hidden = false; no.textContent = '閉じる';
      if (chrome.runtime.lastError || !res || res.error) { show('書き換えられませんでした。', true); return; }
      if (res.plan.error) { show(res.plan.error, true); return; }
      const d = res.done;
      const parts = [];
      if (payload.op === 'delete') parts.push(`${d.removed} 件を消しました。`);
      if (payload.op === 'add') parts.push(`${d.added} 件を足しました。`);
      if (payload.op === 'move') parts.push(`${d.moved} 件を「${res.plan.sub}」に移しました。`);
      if (d.failed) parts.push(`${d.failed} 件はできませんでした。`);
      parts.push('所持チェックに戻って OK を押してください。');
      show(parts.join('\n'), d.failed > 0);
    });
  });
})();
