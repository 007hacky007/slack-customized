const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../last-seen-core.js');

test('emptyStore has the expected shape', () => {
  assert.deepEqual(core.emptyStore(), {
    users: {}, subscriptionLog: [], pendingBaseline: [], lastSubscribedIds: []
  });
});

test('parseWatchlist accepts a valid object and dedupes preserving order', () => {
  const r = core.parseWatchlist({ users: ['U123ABC', 'W99XYZ', 'U123ABC'] });
  assert.equal(r.ok, true);
  assert.deepEqual(r.users, ['U123ABC', 'W99XYZ']);
  assert.equal(r.error, null);
});

test('parseWatchlist accepts a JSON string', () => {
  const r = core.parseWatchlist('{"users":["U123ABC"]}');
  assert.equal(r.ok, true);
  assert.deepEqual(r.users, ['U123ABC']);
});

test('parseWatchlist drops invalid ids but stays ok', () => {
  const r = core.parseWatchlist({ users: ['U123ABC', 'not-an-id', '', 42, null] });
  assert.equal(r.ok, true);
  assert.deepEqual(r.users, ['U123ABC']);
});

test('parseWatchlist returns ok:false on unparseable JSON', () => {
  const r = core.parseWatchlist('{not json');
  assert.equal(r.ok, false);
  assert.deepEqual(r.users, []);
  assert.equal(typeof r.error, 'string');
});

test('parseWatchlist treats missing users array as empty', () => {
  const r = core.parseWatchlist({});
  assert.equal(r.ok, true);
  assert.deepEqual(r.users, []);
});

test('mergePresenceSub passes through non-JSON frames', () => {
  const r = core.mergePresenceSub('not json', ['U123ABC']);
  assert.equal(r.changed, false);
  assert.equal(r.frame, 'not json');
  assert.equal(r.clientIds, null);
});

test('mergePresenceSub passes through non-presence_sub frames', () => {
  const f = JSON.stringify({ type: 'ping', id: 1 });
  const r = core.mergePresenceSub(f, ['U123ABC']);
  assert.equal(r.changed, false);
  assert.equal(r.frame, f);
});

test('mergePresenceSub merges watchlist ids not already present', () => {
  const f = JSON.stringify({ type: 'presence_sub', ids: ['U111AAA'] });
  const r = core.mergePresenceSub(f, ['U222BBB', 'U111AAA']);
  assert.equal(r.changed, true);
  assert.deepEqual(r.clientIds, ['U111AAA']);
  assert.deepEqual(r.injectedIds, ['U222BBB']);
  assert.deepEqual(JSON.parse(r.frame).ids, ['U111AAA', 'U222BBB']);
  assert.equal(JSON.parse(r.frame).type, 'presence_sub');
});

test('mergePresenceSub is a no-op when watchlist adds nothing', () => {
  const f = JSON.stringify({ type: 'presence_sub', ids: ['U111AAA'] });
  const r = core.mergePresenceSub(f, ['U111AAA']);
  assert.equal(r.changed, false);
  assert.equal(r.frame, f);
  assert.deepEqual(r.injectedIds, []);
});

test('mergePresenceSub caps injected ids at WATCHLIST_CAP', () => {
  const watch = [];
  for (let i = 0; i < core.WATCHLIST_CAP + 20; i++) {
    watch.push('U' + String(i).padStart(5, '0') + 'Z');
  }
  const f = JSON.stringify({ type: 'presence_sub', ids: [] });
  const r = core.mergePresenceSub(f, watch);
  assert.equal(r.injectedIds.length, core.WATCHLIST_CAP);
  assert.equal(JSON.parse(r.frame).ids.length, core.WATCHLIST_CAP);
});

test('mergePresenceSub preserves other frame fields', () => {
  const f = JSON.stringify({ type: 'presence_sub', ids: ['U111AAA'], extra: 'keep' });
  const r = core.mergePresenceSub(f, ['U222BBB']);
  assert.equal(JSON.parse(r.frame).extra, 'keep');
});

test('recordSubscription marks newly added ids as pending baseline', () => {
  const s = core.emptyStore();
  core.recordSubscription(s, ['U111AAA'], ['U222BBB'], '2026-07-15T08:00:00.000Z');
  assert.deepEqual(s.lastSubscribedIds, ['U111AAA', 'U222BBB']);
  assert.deepEqual(s.pendingBaseline.sort(), ['U111AAA', 'U222BBB']);
  assert.equal(s.subscriptionLog.length, 1);
  assert.deepEqual(s.subscriptionLog[0], {
    at: '2026-07-15T08:00:00.000Z', clientIds: ['U111AAA'], injectedIds: ['U222BBB']
  });
});

