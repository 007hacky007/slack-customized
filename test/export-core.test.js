const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../export-core.js');

const CFG = JSON.stringify({
  teams: {
    T02MCKX93: { id: 'T02MCKX93', name: 'CDN77', url: 'https://cdn77.slack.com/', token: 'xoxc-abc' },
    T0NOURL:   { id: 'T0NOURL', name: 'NoUrl', domain: 'nourl' }
  }
});

test('parseClientUrl extracts team and channel', () => {
  assert.deepEqual(core.parseClientUrl('/client/T02MCKX93/C09LGFFFSD9'),
    { teamId: 'T02MCKX93', channelId: 'C09LGFFFSD9' });
  assert.equal(core.parseClientUrl('/client/'), null);
  assert.equal(core.parseClientUrl(''), null);
});

test('getTokenForTeam reads token, null when missing', () => {
  assert.equal(core.getTokenForTeam(CFG, 'T02MCKX93'), 'xoxc-abc');
  assert.equal(core.getTokenForTeam(CFG, 'TNOPE'), null);
  assert.equal(core.getTokenForTeam('not json', 'T02MCKX93'), null);
});

test('inferApiBase prefers url, falls back to domain', () => {
  assert.equal(core.inferApiBase(CFG, 'T02MCKX93'), 'https://cdn77.slack.com/api/');
  assert.equal(core.inferApiBase(CFG, 'T0NOURL'), 'https://nourl.slack.com/api/');
  assert.equal(core.inferApiBase(CFG, 'TNOPE'), null);
});

test('workspaceFromConfig returns team id and name', () => {
  assert.deepEqual(core.workspaceFromConfig(CFG, 'T02MCKX93'), { team_id: 'T02MCKX93', name: 'CDN77' });
  assert.deepEqual(core.workspaceFromConfig('bad', 'T02MCKX93'), { team_id: 'T02MCKX93', name: null });
});

test('sanitizeExportFilename strips paths and forces .json', () => {
  assert.equal(core.sanitizeExportFilename('../../etc/passwd'), 'etc-passwd.json');
  assert.equal(core.sanitizeExportFilename('a/b\\c'), 'a-b-c.json');
  assert.equal(core.sanitizeExportFilename('weird:name?*.json'), 'weird-name-.json');
  assert.equal(core.sanitizeExportFilename(''), 'slack-export.json');
  assert.equal(core.sanitizeExportFilename('   '), 'slack-export.json');
  assert.equal(core.sanitizeExportFilename('ok-name.json'), 'ok-name.json');
});

test('sanitizeExportFilename caps length and keeps .json', () => {
  const out = core.sanitizeExportFilename('x'.repeat(500));
  assert.ok(out.length <= 120);
  assert.ok(out.endsWith('.json'));
});

test('resolveActors resolves users, embedded bots, bots.info, and flags unresolved', async () => {
  const refs = {
    userIds: new Set(['U1', 'UBAD']),
    botIds: new Set(['B1', 'B2']),
    embeddedBotProfiles: new Map([['B1', { name: 'GitHub' }]]),
  };
  const apiCall = async (method, p) => {
    if (method === 'users.info' && p.user === 'U1') return { ok: true, user: { id: 'U1', name: 'jdoe', profile: { real_name: 'John Doe', display_name: 'John' } } };
    if (method === 'users.info' && p.user === 'UBAD') return { ok: false, error: 'user_not_found' };
    if (method === 'bots.info' && p.bot === 'B2') return { ok: true, bot: { id: 'B2', name: 'Jira' } };
    return { ok: false, error: 'unknown' };
  };
  const report = core.createReport();
  const users = await core.resolveActors(apiCall, refs, report);

  assert.equal(users.U1.name, 'John');
  assert.equal(users.U1.kind, 'user');
  assert.deepEqual(users.UBAD, { id: 'UBAD', kind: 'user', name: 'UBAD', unresolved: true });
  assert.deepEqual(users.B1, { id: 'B1', kind: 'bot', is_bot: true, name: 'GitHub', real_name: 'GitHub' });
  assert.equal(users.B2.name, 'Jira');
  assert.equal(report.counts.unresolved_actors, 1);
});

test('cursor and has_more readers', () => {
  assert.equal(core.getNextCursor({ response_metadata: { next_cursor: 'c1' } }), 'c1');
  assert.equal(core.getNextCursor({}), null);
  assert.equal(core.responseHasMore({ has_more: true }), true);
  assert.equal(core.responseHasMore({}), false);
});

test('accumulateByTs dedupes and counts new', () => {
  const m = new Map();
  assert.equal(core.accumulateByTs(m, [{ ts: '1' }, { ts: '2' }]), 2);
  assert.equal(core.accumulateByTs(m, [{ ts: '2' }, { ts: '3' }]), 1);
  assert.equal(m.size, 3);
});

test('finalizeThreadReplies drops parent by ts and sorts asc', () => {
  const m = new Map([
    ['3.0', { ts: '3.0' }],
    ['1.0', { ts: '1.0' }],   // parent (== threadTs)
    ['2.0', { ts: '2.0' }],
  ]);
  assert.deepEqual(core.finalizeThreadReplies(m, '1.0').map(x => x.ts), ['2.0', '3.0']);
});

