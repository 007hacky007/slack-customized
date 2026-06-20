# Channel JSON Export (Web API) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "File -> Export Channel as JSON..." feature that exports the entire current-channel history (messages, threads, replies, reactions with authors, resolved users/bots) to a JSON file via Slack's internal web API.

**Architecture:** All pure + injectable logic lives in a new, unit-tested CommonJS module `export-core.js` (no Electron/DOM/`fetch` dependencies; async functions take an injected `apiCall`). The Electron glue in `main.js` (menu + streaming save IPC) and `preload.js` (token discovery, the real rate-limited `apiCall`, progress overlay, orchestration wiring) is thin and manually verified. The bash builder copies `export-core.js` into the app dir so both processes can `require('./export-core.js')`.

**Tech Stack:** Bash builder generating an Electron app (Node + Chromium). Tests use Node's built-in `node:test` + `node:assert/strict` (`node --test`). No new runtime dependencies.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-06-20-channel-json-export-design.md` (authoritative).
- API host derived per team: `https://<team>.slack.com/api/<method>`; requests are `POST multipart/form-data` with a `token` field; `credentials:'include'` sends the `d` cookie automatically.
- **Message/thread/reply coverage is a HARD requirement:** any failure to fully paginate history/replies aborts the export (no partial file). Reaction-author + actor resolution are best-effort and recorded in `export.complete` / `export.counts` / `export.warnings`.
- No Unicode dashes anywhere in code/docs/commits; use the plain hyphen-minus `-`.
- Do not use any personal data (email, name, handles) in code, headers, configs, or commit metadata.
- `export-core.js` must use only cross-environment JS (no `require` of node/electron, no DOM, no `fetch`/`FormData`) so it loads in both the Node test runner and the renderer.
- Git: commit at the end of every task. Repo default branch is `master`; commit directly there (existing project workflow).
- Menu accelerator for this feature: `CmdOrCtrl+Shift+E`.

---

## File Structure

- **Create `export-core.js`** (repo root) - pure helpers + injectable async orchestration. The tested heart.
- **Create `test/export-core.test.js`** - `node:test` unit tests for every export-core export.
- **Modify `slack-autocomplete-electron-app.sh`:**
  - Copy `export-core.js` from `$SCRIPT_DIR` into `$APP_DIR` at build time.
  - `main.js` heredoc: `require('./export-core.js')`, add the File menu item, add the four streaming save IPC handlers.
  - `preload.js` heredoc: `require('./export-core.js')`, add config/token discovery, the real rate-limited `apiCall`, the progress overlay, and the export trigger that runs `runExport` and streams the result to main.

`export-core.js` public API (the contract every task below must keep consistent):

```
// config / url
parseClientUrl(pathname) -> { teamId, channelId } | null
getTokenForTeam(localConfigRaw, teamId) -> string | null
inferApiBase(localConfigRaw, teamId) -> string | null   // e.g. 'https://cdn77.slack.com/api/'
workspaceFromConfig(localConfigRaw, teamId) -> { team_id, name }

// filename
sanitizeExportFilename(name, opts?) -> string            // safe basename ending in .json

// pagination / list helpers
getNextCursor(resp) -> string | null
responseHasMore(resp) -> boolean
accumulateByTs(map, items) -> number                     // count of newly added
finalizeThreadReplies(map, threadTs) -> array            // parent removed, sorted asc
reactionNeedsBackfill(reaction) -> boolean
messageNeedsReactionBackfill(message) -> boolean

// actors
resolveActorRef(message) -> { kind:'user'|'bot'|'unknown', id?, embeddedProfile?, username? } | null
buildUserEntry(userObj) -> entry
buildBotEntry(botObjOrProfile, botId) -> entry
collectActorRefs(messages) -> { userIds:Set, botIds:Set, embeddedBotProfiles:Map }
pickInlineName(entry) -> string | null

// completeness
createReport() -> { counts, warnings, setBaseCounts, addTruncatedReaction, addUnresolvedActor, build(exportedAt) }

// rate limit / backoff
TIERS, methodTier(method) -> string, tierIntervalMs(method) -> ms
parseRetryAfter(value) -> seconds
backoffDelay(attempt) -> ms

// serializer
streamExportJson(doc) -> Iterable<string>

// async orchestration (apiCall(method, params) -> Promise<respJson>)
fetchAllHistory(apiCall, { channel }, hooks?) -> messages[]
fetchThreadReplies(apiCall, { channel, threadTs }, hooks?) -> replies[]
backfillReactions(apiCall, { channel }, messages, report, hooks?) -> void (mutates)
resolveActors(apiCall, refs, report, hooks?) -> usersMap
runExport(apiCall, ctx, hooks?) -> doc
// hooks: { signal?: AbortSignal, onProgress?(phase, current, total) }
```

---

### Task 1: Test harness + config/URL helpers

**Files:**
- Create: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Produces: `parseClientUrl`, `getTokenForTeam`, `inferApiBase`, `workspaceFromConfig`.

- [ ] **Step 1: Write the failing tests**

Create `test/export-core.test.js`:

```js
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --test`
Expected: FAIL (`Cannot find module '../export-core.js'`).