test('recordSubscription drops ids no longer subscribed from pendingBaseline', () => {
  const s = core.emptyStore();
  core.recordSubscription(s, ['U111AAA', 'U222BBB'], [], '2026-07-15T08:00:00.000Z');
  core.recordSubscription(s, ['U111AAA'], [], '2026-07-15T08:01:00.000Z');
  assert.deepEqual(s.lastSubscribedIds, ['U111AAA']);
  assert.deepEqual(s.pendingBaseline, ['U111AAA']);
});

test('recordSubscription only adds genuinely new ids to pendingBaseline', () => {
  const s = core.emptyStore();
  core.recordSubscription(s, ['U111AAA'], [], '2026-07-15T08:00:00.000Z');
  s.pendingBaseline = []; // simulate baseline already consumed
  core.recordSubscription(s, ['U111AAA', 'U333CCC'], [], '2026-07-15T08:02:00.000Z');
  assert.deepEqual(s.pendingBaseline, ['U333CCC']);
});

test('recordSubscription trims the log to SUB_LOG_MAX', () => {
  const s = core.emptyStore();
  for (let i = 0; i < core.SUB_LOG_MAX + 10; i++) {
    core.recordSubscription(s, ['U111AAA'], [], '2026-07-15T08:00:00.000Z');
  }
  assert.equal(s.subscriptionLog.length, core.SUB_LOG_MAX);
});

test('applyPresenceEvent records first active event as a transition', () => {
  const s = core.emptyStore();
  const { transitions } = core.applyPresenceEvent(
    s, { ids: ['U111AAA'], presence: 'active' }, '2026-07-15T09:00:00.000Z');
  assert.equal(s.users.U111AAA.lastPresence, 'active');
  assert.equal(s.users.U111AAA.lastActiveAt, '2026-07-15T09:00:00.000Z');
  assert.equal(s.users.U111AAA.firstTrackedAt, '2026-07-15T09:00:00.000Z');
  assert.equal(transitions.length, 1);
  assert.deepEqual(transitions[0],
    { at: '2026-07-15T09:00:00.000Z', user: 'U111AAA', presence: 'active', baseline: false });
});

test('applyPresenceEvent marks baseline when id was pending', () => {
  const s = core.emptyStore();
  core.recordSubscription(s, ['U111AAA'], [], '2026-07-15T08:59:00.000Z');
  const { transitions } = core.applyPresenceEvent(
    s, { user: 'U111AAA', presence: 'away' }, '2026-07-15T09:00:00.000Z');
  assert.equal(transitions[0].baseline, true);
  assert.deepEqual(s.pendingBaseline, []);
  assert.equal(s.users.U111AAA.lastAwayAt, '2026-07-15T09:00:00.000Z');
});

test('applyPresenceEvent emits no transition on unchanged repeat', () => {
  const s = core.emptyStore();
  core.applyPresenceEvent(s, { user: 'U111AAA', presence: 'active' }, '2026-07-15T09:00:00.000Z');
  const { transitions } = core.applyPresenceEvent(
    s, { user: 'U111AAA', presence: 'active' }, '2026-07-15T09:05:00.000Z');
  assert.equal(transitions.length, 0);
  assert.equal(s.users.U111AAA.lastEventAt, '2026-07-15T09:05:00.000Z');
});

test('applyPresenceEvent handles a batched ids array', () => {
  const s = core.emptyStore();
  const { transitions } = core.applyPresenceEvent(
    s, { ids: ['U111AAA', 'U222BBB'], presence: 'active' }, '2026-07-15T09:00:00.000Z');
  assert.equal(transitions.length, 2);
});

test('applyPresenceEvent ignores invalid ids and bad presence', () => {
  const s = core.emptyStore();
  const a = core.applyPresenceEvent(s, { ids: ['bad-id'], presence: 'active' }, '2026-07-15T09:00:00.000Z');
  assert.equal(a.transitions.length, 0);
  const b = core.applyPresenceEvent(s, { ids: ['U111AAA'], presence: 'weird' }, '2026-07-15T09:00:00.000Z');
  assert.equal(b.transitions.length, 0);
});