test('reaction backfill predicates', () => {
  assert.equal(core.reactionNeedsBackfill({ count: 5, users: ['a', 'b'] }), true);
  assert.equal(core.reactionNeedsBackfill({ count: 2, users: ['a', 'b'] }), false);
  assert.equal(core.messageNeedsReactionBackfill({ reactions: [{ count: 1, users: ['a'] }, { count: 9, users: [] }] }), true);
  assert.equal(core.messageNeedsReactionBackfill({ reactions: [] }), false);
});

test('resolveActorRef handles user, bot, username-only', () => {
  assert.deepEqual(core.resolveActorRef({ user: 'U1' }), { kind: 'user', id: 'U1' });
  assert.deepEqual(core.resolveActorRef({ bot_id: 'B1', bot_profile: { name: 'GH' }, username: 'GitHub' }),
    { kind: 'bot', id: 'B1', embeddedProfile: { name: 'GH' }, username: 'GitHub' });
  assert.deepEqual(core.resolveActorRef({ username: 'Webhook' }), { kind: 'unknown', id: null, username: 'Webhook' });
  assert.equal(core.resolveActorRef({}), null);
});

test('buildUserEntry / buildBotEntry / pickInlineName', () => {
  const u = core.buildUserEntry({ id: 'U1', name: 'jdoe', is_bot: false, profile: { real_name: 'John Doe', display_name: 'John' } });
  assert.deepEqual(u, { id: 'U1', kind: 'user', is_bot: false, name: 'John', real_name: 'John Doe', display_name: 'John' });
  assert.equal(core.pickInlineName(u), 'John');
  const b = core.buildBotEntry({ name: 'GitHub' }, 'B1');
  assert.deepEqual(b, { id: 'B1', kind: 'bot', is_bot: true, name: 'GitHub', real_name: 'GitHub' });
});

test('collectActorRefs gathers users, bots, reaction authors, replies', () => {
  const messages = [
    { user: 'U1', reactions: [{ name: '+1', users: ['U2', 'U3'] }],
      replies: [{ user: 'U4' }, { bot_id: 'B1', bot_profile: { name: 'GH' } }] },
    { bot_id: 'B2' },
  ];
  const refs = core.collectActorRefs(messages);
  assert.deepEqual([...refs.userIds].sort(), ['U1', 'U2', 'U3', 'U4']);
  assert.deepEqual([...refs.botIds].sort(), ['B1', 'B2']);
  assert.deepEqual(refs.embeddedBotProfiles.get('B1'), { name: 'GH' });
});

test('createReport tracks counts, warnings, completeness', () => {
  const r = core.createReport();
  r.setBaseCounts({ messages: 10, replies: 4, threads: 2, reactions: 3 });
  let out = r.build('2026-06-20T00:00:00.000Z');
  assert.equal(out.complete, true);
  assert.equal(out.exported_by, 'slack-autocomplete-electron');
  assert.equal(out.version, 1);
  assert.deepEqual(out.counts, { messages: 10, replies: 4, threads: 2, reactions: 3, truncated_reactions: 0, unresolved_actors: 0 });

  r.addTruncatedReaction('1.0', 'tada', 25, 31);
  r.addUnresolvedActor('U9', 'user');
  out = r.build('2026-06-20T00:00:00.000Z');
  assert.equal(out.complete, false);
  assert.equal(out.counts.truncated_reactions, 1);
  assert.equal(out.counts.unresolved_actors, 1);
  assert.deepEqual(out.warnings, [
    { type: 'reaction_truncated', ts: '1.0', emoji: 'tada', got: 25, expected: 31 },
    { type: 'actor_unresolved', id: 'U9', kind: 'user' },
  ]);
});

test('methodTier and tierIntervalMs map methods to limits', () => {
  assert.equal(core.methodTier('conversations.history'), 'history');
  assert.equal(core.methodTier('conversations.replies'), 'history');
  assert.equal(core.methodTier('reactions.get'), 'reactions');
  assert.equal(core.methodTier('users.info'), 'users');
  assert.equal(core.methodTier('bots.info'), 'users');
  assert.equal(core.methodTier('conversations.info'), 'info');
  assert.equal(core.methodTier('something.else'), 'default');
  assert.equal(core.tierIntervalMs('reactions.get'), core.TIERS.reactions);
});

test('parseRetryAfter and backoffDelay', () => {
  assert.equal(core.parseRetryAfter('30'), 30);
  assert.equal(core.parseRetryAfter(null), 5);
  assert.equal(core.parseRetryAfter('garbage'), 5);
  assert.equal(core.backoffDelay(1), 1000);
  assert.equal(core.backoffDelay(2), 2000);
  assert.ok(core.backoffDelay(20) <= 30000);
});

test('streamExportJson round-trips to the same document', () => {
  const doc = {
    export: { version: 1, complete: true },
    workspace: { team_id: 'T1', name: 'W' },
    channel: { id: 'C1', name: 'general' },
    users: { U1: { id: 'U1', name: 'John' } },
    messages: [{ ts: '1.0', text: 'a' }, { ts: '2.0', text: 'b' }],
  };
  let out = '';
  for (const chunk of core.streamExportJson(doc)) out += chunk;
  assert.deepEqual(JSON.parse(out), doc);
});

test('streamExportJson handles empty messages', () => {
  const doc = { export: {}, workspace: {}, channel: {}, users: {}, messages: [] };
  let out = '';
  for (const chunk of core.streamExportJson(doc)) out += chunk;
  assert.deepEqual(JSON.parse(out), doc);
});

