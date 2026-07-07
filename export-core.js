'use strict';

function parseClientUrl(pathname) {
  const m = /\/client\/(T[A-Z0-9]+)\/([CDG][A-Z0-9]+)/i.exec(pathname || '');
  return m ? { teamId: m[1], channelId: m[2] } : null;
}

function parseClientTeam(pathname) {
  const m = /\/client\/(T[A-Z0-9]+)/i.exec(pathname || '');
  return m ? { teamId: m[1] } : null;
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
  const ext = /^[a-z0-9]{1,8}$/i.test(opts.ext || '') ? opts.ext.toLowerCase() : 'json';
  const extRe = new RegExp('\\.' + ext + '$', 'i');
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
  if (!extRe.test(s)) s = s + '.' + ext;
  if (s.length > maxLength) {
    const base = s.slice(0, maxLength - ext.length - 2).replace(/[-.]+$/, '');
    s = base + '.' + ext;
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

const TIERS = { history: 1200, reactions: 3000, users: 600, info: 1200, list: 3000, default: 1200 };

function methodTier(method) {
  if (method === 'conversations.history' || method === 'conversations.replies') return 'history';
  if (method === 'reactions.get') return 'reactions';
  if (method === 'users.info' || method === 'bots.info') return 'users';
  if (method === 'conversations.info' || method === 'conversations.genericInfo') return 'info';
  if (method === 'users.conversations' || method === 'conversations.list') return 'list';
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

// --- Notification helpers (used by the preload's Notification bridge) ---

// Deep-scans the options object Slack's web client passes to `new Notification()`
// for a conversation id + message ts so an inline notification reply can be
// posted via chat.postMessage. Explicitly named keys win over pattern matches.
function extractNotificationTarget(options) {
  const CHANNEL_RE = /\b([CDG][A-Z0-9]{7,})\b/;
  const TS_RE = /\b(\d{10}\.\d{6})\b/;
  let channel = null;
  let ts = null;
  let threadTs = null;
  const seen = new Set();

  function considerString(key, val) {
    const k = String(key || '').toLowerCase();
    const cm = CHANNEL_RE.exec(val);
    if (cm) {
      if (/channel|conversation|^ch$|^c$/.test(k)) channel = cm[1];
      else if (!channel) channel = cm[1];
    }
    const tm = TS_RE.exec(val);
    if (tm) {
      if (/thread/.test(k)) threadTs = tm[1];
      else if (/^ts$|timestamp|message/.test(k)) ts = ts || tm[1];
      else if (!ts) ts = tm[1];
    }
  }

  function visit(key, val, depth) {
    if (val == null || depth > 6) return;
    if (typeof val === 'string') { considerString(key, val); return; }
    if (typeof val !== 'object' || seen.has(val)) return;
    seen.add(val);
    if (Array.isArray(val)) { for (const v of val) visit(key, v, depth + 1); return; }
    for (const [k, v] of Object.entries(val)) visit(k, v, depth + 1);
  }

  visit('options', options, 0);
  return channel ? { channel, ts, threadTs } : null;
}

// Summarizes a client.counts response. Tolerant of shape drift in the
// undocumented API. Returns null when the response is unusable.
function summarizeCounts(counts) {
  if (!counts || counts.ok === false) return null;
  let mentions = 0;
  let unread = false;
  const buckets = [counts.channels, counts.mpims, counts.ims];
  for (const list of buckets) {
    for (const item of (Array.isArray(list) ? list : [])) {
      if (!item) continue;
      mentions += (item.mention_count | 0) + (item.dm_count | 0);
      if (item.has_unreads) unread = true;
    }
  }
  if (counts.threads) {
    mentions += counts.threads.mention_count | 0;
    if (counts.threads.has_unreads) unread = true;
  }
  return { mentions, hasUnreads: unread };
}

function computeBadgeFromCounts(counts) {
  const s = summarizeCounts(counts);
  if (!s) return null;
  if (s.mentions > 0) return String(s.mentions);
  return s.hasUnreads ? '•' : '';
}

function normalizeChannelTypes(types) {
  if (types === 'public_channel' || types === 'private_channel') return types;
  return 'public_channel,private_channel';
}

function channelTypesLabel(types) {
  const t = normalizeChannelTypes(types);
  if (t === 'public_channel') return 'public';
  if (t === 'private_channel') return 'private';
  return 'all';
}

// Lists every channel the calling user is a member of (users.conversations only
// returns the caller's memberships), filtered to public/private/both.
async function fetchAllMemberChannels(apiCall, opts, hooks) {
  opts = opts || {};
  hooks = hooks || {};
  const types = normalizeChannelTypes(opts.types);
  const map = new Map();
  let cursor = null;
  for (;;) {
    throwIfAborted(hooks.signal);
    const params = { types, exclude_archived: true, limit: 200 };
    if (cursor) params.cursor = cursor;
    const resp = await apiCall('users.conversations', params);
    if (!resp || resp.ok === false) throw new Error('users.conversations failed: ' + (resp && resp.error));
    for (const c of (resp.channels || [])) {
      if (c && c.id && !map.has(c.id)) map.set(c.id, c);
    }
    if (hooks.onProgress) hooks.onProgress('channels', map.size, null);
    const next = getNextCursor(resp);
    if (!next) break;
    if (cursor && next === cursor) throw new Error('channel pagination stalled: cursor did not advance');
    cursor = next;
  }
  return Array.from(map.values()).sort((a, b) => String(a.name || a.id).localeCompare(String(b.name || b.id)));
}

function buildChannelListDoc(channels, ctx) {
  ctx = ctx || {};
  return {
    exported_at: ctx.exportedAt || null,
    exported_by: 'slack-autocomplete-electron',
    workspace: ctx.workspace || null,
    types: channelTypesLabel(ctx.types),
    count: (channels || []).length,
    channels: (channels || []).map((c) => ({ id: c.id, name: c.name || c.id, is_private: !!c.is_private })),
  };
}

function formatChannelListText(channels) {
  return (channels || []).map((c) => '#' + (c.name || c.id)).join('\n') + ((channels || []).length ? '\n' : '');
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

async function runExport(apiCall, ctx, hooks) {
  hooks = hooks || {};
  const report = createReport();

  const messages = await fetchAllHistory(apiCall, { channel: ctx.channelId }, hooks);

  const parents = messages.filter((m) => (m.reply_count | 0) > 0);
  let ti = 0;
  for (const m of parents) {
    throwIfAborted(hooks.signal);
    m.replies = await fetchThreadReplies(apiCall, { channel: ctx.channelId, threadTs: m.thread_ts || m.ts }, hooks);
    ti++;
    if (hooks.onProgress) hooks.onProgress('threads', ti, parents.length);
  }

  await backfillReactions(apiCall, { channel: ctx.channelId }, messages, report, hooks);

  const refs = collectActorRefs(messages);
  const users = await resolveActors(apiCall, refs, report, hooks);

  let replyCount = 0;
  let reactionCount = 0;
  function enrich(m) {
    const ref = resolveActorRef(m);
    if (ref) {
      if (ref.kind === 'user' && ref.id) { const e = users[ref.id]; m.user_name = e ? pickInlineName(e) : ref.id; }
      else if (ref.kind === 'bot' && ref.id) { const e = users[ref.id]; m.user_name = e ? pickInlineName(e) : (ref.username || ref.id); m.actor_kind = 'bot'; }
      else if (ref.username) { m.user_name = ref.username; m.actor_kind = 'unknown'; }
    }
    if (Array.isArray(m.reactions)) {
      for (const r of m.reactions) {
        reactionCount++;
        r.user_names = (r.users || []).map((id) => { const e = users[id]; return e ? pickInlineName(e) : id; });
      }
    }
    if (Array.isArray(m.replies)) { for (const rep of m.replies) { replyCount++; enrich(rep); } }
  }
  for (const m of messages) enrich(m);

  report.setBaseCounts({ messages: messages.length, replies: replyCount, threads: parents.length, reactions: reactionCount });

  return {
    export: report.build(ctx.exportedAt),
    workspace: ctx.workspace,
    channel: ctx.channel,
    users,
    messages,
  };
}

module.exports = {
  parseClientUrl, parseClientTeam, getTokenForTeam, inferApiBase, workspaceFromConfig, sanitizeExportFilename,
  normalizeChannelTypes, channelTypesLabel, fetchAllMemberChannels, buildChannelListDoc, formatChannelListText,
  extractNotificationTarget, summarizeCounts, computeBadgeFromCounts,
  getNextCursor, responseHasMore, accumulateByTs, finalizeThreadReplies, reactionNeedsBackfill, messageNeedsReactionBackfill,
  resolveActorRef, buildUserEntry, buildBotEntry, collectActorRefs, pickInlineName, createReport,
  TIERS, methodTier, tierIntervalMs, parseRetryAfter, backoffDelay, streamExportJson, fetchAllHistory, fetchThreadReplies,
  backfillReactions, resolveActors, runExport,
};
