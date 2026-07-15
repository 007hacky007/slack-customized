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

function applyPresenceEvent(store, event, nowIso) {
  const transitions = [];
  if (!event || typeof event !== 'object') return { store, transitions };
  const presence = event.presence;
  if (presence !== 'active' && presence !== 'away') return { store, transitions };

  let ids = event.ids;
  if (!Array.isArray(ids)) ids = event.user ? [event.user] : [];
  const pending = new Set(store.pendingBaseline || []);

  for (const raw of ids) {
    if (typeof raw !== 'string' || !USER_ID_RE.test(raw)) continue;
    const id = raw;
    let entry = store.users[id];
    const isNew = !entry;
    if (isNew) {
      entry = { lastPresence: null, lastActiveAt: null, lastAwayAt: null,
                lastEventAt: null, firstTrackedAt: nowIso };
      store.users[id] = entry;
    }
    const changed = entry.lastPresence !== presence;
    if (presence === 'active') entry.lastActiveAt = nowIso;
    else entry.lastAwayAt = nowIso;
    entry.lastPresence = presence;
    entry.lastEventAt = nowIso;

    const wasPending = pending.has(id);
    if (wasPending) pending.delete(id);
    if (changed) {
      transitions.push({ at: nowIso, user: id, presence, baseline: !!wasPending });
    }
  }
  store.pendingBaseline = Array.from(pending);
  return { store, transitions };
}

function formatTransitionLine(t) {
  return JSON.stringify({ at: t.at, user: t.user, presence: t.presence, baseline: !!t.baseline });
}

function describeLastSeen(entry) {
  const state = entry && entry.lastPresence === 'active' ? 'online' : 'offline';
  return { state, lastOnlineAt: (entry && entry.lastActiveAt) || null };
}

function applyWatchlistUpdate(users, change) {
  const current = dedupeValidIds(users);
  if (!change || typeof change !== 'object') return { users: current, changed: false };
  if (typeof change.add === 'string') {
    const id = change.add.trim();
    if (USER_ID_RE.test(id) && current.indexOf(id) === -1) {
      return { users: current.concat([id]), changed: true };
    }
    return { users: current, changed: false };
  }
  if (typeof change.remove === 'string') {
    const id = change.remove.trim();
    const next = current.filter((u) => u !== id);
    return { users: next, changed: next.length !== current.length };
  }
  return { users: current, changed: false };
}

module.exports = {
  WATCHLIST_CAP,
  SUB_LOG_MAX,
  USER_ID_RE,
  emptyStore,
  dedupeValidIds,
  parseWatchlist,
  mergePresenceSub,
  recordSubscription,
  applyPresenceEvent,
  formatTransitionLine,
  describeLastSeen,
  applyWatchlistUpdate
};