test('fetchAllHistory follows cursors, dedupes, sorts asc', async () => {
  const pages = {
    'null': { ok: true, messages: [{ ts: '3.0' }, { ts: '2.0' }], has_more: true, response_metadata: { next_cursor: 'c1' } },
    'c1':   { ok: true, messages: [{ ts: '2.0' }, { ts: '1.0' }], has_more: false },
  };
  const calls = [];
  const apiCall = async (method, params) => { calls.push([method, params.cursor || 'null']); return pages[params.cursor || 'null']; };
  const msgs = await core.fetchAllHistory(apiCall, { channel: 'C1' });
  assert.deepEqual(msgs.map(m => m.ts), ['1.0', '2.0', '3.0']);
  assert.deepEqual(calls, [['conversations.history', 'null'], ['conversations.history', 'c1']]);
});

test('fetchAllHistory throws when has_more but no cursor', async () => {
  const apiCall = async () => ({ ok: true, messages: [{ ts: '1.0' }], has_more: true });
  await assert.rejects(() => core.fetchAllHistory(apiCall, { channel: 'C1' }), /stalled/);
});

test('fetchAllHistory throws on api error', async () => {
  const apiCall = async () => ({ ok: false, error: 'channel_not_found' });
  await assert.rejects(() => core.fetchAllHistory(apiCall, { channel: 'C1' }), /channel_not_found/);
});

test('fetchThreadReplies paginates by cursor and removes parent', async () => {
  const pages = {
    'null': { ok: true, messages: [{ ts: '1.0' }, { ts: '2.0' }], has_more: true, response_metadata: { next_cursor: 'c1' } },
    'c1':   { ok: true, messages: [{ ts: '3.0' }], has_more: false },
  };
  const apiCall = async (m, p) => pages[p.cursor || 'null'];
  const replies = await core.fetchThreadReplies(apiCall, { channel: 'C1', threadTs: '1.0' });
  assert.deepEqual(replies.map(r => r.ts), ['2.0', '3.0']);
});

test('fetchThreadReplies falls back to oldest-window when no cursor, inclusive=false, dedupes', async () => {
  const seen = [];
  const apiCall = async (m, p) => {
    seen.push({ cursor: p.cursor || null, oldest: p.oldest || null, inclusive: p.inclusive });
    if (!p.oldest && !p.cursor) return { ok: true, messages: [{ ts: '1.0' }, { ts: '2.0' }], has_more: true };
    if (p.oldest === '2.0') { assert.equal(p.inclusive, false); return { ok: true, messages: [{ ts: '3.0' }], has_more: true }; }
    if (p.oldest === '3.0') return { ok: true, messages: [], has_more: true }; // no progress -> terminates
    return { ok: true, messages: [], has_more: false };
  };
  const replies = await core.fetchThreadReplies(apiCall, { channel: 'C1', threadTs: '1.0' });
  assert.deepEqual(replies.map(r => r.ts), ['2.0', '3.0']);
});

test('backfillReactions fills full author lists and flags truncation', async () => {
  const messages = [
    { ts: '1.0', reactions: [{ name: 'tada', count: 3, users: ['U1'] }] },          // backfillable -> full
    { ts: '2.0', reactions: [{ name: '+1', count: 1, users: ['U2'] }] },            // already complete
    { ts: '3.0', reactions: [{ name: 'eyes', count: 5, users: ['U9'] }],            // stays truncated
      replies: [{ ts: '3.1', reactions: [{ name: 'fire', count: 2, users: ['U1'] }] }] },
  ];
  const apiCall = async (method, p) => {
    if (p.timestamp === '1.0') return { ok: true, message: { reactions: [{ name: 'tada', users: ['U1', 'U2', 'U3'] }] } };
    if (p.timestamp === '3.0') return { ok: true, message: { reactions: [{ name: 'eyes', users: ['U9', 'U8'] }] } }; // still < 5
    if (p.timestamp === '3.1') return { ok: true, message: { reactions: [{ name: 'fire', users: ['U1', 'U4'] }] } };
    return { ok: false, error: 'message_not_found' };
  };
  const report = core.createReport();
  await core.backfillReactions(apiCall, { channel: 'C1' }, messages, report);

  assert.deepEqual(messages[0].reactions[0].users, ['U1', 'U2', 'U3']);
  assert.equal(messages[0].reactions[0].users_truncated, false);
  assert.equal(messages[1].reactions[0].users_truncated, false);
  assert.equal(messages[2].reactions[0].users_truncated, true);
  assert.deepEqual(messages[2].replies[0].reactions[0].users, ['U1', 'U4']);
  assert.equal(report.counts.truncated_reactions, 1);
  assert.equal(report.warnings[0].type, 'reaction_truncated');
});