test('formatTransitionLine produces a single-line JSON string', () => {
  const line = core.formatTransitionLine(
    { at: '2026-07-15T09:00:00.000Z', user: 'U111AAA', presence: 'away', baseline: false });
  assert.equal(line.indexOf('\n'), -1);
  assert.deepEqual(JSON.parse(line),
    { at: '2026-07-15T09:00:00.000Z', user: 'U111AAA', presence: 'away', baseline: false });
});

test('describeLastSeen reports online vs offline', () => {
  assert.deepEqual(
    core.describeLastSeen({ lastPresence: 'active', lastActiveAt: '2026-07-15T09:00:00.000Z' }),
    { state: 'online', lastOnlineAt: '2026-07-15T09:00:00.000Z' });
  assert.deepEqual(
    core.describeLastSeen({ lastPresence: 'away', lastActiveAt: '2026-07-15T08:00:00.000Z' }),
    { state: 'offline', lastOnlineAt: '2026-07-15T08:00:00.000Z' });
});

test('applyWatchlistUpdate adds a valid new id', () => {
  const r = core.applyWatchlistUpdate(['U111AAA'], { add: 'U222BBB' });
  assert.equal(r.changed, true);
  assert.deepEqual(r.users, ['U111AAA', 'U222BBB']);
});

test('applyWatchlistUpdate no-ops on duplicate add', () => {
  const r = core.applyWatchlistUpdate(['U111AAA'], { add: 'U111AAA' });
  assert.equal(r.changed, false);
  assert.deepEqual(r.users, ['U111AAA']);
});

test('applyWatchlistUpdate rejects invalid add ids', () => {
  const r = core.applyWatchlistUpdate(['U111AAA'], { add: 'not-an-id' });
  assert.equal(r.changed, false);
  assert.deepEqual(r.users, ['U111AAA']);
});

test('applyWatchlistUpdate removes an existing id', () => {
  const r = core.applyWatchlistUpdate(['U111AAA', 'U222BBB'], { remove: 'U111AAA' });
  assert.equal(r.changed, true);
  assert.deepEqual(r.users, ['U222BBB']);
});

test('applyWatchlistUpdate no-ops removing a missing id', () => {
  const r = core.applyWatchlistUpdate(['U111AAA'], { remove: 'U999ZZZ' });
  assert.equal(r.changed, false);
  assert.deepEqual(r.users, ['U111AAA']);
});

test('applyWatchlistUpdate does not mutate the input array', () => {
  const input = ['U111AAA'];
  core.applyWatchlistUpdate(input, { add: 'U222BBB' });
  assert.deepEqual(input, ['U111AAA']);
});

test('applyWatchlistUpdate handles null/garbage change', () => {
  assert.equal(core.applyWatchlistUpdate(['U111AAA'], null).changed, false);
  assert.equal(core.applyWatchlistUpdate(['U111AAA'], {}).changed, false);
});

const ROSTER = [
  { id: 'U1AAA11', name: 'jkrpes', real_name: 'Jan Krpes', display_name: 'honza' },
  { id: 'U2BBB22', name: 'jnovak', real_name: 'Jan Novak', display_name: '' },
  { id: 'U3CCC33', name: 'asmith', real_name: 'Alice Smith', display_name: 'ali' }
];

test('filterRoster matches case-insensitively on all name fields', () => {
  assert.deepEqual(core.filterRoster(ROSTER, 'JAN').map((e) => e.id), ['U1AAA11', 'U2BBB22']);
  assert.deepEqual(core.filterRoster(ROSTER, 'honza').map((e) => e.id), ['U1AAA11']);
  assert.deepEqual(core.filterRoster(ROSTER, 'smith').map((e) => e.id), ['U3CCC33']);
});

test('filterRoster returns [] for short or empty queries', () => {
  assert.deepEqual(core.filterRoster(ROSTER, 'j'), []);
  assert.deepEqual(core.filterRoster(ROSTER, '  '), []);
  assert.deepEqual(core.filterRoster(ROSTER, null), []);
});

test('filterRoster caps results at max', () => {
  const big = [];
  for (let i = 0; i < 30; i++) big.push({ id: 'U' + i, name: 'samename' + i });
  assert.equal(core.filterRoster(big, 'samename').length, 10);
  assert.equal(core.filterRoster(big, 'samename', 3).length, 3);
});

test('filterRoster tolerates garbage entries', () => {
  assert.deepEqual(core.filterRoster([null, 42, { id: 'U1', name: null }], 'xx'), []);
  assert.deepEqual(core.filterRoster('not-an-array', 'xx'), []);
});