- [ ] **Step 3: Create export-core.js with the helpers**

Create `export-core.js`:

```js
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

module.exports = {
  parseClientUrl, getTokenForTeam, inferApiBase, workspaceFromConfig,
};
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: export-core config and URL helpers"
```

---

### Task 2: sanitizeExportFilename

**Files:**
- Modify: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Produces: `sanitizeExportFilename(name, opts?)` (used by the main-process save handler in Task 14).

- [ ] **Step 1: Write the failing tests** (append to `test/export-core.test.js`)

```js
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
```

- [ ] **Step 2: Run to verify failure**

Run: `node --test`
Expected: FAIL (`sanitizeExportFilename is not a function`).

- [ ] **Step 3: Implement** (add function to `export-core.js` and to `module.exports`)

```js
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
```

Add `sanitizeExportFilename` to `module.exports`.

- [ ] **Step 4: Run to verify pass**

Run: `node --test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: export-core filename sanitizer"
```

---

### Task 3: Pagination, thread-finalize, and reaction predicates

**Files:**
- Modify: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Produces: `getNextCursor`, `responseHasMore`, `accumulateByTs`, `finalizeThreadReplies`, `reactionNeedsBackfill`, `messageNeedsReactionBackfill`.

- [ ] **Step 1: Write the failing tests** (append)

```js
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
```

- [ ] **Step 2: Run to verify failure**

Run: `node --test`
Expected: FAIL (functions undefined).

- [ ] **Step 3: Implement** (add to `export-core.js` + `module.exports`)

```js
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
```

Add all six names to `module.exports`.

- [ ] **Step 4: Run to verify pass**

Run: `node --test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: export-core pagination, thread-finalize, reaction predicates"
```

---

### Task 4: Actor model helpers

**Files:**
- Modify: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Produces: `resolveActorRef`, `buildUserEntry`, `buildBotEntry`, `collectActorRefs`, `pickInlineName`.

- [ ] **Step 1: Write the failing tests** (append)

```js
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
```

- [ ] **Step 2: Run to verify failure**

Run: `node --test`
Expected: FAIL.

- [ ] **Step 3: Implement** (add to `export-core.js` + `module.exports`)

```js
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
```

Add all five names to `module.exports`.

- [ ] **Step 4: Run to verify pass**

Run: `node --test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: export-core actor model helpers"
```

---

### Task 5: Completeness report

**Files:**
- Modify: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Produces: `createReport()` returning `{ counts, warnings, setBaseCounts, addTruncatedReaction, addUnresolvedActor, build(exportedAt) }`.

- [ ] **Step 1: Write the failing tests** (append)

```js
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
```

- [ ] **Step 2: Run to verify failure**

Run: `node --test`
Expected: FAIL.

- [ ] **Step 3: Implement** (add to `export-core.js` + `module.exports`)

```js
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
```

Add `createReport` to `module.exports`.

- [ ] **Step 4: Run to verify pass**

Run: `node --test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: export-core completeness report"
```

---

### Task 6: Rate-limit tiers and backoff helpers

**Files:**
- Modify: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Produces: `TIERS`, `methodTier`, `tierIntervalMs`, `parseRetryAfter`, `backoffDelay` (consumed by the real `apiCall` in Task 15).

- [ ] **Step 1: Write the failing tests** (append)

```js
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
```

- [ ] **Step 2: Run to verify failure**

Run: `node --test`
Expected: FAIL.

- [ ] **Step 3: Implement** (add to `export-core.js` + `module.exports`)

```js
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
```

Add `TIERS`, `methodTier`, `tierIntervalMs`, `parseRetryAfter`, `backoffDelay` to `module.exports`.

- [ ] **Step 4: Run to verify pass**

Run: `node --test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: export-core rate-limit and backoff helpers"
```

---

### Task 7: Streaming JSON serializer

**Files:**
- Modify: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Produces: `streamExportJson(doc)` -> iterable of string chunks whose concatenation is valid JSON equal to `doc`.

- [ ] **Step 1: Write the failing tests** (append)

```js
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
```

- [ ] **Step 2: Run to verify failure**

Run: `node --test`
Expected: FAIL.

- [ ] **Step 3: Implement** (add to `export-core.js` + `module.exports`)

```js
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
```

Add `streamExportJson` to `module.exports`.

- [ ] **Step 4: Run to verify pass**

Run: `node --test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: export-core streaming JSON serializer"
```

---

### Task 8: fetchAllHistory (cursor pagination, hard-fail on stall)

**Files:**
- Modify: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Consumes: `accumulateByTs`, `getNextCursor`, `responseHasMore`.
- Produces: `fetchAllHistory(apiCall, { channel }, hooks?)` -> messages sorted ascending by ts. Also adds an internal `throwIfAborted` helper (not exported).

- [ ] **Step 1: Write the failing tests** (append)

```js
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
```

- [ ] **Step 2: Run to verify failure**

Run: `node --test`
Expected: FAIL.

- [ ] **Step 3: Implement** (add to `export-core.js` + `module.exports`)

