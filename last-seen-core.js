'use strict';

// Pure logic for last-seen presence tracking. No Electron, no fs, no DOM.
// Unit-tested in test/last-seen-core.test.js and copied into the app dir by
// the build script (like export-core.js).

const WATCHLIST_CAP = 100;   // max watchlist ids merged into a presence_sub frame
const SUB_LOG_MAX = 100;     // subscription-log ring buffer length

const USER_ID_RE = /^[UW][A-Z0-9]{2,}$/;

function emptyStore() {
  return { users: {}, subscriptionLog: [], pendingBaseline: [], lastSubscribedIds: [] };
}

function dedupeValidIds(list) {
  const out = [];
  const seen = new Set();
  if (!Array.isArray(list)) return out;
  for (const raw of list) {
    if (typeof raw !== 'string') continue;
    const id = raw.trim();
    if (!USER_ID_RE.test(id) || seen.has(id)) continue;
    seen.add(id);
    out.push(id);
  }
  return out;
}

function parseWatchlist(raw) {
  let obj = raw;
  if (typeof raw === 'string') {
    try { obj = JSON.parse(raw); }
    catch (e) { return { ok: false, users: [], error: String((e && e.message) || e) }; }
  }
  if (!obj || typeof obj !== 'object') {
    return { ok: false, users: [], error: 'watchlist is not an object' };
  }
  return { ok: true, users: dedupeValidIds(obj.users), error: null };
}

function mergePresenceSub(frameString, watchlistIds) {
  const passthrough = { changed: false, frame: frameString, clientIds: null, injectedIds: null };
  if (typeof frameString !== 'string') return passthrough;
  let obj;
  try { obj = JSON.parse(frameString); }
  catch (e) { return passthrough; }
  if (!obj || typeof obj !== 'object' || obj.type !== 'presence_sub') return passthrough;

  const clientIds = dedupeValidIds(obj.ids);
  const clientSet = new Set(clientIds);
  const injectedIds = [];
  for (const id of dedupeValidIds(watchlistIds)) {
    if (clientSet.has(id)) continue;
    injectedIds.push(id);
    if (injectedIds.length >= WATCHLIST_CAP) break;
  }
  if (injectedIds.length === 0) {
    return { changed: false, frame: frameString, clientIds, injectedIds };
  }
  const merged = Object.assign({}, obj, { ids: clientIds.concat(injectedIds) });
  return { changed: true, frame: JSON.stringify(merged), clientIds, injectedIds };
}

function recordSubscription(store, clientIds, injectedIds, nowIso) {
  const cleanClient = dedupeValidIds(clientIds);
  const cleanInjected = dedupeValidIds(injectedIds);
  const allIds = dedupeValidIds(cleanClient.concat(cleanInjected));
  const prev = new Set(store.lastSubscribedIds || []);

  const pending = new Set(store.pendingBaseline || []);
  for (const id of allIds) {
    if (!prev.has(id)) pending.add(id);
  }
  // Drop pending-baseline ids that are no longer subscribed at all.
  const allSet = new Set(allIds);
  for (const id of Array.from(pending)) {
    if (!allSet.has(id)) pending.delete(id);
  }
  store.pendingBaseline = Array.from(pending);
  store.lastSubscribedIds = allIds;

  store.subscriptionLog.push({ at: nowIso, clientIds: cleanClient, injectedIds: cleanInjected });
  if (store.subscriptionLog.length > SUB_LOG_MAX) {
    store.subscriptionLog = store.subscriptionLog.slice(-SUB_LOG_MAX);
  }
  return store;
}

module.exports = {
  WATCHLIST_CAP,
  SUB_LOG_MAX,
  USER_ID_RE,
  emptyStore,
  dedupeValidIds,
  parseWatchlist,
  mergePresenceSub,
  recordSubscription
};
