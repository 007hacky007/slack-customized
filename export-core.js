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

module.exports = {
  parseClientUrl, getTokenForTeam, inferApiBase, workspaceFromConfig, sanitizeExportFilename,
  getNextCursor, responseHasMore, accumulateByTs, finalizeThreadReplies, reactionNeedsBackfill, messageNeedsReactionBackfill,
  resolveActorRef, buildUserEntry, buildBotEntry, collectActorRefs, pickInlineName, createReport,
  TIERS, methodTier, tierIntervalMs, parseRetryAfter, backoffDelay, streamExportJson,
};