test('runExport assembles a complete document end-to-end', async () => {
  const history = {
    'null': { ok: true, has_more: false, messages: [
      { ts: '2.0', user: 'U1', text: 'hi', reply_count: 1, thread_ts: '2.0', reactions: [{ name: 'tada', count: 3, users: ['U1'] }] },
      { ts: '1.0', bot_id: 'B1', bot_profile: { name: 'GitHub' }, subtype: 'bot_message', text: 'deploy ok' },
    ] },
  };
  const replies = { '2.0': { ok: true, has_more: false, messages: [ { ts: '2.0', user: 'U1' }, { ts: '2.5', user: 'U2', text: 'reply' } ] } };
  const apiCall = async (method, p) => {
    if (method === 'conversations.history') return history[p.cursor || 'null'];
    if (method === 'conversations.replies') return replies[p.ts];
    if (method === 'reactions.get' && p.timestamp === '2.0') return { ok: true, message: { reactions: [{ name: 'tada', users: ['U1', 'U2', 'U3'] }] } };
    if (method === 'users.info') return { ok: true, user: { id: p.user, name: p.user.toLowerCase(), profile: { real_name: 'Real ' + p.user } } };
    return { ok: false, error: 'unexpected ' + method };
  };
  const doc = await core.runExport(apiCall, {
    channelId: 'C1',
    channel: { id: 'C1', name: 'general', is_private: false },
    workspace: { team_id: 'T1', name: 'W' },
    exportedAt: '2026-06-20T00:00:00.000Z',
  });

  assert.deepEqual(doc.messages.map(m => m.ts), ['1.0', '2.0']);                  // chronological
  const threaded = doc.messages.find(m => m.ts === '2.0');
  assert.deepEqual(threaded.replies.map(r => r.ts), ['2.5']);                     // parent dropped
  assert.equal(threaded.user_name, 'Real U1');
  assert.deepEqual(threaded.reactions[0].users, ['U1', 'U2', 'U3']);             // backfilled
  assert.deepEqual(threaded.reactions[0].user_names, ['Real U1', 'Real U2', 'Real U3']);
  const bot = doc.messages.find(m => m.ts === '1.0');
  assert.equal(bot.user_name, 'GitHub');
  assert.equal(bot.actor_kind, 'bot');
  assert.equal(doc.users.B1.kind, 'bot');
  assert.equal(doc.export.complete, true);
  assert.deepEqual(doc.export.counts, { messages: 2, replies: 1, threads: 1, reactions: 1, truncated_reactions: 0, unresolved_actors: 0 });
});

test('parseClientTeam extracts team without a channel', () => {
  assert.deepEqual(core.parseClientTeam('/client/T02MCKX93'), { teamId: 'T02MCKX93' });
  assert.deepEqual(core.parseClientTeam('/client/T02MCKX93/C09LGFFFSD9'), { teamId: 'T02MCKX93' });
  assert.equal(core.parseClientTeam('/client/'), null);
  assert.equal(core.parseClientTeam(''), null);
});

test('sanitizeExportFilename honors ext option', () => {
  assert.equal(core.sanitizeExportFilename('channels', { ext: 'txt' }), 'channels.txt');
  assert.equal(core.sanitizeExportFilename('channels.txt', { ext: 'txt' }), 'channels.txt');
  assert.equal(core.sanitizeExportFilename('', { ext: 'txt' }), 'slack-export.txt');
  const long = core.sanitizeExportFilename('x'.repeat(500), { ext: 'txt' });
  assert.ok(long.length <= 120);
  assert.ok(long.endsWith('.txt'));
  assert.equal(core.sanitizeExportFilename('a.json', { ext: '../evil' }), 'a.json'); // bad ext falls back to json
});

test('normalizeChannelTypes and channelTypesLabel', () => {
  assert.equal(core.normalizeChannelTypes('public_channel'), 'public_channel');
  assert.equal(core.normalizeChannelTypes('private_channel'), 'private_channel');
  assert.equal(core.normalizeChannelTypes('public_channel,private_channel'), 'public_channel,private_channel');
  assert.equal(core.normalizeChannelTypes(undefined), 'public_channel,private_channel');
  assert.equal(core.normalizeChannelTypes('mpim'), 'public_channel,private_channel');
  assert.equal(core.channelTypesLabel('public_channel'), 'public');
  assert.equal(core.channelTypesLabel('private_channel'), 'private');
  assert.equal(core.channelTypesLabel('anything-else'), 'all');
});

test('methodTier maps list methods to the list tier', () => {
  assert.equal(core.methodTier('users.conversations'), 'list');
  assert.equal(core.methodTier('conversations.list'), 'list');
  assert.equal(core.tierIntervalMs('users.conversations'), 3000);
});

test('fetchAllMemberChannels paginates, dedupes and sorts by name', async () => {
  const pages = {
    'null': { ok: true, channels: [{ id: 'C2', name: 'zeta' }, { id: 'C1', name: 'alpha' }], response_metadata: { next_cursor: 'cur1' } },
    'cur1': { ok: true, channels: [{ id: 'C2', name: 'zeta' }, { id: 'C3', name: 'mid', is_private: true }], response_metadata: { next_cursor: '' } },
  };
  const calls = [];
  const apiCall = async (method, p) => {
    calls.push({ method, p });
    return pages[p.cursor || 'null'];
  };
  const out = await core.fetchAllMemberChannels(apiCall, { types: 'public_channel,private_channel' });
  assert.deepEqual(out.map((c) => c.id), ['C1', 'C3', 'C2']);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].method, 'users.conversations');
  assert.equal(calls[0].p.types, 'public_channel,private_channel');
  assert.equal(calls[0].p.exclude_archived, true);
  assert.equal(calls[1].p.cursor, 'cur1');
});

test('fetchAllMemberChannels throws on api error and stalled cursor', async () => {
  await assert.rejects(
    core.fetchAllMemberChannels(async () => ({ ok: false, error: 'invalid_auth' })),
    /users\.conversations failed: invalid_auth/
  );
  const stalled = async (_m, p) => ({ ok: true, channels: [], response_metadata: { next_cursor: 'same' } });
  await assert.rejects(core.fetchAllMemberChannels(stalled), /cursor did not advance/);
});