```js
function throwIfAborted(signal) {
  if (signal && signal.aborted) { const e = new Error('aborted'); e.name = 'AbortError'; throw e; }
}

async function fetchAllHistory(apiCall, opts, hooks) {
  hooks = hooks || {};
  const channel = opts.channel;
  const map = new Map();
  let cursor = null;
  for (;;) {
    throwIfAborted(hooks.signal);
    const params = { channel, limit: 200, ignore_replies: true, no_user_profile: true };
    if (cursor) params.cursor = cursor;
    const resp = await apiCall('conversations.history', params);
    if (!resp || resp.ok === false) throw new Error('conversations.history failed: ' + (resp && resp.error));
    accumulateByTs(map, resp.messages || []);
    if (hooks.onProgress) hooks.onProgress('messages', map.size, null);
    if (!responseHasMore(resp)) break;
    const next = getNextCursor(resp);
    if (!next) throw new Error('history pagination stalled: has_more without next_cursor');
    if (cursor && next === cursor) throw new Error('history pagination stalled: cursor did not advance');
    cursor = next;
  }
  return Array.from(map.values()).sort((a, b) => parseFloat(a.ts) - parseFloat(b.ts));
}
```

Add `fetchAllHistory` to `module.exports`.

- [ ] **Step 4: Run to verify pass**

Run: `node --test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: export-core fetchAllHistory with hard-fail on stall"
```

---

### Task 9: fetchThreadReplies (cursor-first, window fallback)

**Files:**
- Modify: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Consumes: `accumulateByTs`, `getNextCursor`, `responseHasMore`, `finalizeThreadReplies`, `throwIfAborted`.
- Produces: `fetchThreadReplies(apiCall, { channel, threadTs }, hooks?)` -> replies sorted asc, parent removed.

- [ ] **Step 1: Write the failing tests** (append)

```js
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
```

- [ ] **Step 2: Run to verify failure**

Run: `node --test`
Expected: FAIL.

- [ ] **Step 3: Implement** (add to `export-core.js` + `module.exports`)

```js
async function fetchThreadReplies(apiCall, opts, hooks) {
  hooks = hooks || {};
  const channel = opts.channel;
  const threadTs = opts.threadTs;
  const map = new Map();
  let cursor = null;
  let useWindow = false;
  let maxTs = null;
  let noProgress = 0;
  for (;;) {
    throwIfAborted(hooks.signal);
    const params = { channel, ts: threadTs, limit: 200 };
    if (useWindow) { if (maxTs) { params.oldest = maxTs; params.inclusive = false; } }
    else if (cursor) { params.cursor = cursor; }
    const resp = await apiCall('conversations.replies', params);
    if (!resp || resp.ok === false) throw new Error('conversations.replies failed: ' + (resp && resp.error));
    const items = resp.messages || [];
    const added = accumulateByTs(map, items);
    for (const m of items) { if (m && m.ts && (maxTs === null || parseFloat(m.ts) > parseFloat(maxTs))) maxTs = m.ts; }
    if (hooks.onProgress) hooks.onProgress('thread-page', map.size, null);
    if (!responseHasMore(resp)) break;
    if (!useWindow) {
      const next = getNextCursor(resp);
      if (next && next !== cursor) { cursor = next; continue; }
      useWindow = true; // no/stale cursor -> switch to oldest-window fallback
    }
    if (useWindow) { if (added === 0) { if (++noProgress >= 2) break; } else noProgress = 0; }
  }
  return finalizeThreadReplies(map, threadTs);
}
```

Add `fetchThreadReplies` to `module.exports`.

- [ ] **Step 4: Run to verify pass**

Run: `node --test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: export-core fetchThreadReplies with cursor and window fallback"
```

---

### Task 10: backfillReactions

**Files:**
- Modify: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Consumes: `reactionNeedsBackfill`, `throwIfAborted`, a report from `createReport`.
- Produces: `backfillReactions(apiCall, { channel }, messages, report, hooks?)` (mutates reactions in place: sets `users` (when fuller) and `users_truncated`; records warnings). Internal `extractReactionUsers(resp, name)` (not exported).

- [ ] **Step 1: Write the failing tests** (append)

```js
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
```

- [ ] **Step 2: Run to verify failure**

Run: `node --test`
Expected: FAIL.

- [ ] **Step 3: Implement** (add to `export-core.js` + `module.exports`)

```js
function extractReactionUsers(resp, name) {
  const msg = resp.message || (resp.messages && resp.messages[0]) || null;
  if (!msg || !Array.isArray(msg.reactions)) return null;
  const found = msg.reactions.find((x) => x.name === name);
  return found ? (found.users || []) : null;
}

async function backfillReactions(apiCall, ctx, messages, report, hooks) {
  hooks = hooks || {};
  const targets = [];
  function visit(m) {
    if (Array.isArray(m.reactions)) for (const r of m.reactions) targets.push({ m, r });
    if (Array.isArray(m.replies)) for (const rep of m.replies) visit(rep);
  }
  for (const m of (messages || [])) visit(m);

  let done = 0;
  const total = targets.length;
  for (const { m, r } of targets) {
    throwIfAborted(hooks.signal);
    if (reactionNeedsBackfill(r)) {
      let resp = null;
      try { resp = await apiCall('reactions.get', { channel: ctx.channel, timestamp: m.ts, full: true }); } catch (e) { resp = null; }
      const full = (resp && resp.ok) ? extractReactionUsers(resp, r.name) : null;
      const have = (r.users && r.users.length) || 0;
      if (full && full.length >= (r.count | 0)) { r.users = full; r.users_truncated = false; }
      else {
        if (full && full.length > have) r.users = full;
        r.users_truncated = true;
        report.addTruncatedReaction(m.ts, r.name, (r.users && r.users.length) || 0, r.count | 0);
      }
    } else {
      r.users_truncated = false;
    }
    done++;
    if (hooks.onProgress) hooks.onProgress('reactions', done, total);
  }
}
```

