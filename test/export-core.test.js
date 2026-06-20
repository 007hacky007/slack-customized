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
