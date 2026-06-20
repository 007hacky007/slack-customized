#!/usr/bin/env node
'use strict';

// Analyze a channel JSON export (produced by the "Export Channel as JSON" feature).
// Pick a reactor X, then see, per author Y, what share of Y's reacted-to posts X also
// reacted to - plus the popular posts X skipped (outliers).
//
// Usage:
//   node analyze-reactions.js <export.json> [options]
// Options:
//   --exclude-threads     count only top-level messages (ignore thread replies)
//   --min-posts N         hide authors with fewer than N reacted-to posts (default 5)
//   --top-outliers N      number of skipped-popular posts to show (default 15)
//   --user <id|name>      skip the interactive picker; choose reactor X directly

const fs = require('fs');
const readline = require('readline');

// ----------------------------- pure core -----------------------------

function snippet(text, max) {
  max = max || 80;
  const s = String(text == null ? '' : text).replace(/\s+/g, ' ').trim();
  return s.length > max ? s.slice(0, max - 1) + '…' : s;
}

function nameFor(id, usersMap, post) {
  const u = (usersMap && usersMap[id]) || null;
  return (u && (u.name || u.real_name))
    || (post && post.user_name)
    || id
    || '(unknown)';
}

function distinctReactors(post) {
  const s = new Set();
  if (Array.isArray(post.reactions)) {
    for (const r of post.reactions) {
      for (const u of (r.users || [])) s.add(u);
    }
  }
  return s;
}

function postRecord(post, usersMap) {
  const authorId = post.user || post.bot_id || null;
  const reactorSet = distinctReactors(post);
  return {
    authorId,
    authorName: nameFor(authorId, usersMap, post),
    ts: post.ts,
    text: snippet(post.text),
    reactorSet,
    reactorCount: reactorSet.size,
    hasReaction: Array.isArray(post.reactions) && post.reactions.length > 0,
  };
}

function buildIndex(data, opts) {
  opts = opts || {};
  const excludeThreads = !!opts.excludeThreads;
  const usersMap = (data && data.users) || {};
  const posts = [];
  for (const m of ((data && data.messages) || [])) {
    posts.push(postRecord(m, usersMap));
    if (!excludeThreads && Array.isArray(m.replies)) {
      for (const r of m.replies) posts.push(postRecord(r, usersMap));
    }
  }
  // Per-user activity (for the picker): posts authored, and distinct posts reacted to.
  const activity = new Map();
  const bump = (id, key) => {
    if (!id) return;
    const a = activity.get(id) || { posts: 0, reacted: 0 };
    a[key]++;
    activity.set(id, a);
  };
  for (const p of posts) {
    bump(p.authorId, 'posts');
    for (const u of p.reactorSet) bump(u, 'reacted');
  }
  return { posts, activity, usersMap };
}

function perAuthorStats(posts, xId, opts) {
  opts = opts || {};
  const minPosts = opts.minPosts != null ? opts.minPosts : 5;
  const byAuthor = new Map();
  for (const p of posts) {
    if (!p.authorId || p.authorId === xId) continue;
    if (!p.hasReaction) continue;
    const a = byAuthor.get(p.authorId) || { authorId: p.authorId, name: p.authorName, denom: 0, num: 0 };
    a.denom++;
    if (p.reactorSet.has(xId)) a.num++;
    byAuthor.set(p.authorId, a);
  }
  const rows = [];
  for (const a of byAuthor.values()) {
    if (a.denom < minPosts) continue;
    rows.push({ authorId: a.authorId, name: a.name, num: a.num, denom: a.denom, pct: a.denom ? (a.num / a.denom) * 100 : 0 });
  }
  rows.sort((x, y) => (y.pct - x.pct) || (y.denom - x.denom) || x.name.localeCompare(y.name));
  return rows;
}

function findOutliers(posts, xId, opts) {
  opts = opts || {};
  const top = opts.top != null ? opts.top : 15;
  const cands = posts.filter((p) =>
    p.authorId && p.authorId !== xId && p.hasReaction && !p.reactorSet.has(xId));
  cands.sort((a, b) => (b.reactorCount - a.reactorCount) || (parseFloat(b.ts) - parseFloat(a.ts)));
  return cands.slice(0, top);
}

