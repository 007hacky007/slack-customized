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