Add `backfillReactions` to `module.exports`.

- [ ] **Step 4: Run to verify pass**

Run: `node --test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: export-core reaction author backfill"
```

---

### Task 11: resolveActors

**Files:**
- Modify: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Consumes: `buildUserEntry`, `buildBotEntry`, `throwIfAborted`, a report.
- Produces: `resolveActors(apiCall, refs, report, hooks?)` -> users map keyed by id (`refs` shape from `collectActorRefs`).

- [ ] **Step 1: Write the failing tests** (append)

```js
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
```

- [ ] **Step 2: Run to verify failure**

Run: `node --test`
Expected: FAIL.

- [ ] **Step 3: Implement** (add to `export-core.js` + `module.exports`)

```js
async function resolveActors(apiCall, refs, report, hooks) {
  hooks = hooks || {};
  const users = {};
  const total = refs.userIds.size + refs.botIds.size;
  let done = 0;
  for (const id of refs.userIds) {
    throwIfAborted(hooks.signal);
    let resp = null;
    try { resp = await apiCall('users.info', { user: id }); } catch (e) { resp = null; }
    if (resp && resp.ok && resp.user) users[id] = buildUserEntry(resp.user);
    else { users[id] = { id, kind: 'user', name: id, unresolved: true }; report.addUnresolvedActor(id, 'user'); }
    done++;
    if (hooks.onProgress) hooks.onProgress('actors', done, total);
  }
  for (const id of refs.botIds) {
    throwIfAborted(hooks.signal);
    const prof = refs.embeddedBotProfiles.get(id);
    if (prof) { users[id] = buildBotEntry(prof, id); }
    else {
      let resp = null;
      try { resp = await apiCall('bots.info', { bot: id }); } catch (e) { resp = null; }
      if (resp && resp.ok && resp.bot) users[id] = buildBotEntry(resp.bot, id);
      else { users[id] = { id, kind: 'bot', name: id, unresolved: true }; report.addUnresolvedActor(id, 'bot'); }
    }
    done++;
    if (hooks.onProgress) hooks.onProgress('actors', done, total);
  }
  return users;
}
```

Add `resolveActors` to `module.exports`.

- [ ] **Step 4: Run to verify pass**

Run: `node --test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: export-core actor resolution"
```

---

### Task 12: runExport orchestrator

**Files:**
- Modify: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Consumes: every async function + `collectActorRefs`, `resolveActorRef`, `pickInlineName`, `createReport`.
- Produces: `runExport(apiCall, ctx, hooks?)` -> the full export document. `ctx = { channelId, channel, workspace, exportedAt }`.

- [ ] **Step 1: Write the failing tests** (append)

```js
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
```

- [ ] **Step 2: Run to verify failure**

Run: `node --test`
Expected: FAIL.

- [ ] **Step 3: Implement** (add to `export-core.js` + `module.exports`)

```js
async function runExport(apiCall, ctx, hooks) {
  hooks = hooks || {};
  const report = createReport();

  const messages = await fetchAllHistory(apiCall, { channel: ctx.channelId }, hooks);

  const parents = messages.filter((m) => (m.reply_count | 0) > 0);
  let ti = 0;
  for (const m of parents) {
    throwIfAborted(hooks.signal);
    m.replies = await fetchThreadReplies(apiCall, { channel: ctx.channelId, threadTs: m.thread_ts || m.ts }, hooks);
    ti++;
    if (hooks.onProgress) hooks.onProgress('threads', ti, parents.length);
  }

  await backfillReactions(apiCall, { channel: ctx.channelId }, messages, report, hooks);

  const refs = collectActorRefs(messages);
  const users = await resolveActors(apiCall, refs, report, hooks);

  let replyCount = 0;
  let reactionCount = 0;
  function enrich(m) {
    const ref = resolveActorRef(m);
    if (ref) {
      if (ref.kind === 'user' && ref.id) { const e = users[ref.id]; m.user_name = e ? pickInlineName(e) : ref.id; }
      else if (ref.kind === 'bot' && ref.id) { const e = users[ref.id]; m.user_name = e ? pickInlineName(e) : (ref.username || ref.id); m.actor_kind = 'bot'; }
      else if (ref.username) { m.user_name = ref.username; m.actor_kind = 'unknown'; }
    }
    if (Array.isArray(m.reactions)) {
      for (const r of m.reactions) {
        reactionCount++;
        r.user_names = (r.users || []).map((id) => { const e = users[id]; return e ? pickInlineName(e) : id; });
      }
    }
    if (Array.isArray(m.replies)) { for (const rep of m.replies) { replyCount++; enrich(rep); } }
  }
  for (const m of messages) enrich(m);

  report.setBaseCounts({ messages: messages.length, replies: replyCount, threads: parents.length, reactions: reactionCount });

  return {
    export: report.build(ctx.exportedAt),
    workspace: ctx.workspace,
    channel: ctx.channel,
    users,
    messages,
  };
}
```

