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
