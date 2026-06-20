'use strict';

function parseClientUrl(pathname) {
  const m = /\/client\/(T[A-Z0-9]+)\/([CDG][A-Z0-9]+)/i.exec(pathname || '');
  return m ? { teamId: m[1], channelId: m[2] } : null;
}

function getTokenForTeam(localConfigRaw, teamId) {
  try {
    const cfg = JSON.parse(localConfigRaw);
    const t = cfg && cfg.teams && cfg.teams[teamId];
    return (t && t.token) || null;
  } catch (e) { return null; }
}

function inferApiBase(localConfigRaw, teamId) {
  try {
    const cfg = JSON.parse(localConfigRaw);
    const t = cfg && cfg.teams && cfg.teams[teamId];
    if (!t) return null;
    if (t.url) return new URL(t.url).origin + '/api/';
    if (t.domain) return 'https://' + t.domain + '.slack.com/api/';
    return null;
  } catch (e) { return null; }
}

function workspaceFromConfig(localConfigRaw, teamId) {
  let name = null;
  try {
    const cfg = JSON.parse(localConfigRaw);
    const t = cfg && cfg.teams && cfg.teams[teamId];
    name = (t && t.name) || null;
  } catch (e) { /* ignore */ }
  return { team_id: teamId, name };
}

function sanitizeExportFilename(name, opts) {
  opts = opts || {};
  const fallback = opts.fallback || 'slack-export';
  const maxLength = opts.maxLength || 120;
  let s = String(name == null ? '' : name);
  s = s.replace(/[\/\\]/g, '-');          // path separators
  s = s.replace(/[\x00-\x1f\x7f]/g, '');  // control chars
  s = s.replace(/[<>:"|?*]/g, '-');       // reserved chars
  s = s.replace(/\.{2,}/g, '-');          // collapse .. (no traversal)
  s = s.replace(/-{2,}/g, '-');           // collapse repeated dashes
  s = s.replace(/^[-.]+/, '');            // strip leading dashes/dots
  s = s.replace(/[-.\s]+$/, '');          // strip trailing dashes/dots/space
  s = s.trim();
  if (!s) s = fallback;
  if (!/\.json$/i.test(s)) s = s + '.json';
  if (s.length > maxLength) {
    const base = s.slice(0, maxLength - 5).replace(/[-.]+$/, '');
    s = base + '.json';
  }
  return s;
}

function getNextCursor(resp) {
  return (resp && resp.response_metadata && resp.response_metadata.next_cursor) || null;
}
function responseHasMore(resp) { return !!(resp && resp.has_more); }

function accumulateByTs(map, items) {
  let added = 0;
  for (const it of (items || [])) {
    if (it && it.ts && !map.has(it.ts)) { map.set(it.ts, it); added++; }
  }
  return added;
}

function finalizeThreadReplies(map, threadTs) {
  return Array.from(map.values())
    .filter((m) => m.ts !== threadTs)
    .sort((a, b) => parseFloat(a.ts) - parseFloat(b.ts));
}

function reactionNeedsBackfill(r) {
  return !!r && (r.count | 0) > ((r.users && r.users.length) || 0);
}
function messageNeedsReactionBackfill(m) {
  return !!m && Array.isArray(m.reactions) && m.reactions.some(reactionNeedsBackfill);
}

function resolveActorRef(message) {
  if (!message) return null;
  if (message.user) return { kind: 'user', id: message.user };
  if (message.bot_id) return { kind: 'bot', id: message.bot_id, embeddedProfile: message.bot_profile || null, username: message.username || null };
  if (message.username) return { kind: 'unknown', id: null, username: message.username };
  return null;
}

function buildUserEntry(u) {
  const p = u.profile || {};
  const name = p.display_name || p.real_name || u.name || u.id;
  return { id: u.id, kind: 'user', is_bot: !!u.is_bot, name, real_name: p.real_name || u.real_name || null, display_name: p.display_name || null };
}

function buildBotEntry(b, botId) {
  const name = (b && b.name) || botId;
  return { id: botId, kind: 'bot', is_bot: true, name, real_name: name };
}

function pickInlineName(entry) {
  return entry ? (entry.name || entry.real_name || entry.id) : null;
}

function collectActorRefs(messages) {
  const userIds = new Set();
  const botIds = new Set();
  const embeddedBotProfiles = new Map();
  function visit(m) {
    const ref = resolveActorRef(m);
    if (ref) {
      if (ref.kind === 'user' && ref.id) userIds.add(ref.id);
      else if (ref.kind === 'bot' && ref.id) {
        botIds.add(ref.id);
        if (ref.embeddedProfile && !embeddedBotProfiles.has(ref.id)) embeddedBotProfiles.set(ref.id, ref.embeddedProfile);
      }
    }
    if (Array.isArray(m.reactions)) for (const r of m.reactions) for (const u of (r.users || [])) userIds.add(u);
    if (Array.isArray(m.replies)) for (const rep of m.replies) visit(rep);
  }
  for (const m of (messages || [])) visit(m);
  return { userIds, botIds, embeddedBotProfiles };
}

function createReport() {
  const counts = { messages: 0, replies: 0, threads: 0, reactions: 0, truncated_reactions: 0, unresolved_actors: 0 };
  const warnings = [];
  return {
    counts, warnings,
    setBaseCounts(b) {
      counts.messages = b.messages | 0;
      counts.replies = b.replies | 0;
      counts.threads = b.threads | 0;
      counts.reactions = b.reactions | 0;
    },
    addTruncatedReaction(ts, emoji, got, expected) {
      counts.truncated_reactions++;
      warnings.push({ type: 'reaction_truncated', ts, emoji, got, expected });
    },
    addUnresolvedActor(id, kind) {
      counts.unresolved_actors++;
      warnings.push({ type: 'actor_unresolved', id, kind });
    },
    build(exportedAt) {
      return {
        exported_at: exportedAt,
        exported_by: 'slack-autocomplete-electron',
        version: 1,
        complete: counts.truncated_reactions === 0 && counts.unresolved_actors === 0,
        counts: Object.assign({}, counts),
        warnings: warnings.slice(),
      };
    },
  };
}

const TIERS = { history: 1200, reactions: 3000, users: 600, info: 1200, default: 1200 };

function methodTier(method) {
  if (method === 'conversations.history' || method === 'conversations.replies') return 'history';
  if (method === 'reactions.get') return 'reactions';
  if (method === 'users.info' || method === 'bots.info') return 'users';
  if (method === 'conversations.info' || method === 'conversations.genericInfo') return 'info';
  return 'default';
}
function tierIntervalMs(method) { return TIERS[methodTier(method)] || TIERS.default; }

function parseRetryAfter(value) {
  const n = parseInt(value, 10);
  return (isFinite(n) && n >= 0) ? n : 5;
}
function backoffDelay(attempt) { return Math.min(30000, 500 * Math.pow(2, attempt)); }

function* streamExportJson(doc) {
  yield '{\n';
  yield '"export":' + JSON.stringify(doc.export) + ',\n';
  yield '"workspace":' + JSON.stringify(doc.workspace) + ',\n';
  yield '"channel":' + JSON.stringify(doc.channel) + ',\n';
  yield '"users":' + JSON.stringify(doc.users) + ',\n';
  yield '"messages":[\n';
  const arr = doc.messages || [];
  for (let i = 0; i < arr.length; i++) {
    yield JSON.stringify(arr[i]) + (i < arr.length - 1 ? ',\n' : '\n');
  }
  yield ']\n}\n';
}

function throwIfAborted(signal) {
  if (signal && signal.aborted) { const e = new Error('aborted'); e.name = 'AbortError'; throw e; }
}

async function fetchAllHistory(apiCall, opts, hooks) {
  hooks = hooks || {};
  const channel = opts.channel;
  const map = new Map();
  let cursor = null;
  for (;;) {
    throwIfAborted(hooks.signal);
    const params = { channel, limit: 200, ignore_replies: true, no_user_profile: true };
    if (cursor) params.cursor = cursor;
    const resp = await apiCall('conversations.history', params);
    if (!resp || resp.ok === false) throw new Error('conversations.history failed: ' + (resp && resp.error));
    accumulateByTs(map, resp.messages || []);
    if (hooks.onProgress) hooks.onProgress('messages', map.size, null);
    if (!responseHasMore(resp)) break;
    const next = getNextCursor(resp);
    if (!next) throw new Error('history pagination stalled: has_more without next_cursor');
    if (cursor && next === cursor) throw new Error('history pagination stalled: cursor did not advance');
    cursor = next;
  }
  return Array.from(map.values()).sort((a, b) => parseFloat(a.ts) - parseFloat(b.ts));
}

async function fetchThreadReplies(apiCall, opts, hooks) {
  hooks = hooks || {};
  const channel = opts.channel;
  const threadTs = opts.threadTs;
  const map = new Map();
  let cursor = null;
  let useWindow = false;
  let maxTs = null;
  let noProgress = 0;
  for (;;) {
    throwIfAborted(hooks.signal);
    const params = { channel, ts: threadTs, limit: 200 };
    if (useWindow) { if (maxTs) { params.oldest = maxTs; params.inclusive = false; } }
    else if (cursor) { params.cursor = cursor; }
    const resp = await apiCall('conversations.replies', params);
    if (!resp || resp.ok === false) throw new Error('conversations.replies failed: ' + (resp && resp.error));
    const items = resp.messages || [];
    const added = accumulateByTs(map, items);
    for (const m of items) { if (m && m.ts && (maxTs === null || parseFloat(m.ts) > parseFloat(maxTs))) maxTs = m.ts; }
    if (hooks.onProgress) hooks.onProgress('thread-page', map.size, null);
    if (!responseHasMore(resp)) break;
    if (!useWindow) {
      const next = getNextCursor(resp);
      if (next && next !== cursor) { cursor = next; continue; }
      useWindow = true; // no/stale cursor -> switch to oldest-window fallback
    }
    if (useWindow) { if (added === 0) { if (++noProgress >= 2) break; } else noProgress = 0; }
  }
  return finalizeThreadReplies(map, threadTs);
}

function extractReactionUsers(resp, name) {
  const msg = resp.message || (resp.messages && resp.messages[0]) || null;
  if (!msg || !Array.isArray(msg.reactions)) return null;
  const found = msg.reactions.find((x) => x.name === name);
  return found ? (found.users || []) : null;
}

async function backfillReactions(apiCall, ctx, messages, report, hooks) {
  hooks = hooks || {};
  const targets = [];
  function visit(m) {
    if (Array.isArray(m.reactions)) for (const r of m.reactions) targets.push({ m, r });
    if (Array.isArray(m.replies)) for (const rep of m.replies) visit(rep);
  }
  for (const m of (messages || [])) visit(m);

  let done = 0;
  const total = targets.length;
  for (const { m, r } of targets) {
    throwIfAborted(hooks.signal);
    if (reactionNeedsBackfill(r)) {
      let resp = null;
      try { resp = await apiCall('reactions.get', { channel: ctx.channel, timestamp: m.ts, full: true }); } catch (e) { resp = null; }
      const full = (resp && resp.ok) ? extractReactionUsers(resp, r.name) : null;
      const have = (r.users && r.users.length) || 0;
      if (full && full.length >= (r.count | 0)) { r.users = full; r.users_truncated = false; }
      else {
        if (full && full.length > have) r.users = full;
        r.users_truncated = true;
        report.addTruncatedReaction(m.ts, r.name, (r.users && r.users.length) || 0, r.count | 0);
      }
    } else {
      r.users_truncated = false;
    }
    done++;
    if (hooks.onProgress) hooks.onProgress('reactions', done, total);
  }
}

async function resolveActors(apiCall, refs, report, hooks) {
  hooks = hooks || {};
  const users = {};
  const total = refs.userIds.size + refs.botIds.size;
  let done = 0;
  for (const id of refs.userIds) {
    throwIfAborted(hooks.signal);
    let resp = null;
    try { resp = await apiCall('users.info', { user: id }); } catch (e) { resp = null; }
    if (resp && resp.ok && resp.user) users[id] = buildUserEntry(resp.user);
    else { users[id] = { id, kind: 'user', name: id, unresolved: true }; report.addUnresolvedActor(id, 'user'); }
    done++;
    if (hooks.onProgress) hooks.onProgress('actors', done, total);
  }
  for (const id of refs.botIds) {
    throwIfAborted(hooks.signal);
    const prof = refs.embeddedBotProfiles.get(id);
    if (prof) { users[id] = buildBotEntry(prof, id); }
    else {
      let resp = null;
      try { resp = await apiCall('bots.info', { bot: id }); } catch (e) { resp = null; }
      if (resp && resp.ok && resp.bot) users[id] = buildBotEntry(resp.bot, id);
      else { users[id] = { id, kind: 'bot', name: id, unresolved: true }; report.addUnresolvedActor(id, 'bot'); }
    }
    done++;
    if (hooks.onProgress) hooks.onProgress('actors', done, total);
  }
  return users;
}

module.exports = {
  parseClientUrl, getTokenForTeam, inferApiBase, workspaceFromConfig, sanitizeExportFilename,
  getNextCursor, responseHasMore, accumulateByTs, finalizeThreadReplies, reactionNeedsBackfill, messageNeedsReactionBackfill,
  resolveActorRef, buildUserEntry, buildBotEntry, collectActorRefs, pickInlineName, createReport,
  TIERS, methodTier, tierIntervalMs, parseRetryAfter, backoffDelay, streamExportJson, fetchAllHistory, fetchThreadReplies,
  backfillReactions, resolveActors,
};
