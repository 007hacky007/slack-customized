const test = require('node:test');
const assert = require('node:assert/strict');
const A = require('../analyze-reactions.js');

// Fixture: X is the reactor we analyze. Y and Z are authors. W/V/U/T/S are extra reactors.
const DATA = {
  users: {
    X: { id: 'X', name: 'Xavier' },
    Y: { id: 'Y', name: 'Yara' },
    Z: { id: 'Z', name: 'Zed' },
  },
  messages: [
    { ts: '1', user: 'Y', text: 'y1', reactions: [{ name: 'a', users: ['X', 'Z'] }] },            // reacted; X reacted
    { ts: '2', user: 'Y', text: 'y2', reactions: [{ name: 'a', users: ['Z'] }] },                  // reacted; X did not
    { ts: '3', user: 'Y', text: 'y3', reactions: [] },                                              // no reaction -> excluded from denom
    { ts: '4', user: 'Y', text: 'y4', reactions: [{ name: 'a', users: ['X', 'Z', 'W', 'V'] }] },    // reacted; X reacted; 4 reactors
    { ts: '5', user: 'Z', text: 'z1', reactions: [{ name: 'a', users: ['W', 'V', 'U', 'T', 'S'] }] },// 5 reactors; X did NOT -> top outlier
    { ts: '6', user: 'X', text: 'x1', reactions: [{ name: 'a', users: ['Y', 'Z', 'W', 'V', 'U', 'T'] }] }, // X's own post -> excluded everywhere
    { ts: '7', user: 'Z', text: 'zp', reactions: [], replies: [
      { ts: '7.1', user: 'Y', text: 'yr', reactions: [{ name: 'a', users: ['Z'] }] },              // reply; reacted; X did not
    ] },
  ],
};

test('buildIndex includes replies by default, excludes them with excludeThreads', () => {
  assert.equal(A.buildIndex(DATA).posts.length, 8);                 // 7 top-level + 1 reply
  assert.equal(A.buildIndex(DATA, { excludeThreads: true }).posts.length, 7);
});

test('perAuthorStats: denominator is reacted-to posts; X and authorless excluded', () => {
  const idx = A.buildIndex(DATA);
  const rows = A.perAuthorStats(idx.posts, 'X', { minPosts: 1 });
  const byId = Object.fromEntries(rows.map((r) => [r.authorId, r]));
  assert.ok(!byId.X, 'X must not be compared to self');
  // Y reacted posts: ts1(X yes), ts2(no), ts4(yes), reply7.1(no) => 2/4 = 50%
  assert.equal(byId.Y.num, 2);
  assert.equal(byId.Y.denom, 4);
  assert.equal(Math.round(byId.Y.pct), 50);
  // Z reacted posts: ts5(no) => 0/1
  assert.equal(byId.Z.num, 0);
  assert.equal(byId.Z.denom, 1);
});

test('perAuthorStats respects excludeThreads', () => {
  const idx = A.buildIndex(DATA, { excludeThreads: true });
  const rows = A.perAuthorStats(idx.posts, 'X', { minPosts: 1 });
  const y = rows.find((r) => r.authorId === 'Y');
  assert.equal(y.denom, 3);   // reply dropped: ts1, ts2, ts4
  assert.equal(y.num, 2);
});

test('perAuthorStats drops authors below minPosts', () => {
  const idx = A.buildIndex(DATA);
  const rows = A.perAuthorStats(idx.posts, 'X', { minPosts: 2 });
  assert.ok(rows.find((r) => r.authorId === 'Y'));   // Y has 4 reacted posts
  assert.ok(!rows.find((r) => r.authorId === 'Z'));  // Z has only 1
});

test('perAuthorStats sorts by pct desc', () => {
  const idx = A.buildIndex(DATA);
  const rows = A.perAuthorStats(idx.posts, 'X', { minPosts: 1 });
  for (let i = 0; i < rows.length - 1; i++) assert.ok(rows[i].pct >= rows[i + 1].pct);
});

test('findOutliers ranks X-skipped posts by distinct reactor count; excludes X own + X-reacted', () => {
  const idx = A.buildIndex(DATA);
  const out = A.findOutliers(idx.posts, 'X', { top: 15 });
  assert.equal(out[0].ts, '5');             // Z's post, 5 reactors, X skipped
  assert.equal(out[0].reactorCount, 5);
  assert.equal(out[0].authorId, 'Z');
  assert.ok(!out.some((p) => p.ts === '6')); // X's own post excluded
  assert.ok(!out.some((p) => p.ts === '1')); // X reacted -> excluded
  assert.ok(!out.some((p) => p.ts === '3')); // no reaction -> excluded
  // remaining outliers are the 1-reactor X-skipped posts (ts2, ts7.1)
  assert.deepEqual(out.slice(1).map((p) => p.ts).sort(), ['2', '7.1']);
});

test('findOutliers respects top limit', () => {
  const idx = A.buildIndex(DATA);
  assert.equal(A.findOutliers(idx.posts, 'X', { top: 1 }).length, 1);
});

test('nameFor resolves via users map then falls back to id', () => {
  assert.equal(A.nameFor('Y', DATA.users, {}), 'Yara');
  assert.equal(A.nameFor('Q', DATA.users, {}), 'Q');
  assert.equal(A.nameFor('Q', DATA.users, { user_name: 'Quinn' }), 'Quinn');
});
