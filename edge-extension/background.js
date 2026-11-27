// 所持チェック ブックマーク係：お気に入りを実際に書き換える部分（service worker）。
// content.js からの「plan」（何をするか数える）と「apply」（書き換える）だけを受け付ける。
'use strict';
importScripts('ops.js');
const { planOps, parsePayload } = self.GptBookmarkOps;

function fromDlsite(sender) {
  try { return sender.id === chrome.runtime.id && new URL(sender.url).origin === 'https://www.dlsite.com'; } catch (e) { return false; }
}

async function apply(payload) {
  const plan = planOps(await chrome.bookmarks.getTree(), payload);
  const done = { removed: 0, added: 0, moved: 0, failed: 0 };
  if (plan.error) return { plan, done };
  for (const id of plan.remove) {
    try { await chrome.bookmarks.remove(id); done.removed++; } catch (e) { done.failed++; }
  }
  for (const b of plan.add) {
    try { await chrome.bookmarks.create({ parentId: plan.parentId, title: b.title, url: b.url }); done.added++; } catch (e) { done.failed++; }
  }
  if (plan.move.length > 0) {
    let subId = plan.subId;
    if (plan.createSub) {
      try { subId = (await chrome.bookmarks.create({ parentId: plan.parentId, title: plan.sub })).id; } catch (e) { done.failed += plan.move.length; return { plan, done }; }
    }
    for (const id of plan.move) {
      try { await chrome.bookmarks.move(id, { parentId: subId }); done.moved++; } catch (e) { done.failed++; }
    }
  }
  return { plan, done };
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  const payload = msg && parsePayload(msg.hash);
  if (!fromDlsite(sender) || !payload) return false;
  if (msg.type === 'plan') {
    chrome.bookmarks.getTree().then((t) => sendResponse({ plan: planOps(t, payload) }), (e) => sendResponse({ error: String(e) }));
    return true;
  }
  if (msg.type === 'apply') {
    apply(payload).then(sendResponse, (e) => sendResponse({ error: String(e) }));
    return true;
  }
  return false;
});