test('buildChannelListDoc keeps id, name, is_private and metadata', () => {
  const doc = core.buildChannelListDoc(
    [{ id: 'C1', name: 'general', is_private: false, topic: { value: 'noise' } }, { id: 'C2', is_private: true }],
    { exportedAt: '2026-07-07T00:00:00.000Z', workspace: { team_id: 'T1', name: 'W' }, types: 'private_channel' }
  );
  assert.equal(doc.exported_at, '2026-07-07T00:00:00.000Z');
  assert.equal(doc.types, 'private');
  assert.equal(doc.count, 2);
  assert.deepEqual(doc.channels, [
    { id: 'C1', name: 'general', is_private: false },
    { id: 'C2', name: 'C2', is_private: true },
  ]);
});

test('formatChannelListText emits one channel per line', () => {
  assert.equal(core.formatChannelListText([{ id: 'C1', name: 'general' }, { id: 'C2' }]), '#general\n#C2\n');
  assert.equal(core.formatChannelListText([]), '');
});

test('extractNotificationTarget finds channel and ts across option shapes', () => {
  // explicit keys in data
  assert.deepEqual(
    core.extractNotificationTarget({ data: { channelId: 'C0123ABCD', ts: '1720000000.123456' } }),
    { channel: 'C0123ABCD', ts: '1720000000.123456', threadTs: null }
  );
  // ids embedded in a tag string
  assert.deepEqual(
    core.extractNotificationTarget({ tag: 'msg-C0123ABCD-1720000000.123456' }),
    { channel: 'C0123ABCD', ts: '1720000000.123456', threadTs: null }
  );
  // thread key wins for threadTs; group id supported
  const t = core.extractNotificationTarget({ data: { conversation: 'G9999ZZZZ', thread_ts: '1720000000.000001' } });
  assert.equal(t.channel, 'G9999ZZZZ');
  assert.equal(t.threadTs, '1720000000.000001');
  // nothing usable
  assert.equal(core.extractNotificationTarget({ body: 'hello there' }), null);
  assert.equal(core.extractNotificationTarget(null), null);
  // cyclic objects do not loop forever
  const cyc = { data: {} };
  cyc.data.self = cyc;
  cyc.data.channel = 'D0123ABCD';
  assert.equal(core.extractNotificationTarget(cyc).channel, 'D0123ABCD');
});

test('computeBadgeFromCounts sums mentions, falls back to unread dot', () => {
  assert.equal(core.computeBadgeFromCounts({
    ok: true,
    channels: [{ id: 'C1', mention_count: 2, has_unreads: true }, { id: 'C2', mention_count: 0 }],
    mpims: [{ id: 'G1', mention_count: 1 }],
    ims: [{ id: 'D1', dm_count: 3 }],
    threads: { has_unreads: true, mention_count: 1 },
  }), '7');
  assert.equal(core.computeBadgeFromCounts({ ok: true, channels: [{ id: 'C1', has_unreads: true }] }), '•');
  assert.equal(core.computeBadgeFromCounts({ ok: true, channels: [] }), '');
  assert.equal(core.computeBadgeFromCounts({ ok: false, error: 'invalid_auth' }), null);
  assert.equal(core.computeBadgeFromCounts(null), null);
});

test('summarizeCounts returns mention totals and unread flag', () => {
  const s = core.summarizeCounts({
    ok: true,
    channels: [{ id: 'C1', mention_count: 2, has_unreads: true }],
    ims: [{ id: 'D1', dm_count: 1 }],
    threads: { mention_count: 1 },
  });
  assert.equal(s.mentions, 4);
  assert.equal(s.hasUnreads, true);
  const empty = core.summarizeCounts({ ok: true });
  assert.equal(empty.mentions, 0);
  assert.equal(empty.hasUnreads, false);
  assert.equal(core.summarizeCounts({ ok: false }), null);
  assert.equal(core.summarizeCounts(undefined), null);
});

test('summarizeCounts excludes muted channels from unread dot but keeps mentions', () => {
  const counts = {
    ok: true,
    channels: [
      { id: 'C1', has_unreads: true, mention_count: 0 },   // muted -> no dot
      { id: 'C2', has_unreads: true, mention_count: 2 },   // muted -> mention still counts
    ],
    ims: [], mpims: [], threads: { has_unreads: false, mention_count: 0 },
  };
  const muted = new Set(['C1', 'C2']);
  const s = core.summarizeCounts(counts, muted);
  assert.equal(s.mentions, 2);
  assert.equal(s.hasUnreads, false);
  // without muting, the unread dot shows
  const s2 = core.summarizeCounts(counts, new Set());
  assert.equal(s2.mentions, 2);
  assert.equal(s2.hasUnreads, true);
  // an unmuted unread channel lights the dot
  const c2 = { ok: true, channels: [{ id: 'C9', has_unreads: true, mention_count: 0 }] };
  assert.equal(core.summarizeCounts(c2, new Set(['C1'])).hasUnreads, true);
});

test('parseMutedChannels reads the comma-separated pref', () => {
  assert.deepEqual([...core.parseMutedChannels({ ok: true, prefs: { muted_channels: 'C1,C2,C3' } })], ['C1', 'C2', 'C3']);
  assert.deepEqual([...core.parseMutedChannels({ ok: true, prefs: { muted_channels: '' } })], []);
  assert.deepEqual([...core.parseMutedChannels({ ok: true, prefs: {} })], []);
  assert.deepEqual([...core.parseMutedChannels(null)], []);
  assert.deepEqual([...core.parseMutedChannels({ prefs: { muted_channels: ' C1 , C2 ' } })], ['C1', 'C2']);
});

