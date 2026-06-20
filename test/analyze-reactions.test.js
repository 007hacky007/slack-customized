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

test('authorOutliers aggregates skipped posts per author, sorted by total missed reactors', () => {
  const idx = A.buildIndex(DATA);
  const rows = A.authorOutliers(idx.posts, 'X', { minPosts: 1, minReactors: 3, top: 10 });
  assert.ok(!rows.find((r) => r.authorId === 'X'), 'X excluded as author');
  // Z: skipped ts5 (5 reactors) => skipped 1, missed 5, avg 5, popular(>=3) 1, top 5
  const z = rows.find((r) => r.authorId === 'Z');
  assert.equal(z.skipped, 1);
  assert.equal(z.missed, 5);
  assert.equal(z.avg, 5);
  assert.equal(z.popularSkipped, 1);
  assert.equal(z.top.reactorCount, 5);
  // Y: skipped ts2 + reply7.1 (1 reactor each) => skipped 2, missed 2, avg 1, popular 0
  const y = rows.find((r) => r.authorId === 'Y');
  assert.equal(y.skipped, 2);
  assert.equal(y.missed, 2);
  assert.equal(y.avg, 1);
  assert.equal(y.popularSkipped, 0);
  // sorted by missed desc => Z before Y
  assert.deepEqual(rows.map((r) => r.authorId), ['Z', 'Y']);
});

test('authorOutliers respects excludeThreads and top limit', () => {
  const idxNoThreads = A.buildIndex(DATA, { excludeThreads: true });
  const y = A.authorOutliers(idxNoThreads.posts, 'X', { minPosts: 1, minReactors: 3, top: 10 })
    .find((r) => r.authorId === 'Y');
  assert.equal(y.skipped, 1);   // reply7.1 dropped, only ts2 remains
  assert.equal(y.missed, 1);
  const idx = A.buildIndex(DATA);
  assert.equal(A.authorOutliers(idx.posts, 'X', { minPosts: 1, top: 1 }).length, 1);
});

test('authorOutliers excludes authors X never skipped and below minPosts', () => {
  const idx = A.buildIndex(DATA);
  // minPosts 2 keeps Y (4 reacted-to posts), drops Z (1)
  const rows = A.authorOutliers(idx.posts, 'X', { minPosts: 2, top: 10 });
  assert.ok(rows.find((r) => r.authorId === 'Y'));
  assert.ok(!rows.find((r) => r.authorId === 'Z'));
});

test('parseDateBoundary: YYYY-MM-DD maps to UTC start/end of day (seconds)', () => {
  assert.equal(A.parseDateBoundary('2026-05-01', false), Date.UTC(2026, 4, 1, 0, 0, 0, 0) / 1000);
  assert.equal(A.parseDateBoundary('2026-05-31', true), Date.UTC(2026, 4, 31, 23, 59, 59, 999) / 1000);
  assert.equal(A.parseDateBoundary(null, false), null);
  assert.throws(() => A.parseDateBoundary('not-a-date', false), /invalid date/);
  assert.throws(() => A.parseDateBoundary('2026-13-99', false), /invalid date/);  // impossible month/day
  assert.throws(() => A.parseDateBoundary('2026-02-30', false), /invalid date/);  // Feb 30
});

test('buildIndex filters posts by since/until (epoch seconds), per-post by its own ts', () => {
  // fixture ts are 1..7 plus reply 7.1
  assert.deepEqual(
    A.buildIndex(DATA, { since: 2, until: 5 }).posts.map((p) => p.ts).sort(),
    ['2', '3', '4', '5'],
  );
  assert.deepEqual(
    A.buildIndex(DATA, { since: 7 }).posts.map((p) => p.ts).sort(),
    ['7', '7.1'],
  );
  assert.deepEqual(
    A.buildIndex(DATA, { until: 1 }).posts.map((p) => p.ts),
    ['1'],
  );
  // a reply in range is kept even if we are not excluding threads
  assert.ok(A.buildIndex(DATA, { since: 7.05 }).posts.some((p) => p.ts === '7.1'));
});