Add `runExport` to `module.exports`.

- [ ] **Step 4: Run to verify pass**

Run: `node --test`
Expected: PASS (all tests across the file).

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: export-core runExport orchestrator"
```

---

### Task 13: Builder copies export-core.js into the app dir

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (after the `preload.js` heredoc ends, near other file generation; before the app launch).

**Interfaces:**
- Produces: `$APP_DIR/export-core.js` present at runtime so `main.js`/`preload.js` can `require('./export-core.js')`.

- [ ] **Step 1: Add the copy step**

Locate the end of the `preload.js` heredoc (the `EOF` closing the `cat > preload.js` block). Immediately after it, add:

```bash
# ---------------------------------------------------------------------------
# Copy pure export-core module (unit-tested separately) into the app dir
# ---------------------------------------------------------------------------
if [[ -f "$SCRIPT_DIR/export-core.js" ]]; then
  cp "$SCRIPT_DIR/export-core.js" "$APP_DIR/export-core.js"
  echo "Copied export-core.js"
else
  echo "WARNING: export-core.js not found next to the script; export feature will not load." >&2
fi
```

- [ ] **Step 2: Verify the script still parses**

Run: `bash -n slack-autocomplete-electron-app.sh`
Expected: no output (exit 0).

- [ ] **Step 3: Verify the copy logic in isolation**

Run:
```bash
SCRIPT_DIR="$(pwd)" APP_DIR="$(mktemp -d)" bash -c 'cp "$SCRIPT_DIR/export-core.js" "$APP_DIR/export-core.js" && node --check "$APP_DIR/export-core.js" && echo COPY_OK'
```
Expected: `COPY_OK`.

- [ ] **Step 4: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "build: copy export-core.js into app dir"
```

---

### Task 14: main.js - menu item + streaming save IPC handlers

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (inside the `cat > main.js` heredoc, lines ~122-1113).

**Interfaces:**
- Consumes: `exportCore.sanitizeExportFilename`.
- Produces: IPC channels `slack-autocomplete:export-channel` (sent to renderer) and `slack-autocomplete:save-export:{begin,write,commit,abort}` (handled in main). Consumed by preload in Task 15.

- [ ] **Step 1: Require export-core in main.js**

Find in the main.js heredoc:
```js
const fs = require('fs');
const path = require('path');
```
Add immediately after:
```js
const exportCore = require('./export-core.js');
```

- [ ] **Step 2: Add the File menu item**

Find the File submenu block:
```js
        {
          label: 'Reset Window State',
          accelerator: 'CmdOrCtrl+Shift+R',
          click: () => resetWindowState()
        },
        { type: 'separator' },
        IS_MAC ? { role: 'close' } : { role: 'quit' }
```
Replace with (inserts the export item + a separator before the close/quit item):
```js
        {
          label: 'Reset Window State',
          accelerator: 'CmdOrCtrl+Shift+R',
          click: () => resetWindowState()
        },
        { type: 'separator' },
        {
          label: 'Export Channel as JSON...',
          accelerator: 'CmdOrCtrl+Shift+E',
          click: (_item, focusedWindow) => {
            const w = focusedWindow || BrowserWindow.getFocusedWindow();
            if (w) w.webContents.send('slack-autocomplete:export-channel');
          }
        },
        { type: 'separator' },
        IS_MAC ? { role: 'close' } : { role: 'quit' }
```

- [ ] **Step 3: Add the streaming save IPC handlers**