// "Which authors don't appeal to X": for each author Y, aggregate Y's reacted-to posts
// that X skipped - total missed reactors (primary rank), avg popularity of those skips,
// and how many were "popular" (>= minReactors), plus the single most-reacted skipped post.
function authorOutliers(posts, xId, opts) {
  opts = opts || {};
  const minPosts = opts.minPosts != null ? opts.minPosts : 5;
  const minReactors = opts.minReactors != null ? opts.minReactors : 5;
  const top = opts.top != null ? opts.top : 15;
  const byAuthor = new Map();
  for (const p of posts) {
    if (!p.authorId || p.authorId === xId) continue;
    if (!p.hasReaction) continue;
    let a = byAuthor.get(p.authorId);
    if (!a) {
      a = { authorId: p.authorId, name: p.authorName, denom: 0, skipped: 0, missed: 0, popularSkipped: 0, top: null };
      byAuthor.set(p.authorId, a);
    }
    a.denom++;
    if (!p.reactorSet.has(xId)) {
      a.skipped++;
      a.missed += p.reactorCount;
      if (p.reactorCount >= minReactors) a.popularSkipped++;
      if (!a.top || p.reactorCount > a.top.reactorCount) {
        a.top = { reactorCount: p.reactorCount, ts: p.ts, text: p.text };
      }
    }
  }
  const rows = [];
  for (const a of byAuthor.values()) {
    if (a.denom < minPosts || a.skipped === 0) continue;
    rows.push({
      authorId: a.authorId,
      name: a.name,
      denom: a.denom,
      skipped: a.skipped,
      missed: a.missed,
      avg: a.skipped ? a.missed / a.skipped : 0,
      popularSkipped: a.popularSkipped,
      top: a.top,
    });
  }
  rows.sort((x, y) => (y.missed - x.missed) || (y.skipped - x.skipped) || x.name.localeCompare(y.name));
  return rows.slice(0, top);
}

// ----------------------------- CLI / IO -----------------------------

function parseArgs(argv) {
  const out = { file: null, excludeThreads: false, minPosts: 5, topOutliers: 15, minReactors: 5, user: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--exclude-threads') out.excludeThreads = true;
    else if (a === '--min-posts') out.minPosts = parseInt(argv[++i], 10);
    else if (a === '--top-outliers') out.topOutliers = parseInt(argv[++i], 10);
    else if (a === '--min-reactors') out.minReactors = parseInt(argv[++i], 10);
    else if (a === '--user') out.user = argv[++i];
    else if (a.startsWith('--')) throw new Error('unknown option: ' + a);
    else if (!out.file) out.file = a;
    else throw new Error('unexpected argument: ' + a);
  }
  if (!Number.isFinite(out.minPosts) || out.minPosts < 1) out.minPosts = 5;
  if (!Number.isFinite(out.topOutliers) || out.topOutliers < 1) out.topOutliers = 15;
  if (!Number.isFinite(out.minReactors) || out.minReactors < 1) out.minReactors = 5;
  return out;
}

function dateOf(ts) {
  const n = parseFloat(ts);
  if (!isFinite(n)) return '????-??-??';
  return new Date(n * 1000).toISOString().slice(0, 10);
}

function resolveUser(arg, index) {
  if (index.usersMap[arg] || index.activity.has(arg)) return arg;
  const lc = String(arg).toLowerCase();
  const matches = [...index.activity.keys()].filter((id) => {
    const u = index.usersMap[id] || {};
    return id.toLowerCase() === lc
      || String(u.name || '').toLowerCase().includes(lc)
      || String(u.real_name || '').toLowerCase().includes(lc);
  });
  return matches; // [] none, [id] unique, [..] ambiguous
}

function pickUserInteractive(index) {
  const users = [...index.activity.entries()]
    .map(([id, a]) => ({ id, name: nameFor(id, index.usersMap, {}), posts: a.posts, reacted: a.reacted }))
    .sort((x, y) => (y.posts + y.reacted) - (x.posts + x.reacted) || x.name.localeCompare(y.name));
  console.log('\nUsers (sorted by activity):\n');
  users.forEach((u, i) => {
    console.log('  ' + String(i + 1).padStart(3) + '. ' + u.name.padEnd(28)
      + '  ' + String(u.posts).padStart(5) + ' posts'
      + '  ' + String(u.reacted).padStart(5) + ' reacted'
      + '   (' + u.id + ')');
  });
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question('\nSelect the reactor (number), or paste a user id: ', (ans) => {
      rl.close();
      const trimmed = String(ans).trim();
      const n = parseInt(trimmed, 10);
      if (Number.isFinite(n) && n >= 1 && n <= users.length && String(n) === trimmed) {
        resolve(users[n - 1].id);
      } else if (index.activity.has(trimmed) || index.usersMap[trimmed]) {
        resolve(trimmed);
      } else {
        resolve(null);
      }
    });
  });
}

function bar(pct, width) {
  width = width || 20;
  const filled = Math.round((pct / 100) * width);
  return '#'.repeat(filled) + '.'.repeat(width - filled);
}