test('parseMutedChannels reads all_notifications_prefs (muted_channels is gone from live prefs)', () => {
  // verified live 2026-07-07: users.prefs.get returns no muted_channels key;
  // muting lives in all_notifications_prefs channels[id].muted
  const anp = JSON.stringify({
    global: { global_desktop: 'mentions_dms' },
    channels: {
      C1: { desktop: 'everything', muted: true },
      C2: { desktop: 'everything', muted: false },
      G3: { muted: true },
    },
  });
  assert.deepEqual([...core.parseMutedChannels({ ok: true, prefs: { all_notifications_prefs: anp } })].sort(), ['C1', 'G3']);
  // union with the legacy pref when both are present
  assert.deepEqual(
    [...core.parseMutedChannels({ ok: true, prefs: { muted_channels: 'C9', all_notifications_prefs: anp } })].sort(),
    ['C1', 'C9', 'G3']
  );
  // malformed JSON is ignored
  assert.deepEqual([...core.parseMutedChannels({ ok: true, prefs: { all_notifications_prefs: '{bad' } })], []);
});

test('parseShowBullet reads mac_ssb_bullet, defaults true', () => {
  assert.equal(core.parseShowBullet({ ok: true, prefs: { mac_ssb_bullet: true } }), true);
  assert.equal(core.parseShowBullet({ ok: true, prefs: { mac_ssb_bullet: false } }), false);
  assert.equal(core.parseShowBullet({ ok: true, prefs: {} }), true);
  assert.equal(core.parseShowBullet(null), true);
});

test('summarizeCounts reports the non-muted unread conversation ids', () => {
  const counts = {
    ok: true,
    channels: [
      { id: 'C1', has_unreads: true, mention_count: 0 },
      { id: 'C2', has_unreads: true, mention_count: 0 },
      { id: 'C3', has_unreads: false, mention_count: 0 },
    ],
    ims: [{ id: 'D1', has_unreads: true, dm_count: 0 }],
    mpims: [],
    threads: { has_unreads: true, mention_count: 0 },
  };
  const s = core.summarizeCounts(counts, new Set(['C2']));
  assert.deepEqual(s.unreadIds.sort(), ['C1', 'D1']);
  assert.equal(s.threadsUnread, true);
  assert.equal(s.hasUnreads, true);
  const s2 = core.summarizeCounts({ ok: true, channels: [] });
  assert.deepEqual(s2.unreadIds, []);
  assert.equal(s2.threadsUnread, false);
});

test('normalizeSections maps list response, strips only wrapping emoji colons', () => {
  // Live-verified: list returns emoji WITHOUT wrapping colons ('' for none),
  // and skin-tone emoji keep an interior '::' that must survive normalization.
  const resp = { ok: true, channel_sections: [
    { channel_section_id: 'S1', name: 'Infra', emoji: ':wrench:', type: 'standard',
      channel_ids_page: { channel_ids: ['C1', 'C2'], count: 2, cursor: 'C2' } },
    { channel_section_id: 'S2', name: 'Starred', emoji: '', type: 'stars',
      channel_ids_page: { channel_ids: [], count: 0 } },
    { channel_section_id: 'S3', name: 'People', emoji: 'older_man::skin-tone-6', type: 'standard',
      channel_ids_page: { channel_ids: ['C3'], count: 1, cursor: 'C3' } },
  ]};
  assert.deepEqual(core.normalizeSections(resp), [
    { id: 'S1', name: 'Infra', emoji: 'wrench', type: 'standard', channelIds: ['C1', 'C2'] },
    { id: 'S2', name: 'Starred', emoji: null, type: 'stars', channelIds: [] },
    { id: 'S3', name: 'People', emoji: 'older_man::skin-tone-6', type: 'standard', channelIds: ['C3'] },
  ]);
});

test('normalizeSections tolerates missing pieces and drops id-less entries', () => {
  const resp = { ok: true, channel_sections: [
    { channel_section_id: 'S1', type: 'standard' },
    { name: 'ghost', type: 'standard' },
  ]};
  assert.deepEqual(core.normalizeSections(resp), [
    { id: 'S1', name: '', emoji: null, type: 'standard', channelIds: [] },
  ]);
  assert.deepEqual(core.normalizeSections({ ok: true }), []);
});

test('normalizeSections throws on error responses', () => {
  assert.throws(() => core.normalizeSections({ ok: false, error: 'invalid_auth' }), /invalid_auth/);
  assert.throws(() => core.normalizeSections(null), /users\.channelSections\.list failed/);
});