Find an existing top-level handler to anchor near, e.g.:
```js
ipcMain.handle('slack-autocomplete:open-external', async (_event, targetUrl) => {
```
Immediately BEFORE that line, insert:
```js
// --- Channel export: streaming save to a temp file, atomic rename on commit ---
const exportSaveSessions = new Map();
let exportSaveCounter = 0;

function isSlackSender(event) {
  try {
    const url = (event.senderFrame && event.senderFrame.url)
      || (event.sender && typeof event.sender.getURL === 'function' && event.sender.getURL())
      || '';
    return /^https:\/\/[a-z0-9.-]*\.slack\.com(\/|$)/i.test(url);
  } catch (e) { return false; }
}

ipcMain.handle('slack-autocomplete:save-export:begin', async (event, payload = {}) => {
  if (!isSlackSender(event)) throw new Error('export save rejected: untrusted sender');
  const safe = exportCore.sanitizeExportFilename(payload.suggestedName || 'slack-export.json');
  const win = BrowserWindow.fromWebContents(event.sender);
  const defaultPath = path.join(app.getPath('downloads'), safe);
  const res = await dialog.showSaveDialog(win, {
    defaultPath,
    filters: [{ name: 'JSON', extensions: ['json'] }]
  });
  if (res.canceled || !res.filePath) return { canceled: true };
  const finalPath = res.filePath;
  const tmpPath = finalPath + '.partial';
  const stream = fs.createWriteStream(tmpPath, { encoding: 'utf8' });
  const token = 'exp' + (++exportSaveCounter);
  exportSaveSessions.set(token, { stream, tmpPath, finalPath });
  return { ok: true, token };
});

ipcMain.handle('slack-autocomplete:save-export:write', async (event, payload = {}) => {
  if (!isSlackSender(event)) throw new Error('export save rejected: untrusted sender');
  const s = exportSaveSessions.get(payload.token);
  if (!s) throw new Error('unknown export token');
  await new Promise((resolve, reject) => {
    s.stream.write(payload.chunk, (err) => (err ? reject(err) : resolve()));
  });
  return { ok: true };
});

ipcMain.handle('slack-autocomplete:save-export:commit', async (event, payload = {}) => {
  if (!isSlackSender(event)) throw new Error('export save rejected: untrusted sender');
  const s = exportSaveSessions.get(payload.token);
  if (!s) throw new Error('unknown export token');
  await new Promise((resolve, reject) => s.stream.end((err) => (err ? reject(err) : resolve())));
  await fs.promises.rename(s.tmpPath, s.finalPath);
  exportSaveSessions.delete(payload.token);
  return { saved: true, path: s.finalPath };
});

ipcMain.handle('slack-autocomplete:save-export:abort', async (event, payload = {}) => {
  if (!isSlackSender(event)) throw new Error('export save rejected: untrusted sender');
  const s = exportSaveSessions.get(payload.token);
  if (!s) return { ok: true };
  try { await new Promise((resolve) => s.stream.end(() => resolve())); } catch (e) { /* ignore */ }
  try { await fs.promises.unlink(s.tmpPath); } catch (e) { /* ignore */ }
  exportSaveSessions.delete(payload.token);
  return { ok: true };
});

```

- [ ] **Step 4: Verify the script parses and the generated main.js is valid JS**

Run:
```bash
bash -n slack-autocomplete-electron-app.sh && echo BASH_OK
```
Expected: `BASH_OK`.

Then extract just the generated `main.js` and syntax-check it without a full build:
```bash
awk '/^cat > main\.js <<.EOF.$/{f=1;next} f&&/^EOF$/{f=0} f' slack-autocomplete-electron-app.sh > /tmp/main.gen.js && node --check /tmp/main.gen.js && echo MAIN_OK
```
Expected: `MAIN_OK`.

- [ ] **Step 5: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: main-process export menu item and streaming save IPC"
```

---

### Task 15: preload.js - config discovery, apiCall, overlay, trigger wiring

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (inside the `cat > preload.js` heredoc, lines ~1120-3023).

**Interfaces:**
- Consumes: all of `export-core`; IPC channels from Task 14.
- Produces: the renderer-side export pipeline (no new exports; wires `slack-autocomplete:export-channel`).

- [ ] **Step 1: Require export-core in preload.js**

Find near the top of the preload heredoc:
```js
  const { ipcRenderer } = require('electron');
```
Add immediately after:
```js
  const exportCore = require('./export-core.js');
