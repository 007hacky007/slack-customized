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

module.exports = {
  WATCHLIST_CAP,
  SUB_LOG_MAX,
  USER_ID_RE,
  emptyStore,
  dedupeValidIds,
  parseWatchlist
};
