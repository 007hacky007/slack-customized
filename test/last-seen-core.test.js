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