```
(If that `require('electron')` line is inside a function/guard, place the `exportCore` require in the same scope so it is available to the export code added below.)

- [ ] **Step 2: Append the export pipeline at the end of the preload IIFE/body**

Find the end of the preload script body (just before the final `EOF` of the `cat > preload.js` heredoc, inside whatever top-level scope holds `ipcRenderer`). Insert:

```js
  // ===================== Channel JSON export (web API) =====================
  function exportSleep(ms, signal) {
    return new Promise((resolve, reject) => {
      if (signal && signal.aborted) { const e = new Error('aborted'); e.name = 'AbortError'; return reject(e); }
      const t = setTimeout(resolve, ms);
      if (signal) signal.addEventListener('abort', () => { clearTimeout(t); const e = new Error('aborted'); e.name = 'AbortError'; reject(e); }, { once: true });
    });
  }

  function exportTsStamp() {
    const d = new Date();
    const p = (n) => String(n).padStart(2, '0');
    return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '-' + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
  }

  function getExportConfig() {
    const ids = exportCore.parseClientUrl(window.location.pathname);
    if (!ids) throw new Error('Open a channel first (no channel in the URL).');
    const raw = window.localStorage.getItem('localConfig_v2');
    const token = exportCore.getTokenForTeam(raw, ids.teamId);
    const apiBase = exportCore.inferApiBase(raw, ids.teamId);
    if (!token || !apiBase) throw new Error('Could not find the Slack token/config in this workspace.');
    return { teamId: ids.teamId, channelId: ids.channelId, token, apiBase, localConfigRaw: raw };
  }

  function createApiCall(cfg, signal) {
    const lastAt = {};
    async function spaceFor(method) {
      const tier = exportCore.methodTier(method);
      const interval = exportCore.tierIntervalMs(method);
      const now = Date.now();
      const wait = Math.max(0, (lastAt[tier] || 0) + interval - now);
      if (wait) await exportSleep(wait, signal);
      lastAt[tier] = Date.now();
    }
    return async function apiCall(method, params) {
      let attempt = 0;
      for (;;) {
        if (signal && signal.aborted) { const e = new Error('aborted'); e.name = 'AbortError'; throw e; }
        await spaceFor(method);
        const fd = new FormData();
        fd.append('token', cfg.token);
        for (const k of Object.keys(params || {})) {
          const v = params[k];
          fd.append(k, typeof v === 'boolean' ? String(v) : v);
        }
        const url = cfg.apiBase + method + '?slack_route=' + encodeURIComponent(cfg.teamId);
        let resp;
        try {
          resp = await fetch(url, { method: 'POST', body: fd, credentials: 'include', signal });
        } catch (e) {
          if (signal && signal.aborted) throw e;
          attempt++;
          if (attempt > 5) throw e;
          await exportSleep(exportCore.backoffDelay(attempt), signal);
          continue;
        }
        if (resp.status === 429) { await exportSleep(exportCore.parseRetryAfter(resp.headers.get('retry-after')) * 1000, signal); continue; }
        if (resp.status >= 500) { attempt++; if (attempt > 5) throw new Error('Slack server error ' + resp.status); await exportSleep(exportCore.backoffDelay(attempt), signal); continue; }
        const json = await resp.json();
        if (json && json.ok === false && json.error === 'ratelimited') { await exportSleep(exportCore.parseRetryAfter(resp.headers.get('retry-after')) * 1000, signal); continue; }
        return json;
      }
    };
  }

  function createExportOverlay() {
    const root = document.createElement('div');
    root.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:rgba(0,0,0,0.55);display:flex;align-items:center;justify-content:center;font-family:-apple-system,Segoe UI,sans-serif;';
    const box = document.createElement('div');
    box.style.cssText = 'background:#1d1c1d;color:#fff;min-width:340px;max-width:80vw;padding:20px 22px;border-radius:10px;box-shadow:0 10px 40px rgba(0,0,0,0.5);';
    const title = document.createElement('div');
    title.textContent = 'Exporting channel...';
    title.style.cssText = 'font-weight:700;font-size:15px;margin-bottom:10px;';
    const phase = document.createElement('div');
    phase.style.cssText = 'font-size:13px;opacity:0.85;margin-bottom:10px;';
    const barWrap = document.createElement('div');
    barWrap.style.cssText = 'height:8px;background:#3a393a;border-radius:4px;overflow:hidden;margin-bottom:14px;';
    const bar = document.createElement('div');
    bar.style.cssText = 'height:100%;width:0;background:#36c5f0;transition:width 0.2s;';
    barWrap.appendChild(bar);
    const cancelBtn = document.createElement('button');
    cancelBtn.textContent = 'Cancel';
    cancelBtn.style.cssText = 'background:#444;color:#fff;border:0;border-radius:6px;padding:7px 14px;cursor:pointer;font-size:13px;';
    box.appendChild(title); box.appendChild(phase); box.appendChild(barWrap); box.appendChild(cancelBtn);
    root.appendChild(box);
    // modal: swallow clicks behind the overlay
    root.addEventListener('click', (e) => { if (e.target === root) e.stopPropagation(); }, true);
    document.body.appendChild(root);
    let cancelCb = null;
    cancelBtn.addEventListener('click', () => { cancelBtn.disabled = true; cancelBtn.textContent = 'Canceling...'; if (cancelCb) cancelCb(); });
    return {
      onCancel(cb) { cancelCb = cb; },
      setPhase(text) { phase.textContent = text; },
      setProgress(label, cur, total) {
        if (total && total > 0) { bar.style.width = Math.round((cur / total) * 100) + '%'; phase.textContent = label + ' ' + cur + ' / ' + total; }
        else { phase.textContent = label + ' ' + cur + '...'; }
      },
      done(text) { title.textContent = 'Export complete'; phase.textContent = text; bar.style.width = '100%'; cancelBtn.textContent = 'Close'; cancelBtn.disabled = false; cancelBtn.onclick = () => root.remove(); setTimeout(() => { if (root.parentNode) root.remove(); }, 6000); },
      fail(text) { title.textContent = 'Export failed'; phase.textContent = text; bar.style.background = '#e01e5a'; cancelBtn.textContent = 'Close'; cancelBtn.disabled = false; cancelBtn.onclick = () => root.remove(); },
      destroy() { if (root.parentNode) root.remove(); },
    };
  }

  function phaseLabel(p) {
    if (p === 'messages') return 'Fetching messages';
    if (p === 'threads') return 'Fetching threads';
    if (p === 'thread-page') return 'Fetching thread replies';
    if (p === 'reactions') return 'Resolving reaction authors';
    if (p === 'actors') return 'Resolving users';
    return p;
  }

  let exportInProgress = false;
  ipcRenderer.on('slack-autocomplete:export-channel', async () => {
    if (exportInProgress) return;
    exportInProgress = true;
    const overlay = createExportOverlay();
    const ac = new AbortController();
    overlay.onCancel(() => ac.abort());
    let saveToken = null;
    try {
      const cfg = getExportConfig();
      const apiCall = createApiCall(cfg, ac.signal);
      overlay.setPhase('Reading channel info...');
      let channel = { id: cfg.channelId, name: cfg.channelId };
      try {
        const info = await apiCall('conversations.info', { channel: cfg.channelId });
        if (info && info.ok && info.channel) channel = info.channel;
      } catch (e) { /* fall back to id */ }
      const workspace = exportCore.workspaceFromConfig(cfg.localConfigRaw, cfg.teamId);

      const suggested = 'slack-export-' + (channel.name || cfg.channelId) + '-' + exportTsStamp() + '.json';
      const begin = await ipcRenderer.invoke('slack-autocomplete:save-export:begin', { suggestedName: suggested });
      if (begin && begin.canceled) { overlay.destroy(); return; }
      saveToken = begin.token;

      const exportedAt = new Date().toISOString();
      const doc = await exportCore.runExport(apiCall, {
        channelId: cfg.channelId, channel, workspace, exportedAt
      }, {
        signal: ac.signal,
        onProgress: (p, cur, total) => overlay.setProgress(phaseLabel(p), cur, total),
      });

      overlay.setPhase('Saving file...');
      for (const chunk of exportCore.streamExportJson(doc)) {
        await ipcRenderer.invoke('slack-autocomplete:save-export:write', { token: saveToken, chunk });
      }
      const res = await ipcRenderer.invoke('slack-autocomplete:save-export:commit', { token: saveToken });
      overlay.done('Saved to ' + res.path + (doc.export.complete ? '' : ' (incomplete - see export.warnings)'));
    } catch (e) {
      if (saveToken) { try { await ipcRenderer.invoke('slack-autocomplete:save-export:abort', { token: saveToken }); } catch (e2) { /* ignore */ } }
      if (e && e.name === 'AbortError') overlay.done('Export canceled.');
      else overlay.fail(String((e && e.message) || e));
    } finally {
      exportInProgress = false;
    }
  });
  // =================== end channel JSON export ===================