function report(index, xId, opts) {
  const xName = nameFor(xId, index.usersMap, {});
  const threadNote = opts.excludeThreads ? ' (thread replies excluded)' : '';

  const rows = perAuthorStats(index.posts, xId, { minPosts: opts.minPosts });
  console.log('\n=== How often ' + xName + ' reacts to each author\'s reacted-to posts'
    + threadNote + ' ===');
  console.log('(denominator = that author\'s posts which got at least one reaction; '
    + 'min ' + opts.minPosts + ' such posts)\n');
  if (!rows.length) {
    console.log('  (no authors meet the threshold)');
  } else {
    const nameW = Math.min(30, Math.max(12, ...rows.map((r) => r.name.length)));
    for (const r of rows) {
      console.log('  ' + r.name.padEnd(nameW)
        + '  ' + (r.num + '/' + r.denom).padStart(9)
        + '  ' + (r.pct.toFixed(0) + '%').padStart(5)
        + '  ' + bar(r.pct));
    }
  }

  const authorRows = authorOutliers(index.posts, xId, {
    minPosts: opts.minPosts, minReactors: opts.minReactors, top: opts.topOutliers,
  });
  console.log('\n=== Which authors do not appeal to ' + xName
    + ': well-received posts ' + xName + ' skips (top ' + opts.topOutliers + ')' + threadNote + ' ===');
  console.log('(skipped = that author\'s reacted-to posts ' + xName + ' did not react to; '
    + 'missed = total reactors on them [recommended sort]; '
    + 'popular = skips with >= ' + opts.minReactors + ' reactors)\n');
  if (!authorRows.length) {
    console.log('  (no authors meet the threshold)');
  } else {
    const nameW = Math.min(30, Math.max(12, ...authorRows.map((r) => r.name.length)));
    console.log('  ' + 'author'.padEnd(nameW) + '  ' + 'skipped'.padStart(9)
      + '  ' + 'missed'.padStart(6) + '  ' + 'avg'.padStart(5) + '  ' + 'popular'.padStart(7)
      + '   top skipped');
    for (const r of authorRows) {
      const ex = r.top ? '(' + r.top.reactorCount + ') "' + r.top.text + '"' : '';
      console.log('  ' + r.name.padEnd(nameW)
        + '  ' + (r.skipped + '/' + r.denom).padStart(9)
        + '  ' + String(r.missed).padStart(6)
        + '  ' + r.avg.toFixed(1).padStart(5)
        + '  ' + String(r.popularSkipped).padStart(7)
        + '   ' + ex);
    }
  }

  const outliers = findOutliers(index.posts, xId, { top: opts.topOutliers });
  console.log('\n=== Outliers: individual popular posts ' + xName + ' did NOT react to (top '
    + opts.topOutliers + ')' + threadNote + ' ===');
  console.log('(ranked by number of distinct reactors)\n');
  if (!outliers.length) {
    console.log('  (none)');
  } else {
    for (const p of outliers) {
      console.log('  ' + String(p.reactorCount).padStart(3) + ' reactors'
        + '  ' + dateOf(p.ts)
        + '  ' + p.authorName.padEnd(22)
        + '  "' + p.text + '"');
    }
  }
  console.log('');
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (e) {
    console.error(e.message);
    process.exit(2);
  }
  if (!opts.file) {
    console.error('Usage: node analyze-reactions.js <export.json> '
      + '[--exclude-threads] [--min-posts N] [--top-outliers N] [--user <id|name>]');
    process.exit(2);
  }

  let data;
  try {
    data = JSON.parse(fs.readFileSync(opts.file, 'utf8'));
  } catch (e) {
    console.error('Could not read/parse JSON: ' + e.message);
    process.exit(1);
  }

  const index = buildIndex(data, { excludeThreads: opts.excludeThreads });
  if (!index.posts.length) {
    console.error('No messages found in the export.');
    process.exit(1);
  }

  let xId = null;
  if (opts.user) {
    const r = resolveUser(opts.user, index);
    if (typeof r === 'string') {
      xId = r;
    } else if (Array.isArray(r) && r.length === 1) {
      xId = r[0];
    } else if (Array.isArray(r) && r.length === 0) {
      console.error('No user matched "' + opts.user + '".');
      process.exit(1);
    } else {
      console.error('Ambiguous user "' + opts.user + '" matches: '
        + r.map((id) => nameFor(id, index.usersMap, {}) + ' (' + id + ')').join(', '));
      process.exit(1);
    }
  } else {
    xId = await pickUserInteractive(index);
    if (!xId) {
      console.error('No valid selection.');
      process.exit(1);
    }
  }

  report(index, xId, opts);
}

module.exports = {
  snippet, nameFor, distinctReactors, postRecord,
  buildIndex, perAuthorStats, findOutliers, authorOutliers,
  parseArgs, dateOf, resolveUser,
};

if (require.main === module) {
  main();
}