test('buildSectionsDoc builds doc with standard sections, unsectioned, schema and instructions', () => {
  const sections = [
    { id: 'S1', name: 'Infra', emoji: 'wrench', type: 'standard', channelIds: ['C1', 'D9'] },
    { id: 'S2', name: 'Starred', emoji: null, type: 'stars', channelIds: ['C2'] },
  ];
  const channels = [
    { id: 'C1', name: 'backbone', is_private: false },
    { id: 'C2', name: 'dns', is_private: false },
    { id: 'C3', name: 'random', is_private: false },
  ];
  const doc = core.buildSectionsDoc(sections, channels, {
    exportedAt: '2026-07-08T12:00:00.000Z', teamId: 'T123',
    workspace: { team_id: 'T123', name: 'acme' },
  });
  assert.equal(doc.format, 'slack-sections-export');
  assert.equal(doc.version, 1);
  assert.equal(doc.exportedAt, '2026-07-08T12:00:00.000Z');
  assert.deepEqual(doc.workspace, { id: 'T123', name: 'acme' });
  assert.ok(Array.isArray(doc.instructions) && doc.instructions.length >= 5);
  assert.equal(doc.schema.properties.format.const, 'slack-sections-export');
  // starred section excluded; D9 kept with null name (not a member channel)
  assert.deepEqual(doc.sections, [
    { name: 'Infra', emoji: 'wrench', channels: [
      { id: 'C1', name: 'backbone' }, { id: 'D9', name: null } ] },
  ]);
  // C2 is only in a non-standard section, so it counts as unsectioned
  assert.deepEqual(doc.unsectioned, [
    { id: 'C2', name: 'dns' }, { id: 'C3', name: 'random' },
  ]);
});

function validSectionsDoc() {
  return {
    format: 'slack-sections-export', version: 1,
    workspace: { id: 'T123', name: 'acme' },
    sections: [
      { name: 'Infra', emoji: 'wrench', channels: [{ id: 'C0AAA', name: 'backbone' }] },
    ],
    unsectioned: [{ id: 'C0CCC', name: 'random' }],
  };
}

test('parseSectionsDoc accepts a valid doc', () => {
  const doc = core.parseSectionsDoc(JSON.stringify(validSectionsDoc()), 'T123');
  assert.equal(doc.sections[0].name, 'Infra');
});

test('parseSectionsDoc rejects bad json, format, version', () => {
  assert.throws(() => core.parseSectionsDoc('{nope', 'T123'), /JSON/);
  const wrongFormat = Object.assign(validSectionsDoc(), { format: 'other' });
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(wrongFormat), 'T123'), /format/);
  const newer = Object.assign(validSectionsDoc(), { version: 2 });
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(newer), 'T123'), /newer version/);
  const noVersion = validSectionsDoc(); delete noVersion.version;
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(noVersion), 'T123'), /version/);
});

test('parseSectionsDoc rejects workspace mismatch and missing workspace', () => {
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(validSectionsDoc()), 'T999'), /Workspace mismatch/);
  const noWs = validSectionsDoc(); delete noWs.workspace;
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(noWs), 'T123'), /workspace/);
  // no currentTeamId -> mismatch check skipped
  assert.ok(core.parseSectionsDoc(JSON.stringify(validSectionsDoc()), null));
});

test('parseSectionsDoc round-trips a buildSectionsDoc export', () => {
  const doc = core.buildSectionsDoc(
    [{ id: 'S1', name: 'A', emoji: null, type: 'standard', channelIds: ['C1'] }],
    [{ id: 'C1', name: 'one', is_private: false }],
    { exportedAt: 'x', teamId: 'T123', workspace: { team_id: 'T123', name: 'acme' } });
  const parsed = core.parseSectionsDoc(JSON.stringify(doc), 'T123');
  assert.equal(parsed.sections.length, 1);
});

test('parseSectionsDoc rejects malformed sections and channel ids', () => {
  const noName = validSectionsDoc(); noName.sections[0].name = '  ';
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(noName), 'T123'), /name/);
  const badId = validSectionsDoc(); badId.sections[0].channels[0].id = 'lowercase';
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(badId), 'T123'), /channel id/);
  const noChannels = validSectionsDoc(); delete noChannels.sections[0].channels;
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(noChannels), 'T123'), /channels/);
  const notArray = Object.assign(validSectionsDoc(), { sections: 'x' });
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(notArray), 'T123'), /sections/);
});

test('parseSectionsDoc rejects duplicate section names within the file', () => {
  const dup = validSectionsDoc();
  dup.sections = [
    { name: 'Infra', emoji: null, channels: [{ id: 'C0AAA', name: 'backbone' }] },
    { name: 'Team', emoji: null, channels: [{ id: 'C0BBB', name: 'other' }] },
    { name: 'Infra', emoji: null, channels: [{ id: 'C0CCC', name: 'again' }] },
  ];
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(dup), 'T123'), /duplicates the name/);

  const whitespaceDup = validSectionsDoc();
  whitespaceDup.sections = [
    { name: 'Infra', emoji: null, channels: [{ id: 'C0AAA', name: 'backbone' }] },
    { name: ' Infra ', emoji: null, channels: [{ id: 'C0BBB', name: 'other' }] },
  ];
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(whitespaceDup), 'T123'), /duplicates the name/);
});

const PLAN_CURRENT = () => [
  { id: 'S1', name: 'Infra', emoji: 'wrench', type: 'standard', channelIds: ['C1'] },
  { id: 'S2', name: 'Team', emoji: null, type: 'standard', channelIds: ['C2'] },
  { id: 'SSTAR', name: 'Starred', emoji: null, type: 'stars', channelIds: ['C3'] },
];
const PLAN_MEMBERS = () => [
  { id: 'C1', name: 'backbone' }, { id: 'C2', name: 'dns' },
  { id: 'C3', name: 'alerts' }, { id: 'C4', name: 'random' },
];

