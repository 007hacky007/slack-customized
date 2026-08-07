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

// allSubscribedIds: union of ids subscribed across every sender (window/socket).
// Baseline bookkeeping must run against the union, not this frame alone —
// otherwise one window's small presence_sub prunes ids another window still
// subscribes to. Omitted (single-sender callers, tests): the frame is the union.
function recordSubscription(store, clientIds, injectedIds, nowIso, allSubscribedIds) {
  const cleanClient = dedupeValidIds(clientIds);
  const cleanInjected = dedupeValidIds(injectedIds);
  const allIds = allSubscribedIds === undefined
    ? dedupeValidIds(cleanClient.concat(cleanInjected))
    : dedupeValidIds(allSubscribedIds);
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

// A loaded store is stale by definition: presence events stopped when the app
// quit, so any persisted lastPresence is untrustworthy and every previously
// subscribed id must be re-baselined before its next event counts as a real
// transition.
function sanitizeLoadedStore(store) {
  if (!store || typeof store !== 'object') return store;
  if (!store.users || typeof store.users !== 'object') store.users = {};
  for (const id of Object.keys(store.users)) {
    const entry = store.users[id];
    if (!entry || typeof entry !== 'object') { delete store.users[id]; continue; }
    entry.lastPresence = null;
  }
  const pending = new Set(dedupeValidIds(store.pendingBaseline));
  for (const id of dedupeValidIds(store.lastSubscribedIds)) pending.add(id);
  store.pendingBaseline = Array.from(pending);
  store.lastSubscribedIds = [];
  return store;
}

function formatTransitionLine(t) {
  return JSON.stringify({ at: t.at, user: t.user, presence: t.presence, baseline: !!t.baseline });
}

function describeLastSeen(entry) {
  const state = entry && entry.lastPresence === 'active' ? 'online' : 'offline';
  return { state, lastOnlineAt: (entry && entry.lastActiveAt) || null };
}

function orderTrackedIds(users) {
  if (!users || typeof users !== 'object') return [];
  const ids = Object.keys(users);
  const rank = (id) => {
    const e = users[id];
    const online = !!(e && typeof e === 'object' && e.lastPresence === 'active');
    const at = (e && typeof e === 'object' && e.lastActiveAt) || '';
    return { online, at };
  };
  return ids.sort((a, b) => {
    const ra = rank(a), rb = rank(b);
    if (ra.online !== rb.online) return ra.online ? -1 : 1;
    if (ra.at !== rb.at) return ra.at > rb.at ? -1 : 1;
    return a < b ? -1 : (a > b ? 1 : 0);
  });
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

function filterRoster(roster, query, max) {
  const q = String(query || '').trim().toLowerCase();
  const limit = max || 10;
  const out = [];
  if (!Array.isArray(roster) || q.length < 2) return out;
  for (const e of roster) {
    if (!e || typeof e !== 'object') continue;
    const fields = [e.name, e.real_name, e.display_name];
    for (const f of fields) {
      if (typeof f === 'string' && f.toLowerCase().indexOf(q) !== -1) {
        out.push(e);
        break;
      }
    }
    if (out.length >= limit) break;
  }
  return out;
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
  sanitizeLoadedStore,
  formatTransitionLine,
  describeLastSeen,
  orderTrackedIds,
  applyWatchlistUpdate,
  filterRoster
};