```

- [ ] **Step 3: Verify the script parses and the generated preload.js is valid JS**

Run:
```bash
bash -n slack-autocomplete-electron-app.sh && echo BASH_OK
awk '/^cat > preload\.js <<.EOF.$/{f=1;next} f&&/^EOF$/{f=0} f' slack-autocomplete-electron-app.sh > /tmp/preload.gen.js && node --check /tmp/preload.gen.js && echo PRELOAD_OK
```
Expected: `BASH_OK` then `PRELOAD_OK`.

- [ ] **Step 4: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: renderer export pipeline (config, apiCall, overlay, save streaming)"
```

---

### Task 16: Build, end-to-end manual verification, final commit

**Files:** none (verification only).

- [ ] **Step 1: Run the full unit suite**

Run: `node --test`
Expected: PASS, all tests green.

- [ ] **Step 2: Build and launch the app**

Run: `bash slack-autocomplete-electron-app.sh`
Expected: builds (first run installs Electron, ~150MB) and launches. Confirm `$HOME/SlackAutocompleteElectron/export-core.js` exists.

- [ ] **Step 3: Manual verification against a real channel** (from the spec's verification plan)

Perform in the running app and check each:
1. Open a channel, File -> Export Channel as JSON. The save dialog appears BEFORE the long fetch; canceling it does nothing further.
2. Re-run and choose a path; the progress bar advances (messages -> threads -> reactions -> users); only a `<name>.partial` exists during the run; on success it becomes `<name>` atomically.
3. Open the JSON: `export.counts` is plausible for the channel; threaded messages have `replies` with no duplicated reply `ts`; reactions include `users` + `user_names`; `users` map covers all referenced ids.
4. On a channel with a high-count reaction, confirm it is either fully backfilled or flagged `users_truncated:true` with a matching `export.warnings` entry and `export.complete:false`.
5. A bot/app-authored message resolves to a `kind:"bot"` actor with a name and `actor_kind:"bot"`, not an unresolved user.
6. Cancel mid-export; confirm the `.partial` file is deleted and no final file remains.
7. On a large channel, the renderer does not freeze during save (streaming).

- [ ] **Step 4: Final commit (if any verification-driven tweaks were needed)**

```bash
git add -A
git commit -m "test: verify channel JSON export end-to-end"
```

(If no changes were needed, skip this commit.)

---

## Self-Review Notes

- **Spec coverage:** menu/trigger (T14), token+apiBase from localConfig (T1/T15), history cursor paging with hard-fail (T8), thread cursor+window paging with parent removal/dedupe (T9), reaction backfill (T10), actor model users+bots (T4/T11), completeness reporting (T5/T12), streaming save with temp+rename (T7/T14/T15), IPC sender validation + filename sanitization (T2/T14), progress overlay + cancel (T15), rate-limit + 429 (T6/T15). All spec sections map to a task.
- **No placeholders:** every code step contains full code; no "handle errors"/"similar to" stubs.
- **Type consistency:** `apiCall(method, params)`, `hooks={signal,onProgress}`, `refs={userIds,botIds,embeddedBotProfiles}`, report method names, and `ctx={channelId,channel,workspace,exportedAt}` are used identically across Tasks 8-15.