test('computeSectionsImportPlan: idempotent re-import is an empty plan', () => {
  const doc = { sections: [
    { name: 'Infra', emoji: 'wrench', channels: [{ id: 'C1', name: 'backbone' }] },
    { name: 'Team', emoji: null, channels: [{ id: 'C2', name: 'dns' }] },
  ]};
  const plan = core.computeSectionsImportPlan(doc, PLAN_CURRENT(), PLAN_MEMBERS());
  assert.deepEqual(plan.create, []);
  assert.deepEqual(plan.moves, []);
  assert.equal(plan.counts.move, 0);
  assert.equal(plan.skips.length, 2); // both "already in" skips
  assert.match(plan.skips[0].reason, /already in/);
});

test('computeSectionsImportPlan: creates missing sections and moves channels', () => {
  const doc = { sections: [
    { name: 'New Stuff', emoji: 'tada', channels: [
      { id: 'C2', name: 'dns' },   // currently in S2 -> move with remove
      { id: 'C4', name: 'random' } // unsectioned -> insert only
    ]},
  ]};
  const plan = core.computeSectionsImportPlan(doc, PLAN_CURRENT(), PLAN_MEMBERS());
  assert.deepEqual(plan.create, [{ name: 'New Stuff', emoji: 'tada' }]);
  assert.deepEqual(plan.moves, [{
    sectionName: 'New Stuff', sectionId: null,
    insertChannelIds: ['C2', 'C4'],
    removeGroups: [{ sectionId: 'S2', channelIds: ['C2'] }],
  }]);
  assert.deepEqual(plan.counts, { create: 1, move: 2, skip: 0 });
});

test('computeSectionsImportPlan: moving into an existing section by name', () => {
  const doc = { sections: [
    { name: 'Infra', emoji: null, channels: [{ id: 'C2', name: 'dns' }] },
  ]};
  const plan = core.computeSectionsImportPlan(doc, PLAN_CURRENT(), PLAN_MEMBERS());
  assert.deepEqual(plan.create, []);
  assert.deepEqual(plan.moves, [{
    sectionName: 'Infra', sectionId: 'S1',
    insertChannelIds: ['C2'],
    removeGroups: [{ sectionId: 'S2', channelIds: ['C2'] }],
  }]);
});

test('computeSectionsImportPlan: skips unknown channels and duplicates (first wins)', () => {
  const doc = { sections: [
    { name: 'A', emoji: null, channels: [{ id: 'C4', name: 'random' }, { id: 'C0NOPE', name: 'gone' }] },
    { name: 'B', emoji: null, channels: [{ id: 'C4', name: 'random' }] },
  ]};
  const plan = core.computeSectionsImportPlan(doc, PLAN_CURRENT(), PLAN_MEMBERS());
  assert.deepEqual(plan.create.map((c) => c.name), ['A', 'B']); // B still created (empty)
  assert.equal(plan.moves.length, 1);
  assert.deepEqual(plan.moves[0].insertChannelIds, ['C4']);
  assert.equal(plan.skips.length, 2);
  assert.match(plan.skips.find((s) => s.channelId === 'C0NOPE').reason, /not a member|unknown/i);
  assert.match(plan.skips.find((s) => s.channelId === 'C4').reason, /more than once/);
});

test('computeSectionsImportPlan: current sections with a shared name are never a move source between each other', () => {
  const current = [
    { id: 'S1', name: 'Dup', type: 'standard', channelIds: ['C1'] },
    { id: 'S2', name: 'Dup', type: 'standard', channelIds: ['C2'] },
  ];
  const members = [{ id: 'C1', name: 'one' }, { id: 'C2', name: 'two' }];
  const doc = { sections: [
    { name: 'Dup', emoji: null, channels: [{ id: 'C1' }, { id: 'C2' }] },
  ]};
  const plan = core.computeSectionsImportPlan(doc, current, members);
  assert.deepEqual(plan.create, []);
  assert.deepEqual(plan.moves, []);
  assert.equal(plan.skips.length, 2);
  for (const skip of plan.skips) assert.match(skip.reason, /already in/);
});

test('computeSectionsImportPlan: channel only known from a section (e.g. a DM) is movable; starred is never a remove source', () => {
  const doc = { sections: [
    { name: 'Infra', emoji: null, channels: [{ id: 'C3', name: 'alerts' }, { id: 'D7', name: null }] },
  ]};
  const current = PLAN_CURRENT();
  current.push({ id: 'S3', name: 'Misc', emoji: null, type: 'standard', channelIds: ['D7'] });
  const plan = core.computeSectionsImportPlan(doc, current, PLAN_MEMBERS());
  assert.deepEqual(plan.moves[0].insertChannelIds, ['C3', 'D7']);
  // C3 sits only in the starred (non-standard) section: insert without removing from Starred
  assert.deepEqual(plan.moves[0].removeGroups, [{ sectionId: 'S3', channelIds: ['D7'] }]);
});

test('computeSectionsImportPlan: current section name with surrounding whitespace still matches the file\'s trimmed name', () => {
  const current = [
    { id: 'S1', name: ' Infra ', emoji: null, type: 'standard', channelIds: ['C1'] },
  ];
  const members = [{ id: 'C1', name: 'backbone' }];
  const doc = { sections: [
    { name: 'Infra', emoji: null, channels: [{ id: 'C1' }] },
  ]};
  const plan = core.computeSectionsImportPlan(doc, current, members);
  assert.deepEqual(plan.create, []);
  assert.deepEqual(plan.moves, []);
  assert.equal(plan.skips.length, 1);
  assert.match(plan.skips[0].reason, /already in/);
});
