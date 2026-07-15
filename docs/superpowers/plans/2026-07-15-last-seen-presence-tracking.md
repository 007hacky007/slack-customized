# Last Seen (Presence) Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record when each Slack user was last seen online by tapping the client's presence WebSocket, inject a user-defined watchlist into presence subscriptions, and surface it all in an in-app panel.

**Architecture:** A pure logic module (`last-seen-core.js`, unit-tested with `node --test`) holds all frame parsing, subscription merging, and state reduction. The preload injects a main-world `WebSocket` wrapper that taps `presence_change` events and rewrites outgoing `presence_sub` frames, bridging to the isolated world via `CustomEvent`. The main process owns persistence (`last-seen.json`, `last-seen-transitions.jsonl`) and the watchlist file, over the existing `slack-autocomplete:*` IPC pattern. A preload-rendered fixed panel (same technique as the downloads panel) shows the data.

**Tech Stack:** Electron (main + preload, `contextIsolation: true`), Node.js `node:test`, plain DOM. No new dependencies.

## Global Constraints

- All source lives inside heredocs in `slack-autocomplete-electron-app.sh`: `main.js` (`cat > main.js <<'EOF'` at line ~122), `preload.js` (`cat > preload.js <<'EOF'` at line ~1817). Pure modules are separate real files copied into the app dir by the build script (see `export-core.js` at line ~4936).
- Pure logic goes in `last-seen-core.js` (a real file), unit-tested in `test/last-seen-core.test.js`. Never put untested logic in the heredocs that could live in the core module.
- IPC channels are namespaced `slack-autocomplete:*`. Every `ipcMain.handle`/`.on` that a renderer can reach MUST guard with `if (!isSlackSender(event)) throw new Error('... rejected: untrusted sender');` (see line ~528).
- The tap is fail-open: any exception in wrapping/parsing/rewriting must fall back to Slack's original behavior; `send()` always transmits the original frame if the rewrite path throws. It must never break or delay Slack's own traffic.
- No Unicode dashes anywhere (hyphen-minus `-` only). No em/en dashes in code, comments, or docs.
- Storage files live under `app.getPath('userData')`. Writes to `last-seen.json` are debounced (2 s) and atomic (temp file + rename).
- Injected watchlist ids are capped at 100 in the merged `presence_sub` frame.
- Git identity for this public GitHub repo: `git config commit.gpgsign false`, `git config user.name "007hacky007"`, `git config user.email "007hacky007@users.noreply.github.com"`. Do this once before the first commit.
- Do not run the build script or repackage the `.app` as part of task steps; the build/deploy flow is manual (see project memory). Tasks end at "committed"; manual verification of the running app is called out explicitly where it applies.
- Spec: `docs/superpowers/specs/2026-07-15-last-seen-presence-tracking-design.md`.

---

## File Structure

- **Create `last-seen-core.js`** (repo root): pure functions - `mergePresenceSub`, `recordSubscription`, `applyPresenceEvent`, `parseWatchlist`, `formatTransitionLine`, `describeLastSeen`, `emptyStore`, `WATCHLIST_CAP`, `SUB_LOG_MAX`.
- **Create `test/last-seen-core.test.js`**: `node:test` suite for the above.
- **Modify `slack-autocomplete-electron-app.sh`**:
  - `main.js` heredoc: require `last-seen-core.js`; store module (load/save/apply, debounced atomic writes, transition-log append + rotation); watchlist file load/watch/broadcast; IPC handlers; `File > Last Seen` menu submenu; wire startup in `whenReady`, flush on `before-quit`.
  - `preload.js` heredoc: main-world tap injection; isolated-world bridge; viewer panel; export flow; menu-triggered IPC listeners; call new setup fns from `init()`.
  - Build tail: `cp` `last-seen-core.js` into `$APP_DIR` (next to the `export-core.js` copy at line ~4936).
- **Modify `README.md`**: one feature bullet.

---

### Task 1: Core module - watchlist parsing and empty store

**Files:**
- Create: `last-seen-core.js`
- Test: `test/last-seen-core.test.js`

**Interfaces:**
- Produces:
  - `WATCHLIST_CAP` (number, 100), `SUB_LOG_MAX` (number, 100)
  - `emptyStore()` -> `{ users: {}, subscriptionLog: [], pendingBaseline: [], lastSubscribedIds: [] }`
  - `parseWatchlist(raw)` -> `{ ok: boolean, users: string[], error: string|null }`. Accepts a JSON string or object. Valid Slack user ids match `/^[UW][A-Z0-9]{2,}$/`. Deduplicates, preserves order, drops invalid entries. On unparseable input returns `{ ok:false, users:[], error:<message> }`.

- [ ] **Step 1: Write the failing test**

Create `test/last-seen-core.test.js`:

```js
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test test/last-seen-core.test.js`
Expected: FAIL - `Cannot find module '../last-seen-core.js'`.

- [ ] **Step 3: Write minimal implementation**

Create `last-seen-core.js`:

```js
'use strict';

// Pure logic for last-seen presence tracking. No Electron, no fs, no DOM.
// Unit-tested in test/last-seen-core.test.js and copied into the app dir by
// the build script (like export-core.js).

const WATCHLIST_CAP = 100;   // max watchlist ids merged into a presence_sub frame
const SUB_LOG_MAX = 100;     // subscription-log ring buffer length

const USER_ID_RE = /^[UW][A-Z0-9]{2,}$/;

function emptyStore() {
  return { users: {}, subscriptionLog: [], pendingBaseline: [], lastSubscribedIds: [] };
}

function dedupeValidIds(list) {
  const out = [];
  const seen = new Set();
  if (!Array.isArray(list)) return out;
  for (const raw of list) {
    if (typeof raw !== 'string') continue;
    const id = raw.trim();
    if (!USER_ID_RE.test(id) || seen.has(id)) continue;
    seen.add(id);
    out.push(id);
  }
  return out;
}

function parseWatchlist(raw) {
  let obj = raw;
  if (typeof raw === 'string') {
    try { obj = JSON.parse(raw); }
    catch (e) { return { ok: false, users: [], error: String((e && e.message) || e) }; }
  }
  if (!obj || typeof obj !== 'object') {
    return { ok: false, users: [], error: 'watchlist is not an object' };
  }
  return { ok: true, users: dedupeValidIds(obj.users), error: null };
}

module.exports = {
  WATCHLIST_CAP,
  SUB_LOG_MAX,
  USER_ID_RE,
  emptyStore,
  dedupeValidIds,
  parseWatchlist
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test test/last-seen-core.test.js`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git config commit.gpgsign false
git config user.name "007hacky007"
git config user.email "007hacky007@users.noreply.github.com"
git add last-seen-core.js test/last-seen-core.test.js
git commit -m "feat: last-seen-core parseWatchlist and empty store"
```

---

### Task 2: Core module - merge watchlist into presence_sub frames

**Files:**
- Modify: `last-seen-core.js`
- Test: `test/last-seen-core.test.js`

**Interfaces:**
- Consumes: `WATCHLIST_CAP`, `dedupeValidIds` (Task 1).
- Produces:
  - `mergePresenceSub(frameString, watchlistIds)` -> `{ changed, frame, clientIds, injectedIds }`.
    - `frameString` is the raw string passed to `WebSocket.send`. If it does not parse as JSON, or is not an object with `type === 'presence_sub'`, returns `{ changed:false, frame:frameString, clientIds:null, injectedIds:null }` (pass-through).
    - Slack `presence_sub` frame shape: `{ "type":"presence_sub", "ids":[...] }`. `clientIds` = the frame's original ids (validated/deduped). `injectedIds` = watchlist ids not already in `clientIds`, capped at `WATCHLIST_CAP`. If `injectedIds` is empty, returns `changed:false` with the original frame string unchanged. Otherwise `frame` is the re-serialized JSON with `ids = clientIds concat injectedIds` and all other frame fields preserved.

- [ ] **Step 1: Write the failing test**

Append to `test/last-seen-core.test.js`:

```js
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test test/last-seen-core.test.js`
Expected: FAIL - `core.mergePresenceSub is not a function`.

- [ ] **Step 3: Write minimal implementation**

In `last-seen-core.js`, add before `module.exports`:

```js
function mergePresenceSub(frameString, watchlistIds) {
  const passthrough = { changed: false, frame: frameString, clientIds: null, injectedIds: null };
  if (typeof frameString !== 'string') return passthrough;
  let obj;
  try { obj = JSON.parse(frameString); }
  catch (e) { return passthrough; }
  if (!obj || typeof obj !== 'object' || obj.type !== 'presence_sub') return passthrough;

  const clientIds = dedupeValidIds(obj.ids);
  const clientSet = new Set(clientIds);
  const injectedIds = [];
  for (const id of dedupeValidIds(watchlistIds)) {
    if (clientSet.has(id)) continue;
    injectedIds.push(id);
    if (injectedIds.length >= WATCHLIST_CAP) break;
  }
  if (injectedIds.length === 0) {
    return { changed: false, frame: frameString, clientIds, injectedIds };
  }
  const merged = Object.assign({}, obj, { ids: clientIds.concat(injectedIds) });
  return { changed: true, frame: JSON.stringify(merged), clientIds, injectedIds };
}
```

Add `mergePresenceSub` to `module.exports`.

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test test/last-seen-core.test.js`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add last-seen-core.js test/last-seen-core.test.js
git commit -m "feat: last-seen-core mergePresenceSub watchlist injection"
```

---

### Task 3: Core module - subscription recording and baseline tracking

**Files:**
- Modify: `last-seen-core.js`
- Test: `test/last-seen-core.test.js`

**Interfaces:**
- Consumes: `SUB_LOG_MAX`, `dedupeValidIds`, `emptyStore` (Tasks 1-2).
- Produces:
  - `recordSubscription(store, clientIds, injectedIds, nowIso)` -> mutates and returns `store`. Computes `allIds = dedupe(clientIds concat injectedIds)`. Ids in `allIds` not in `store.lastSubscribedIds` are appended to `store.pendingBaseline` (deduped). Pushes `{ at:nowIso, clientIds:[...], injectedIds:[...] }` to `store.subscriptionLog`, trimming to the most recent `SUB_LOG_MAX`. Sets `store.lastSubscribedIds = allIds`. Ids that drop out of the subscription are removed from `store.pendingBaseline`.

- [ ] **Step 1: Write the failing test**

Append to `test/last-seen-core.test.js`:

```js
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test test/last-seen-core.test.js`
Expected: FAIL - `core.recordSubscription is not a function`.

- [ ] **Step 3: Write minimal implementation**

In `last-seen-core.js`, add before `module.exports`:

```js
function recordSubscription(store, clientIds, injectedIds, nowIso) {
  const cleanClient = dedupeValidIds(clientIds);
  const cleanInjected = dedupeValidIds(injectedIds);
  const allIds = dedupeValidIds(cleanClient.concat(cleanInjected));
  const prev = new Set(store.lastSubscribedIds || []);

  const pending = new Set(store.pendingBaseline || []);
  for (const id of allIds) {
    if (!prev.has(id)) pending.add(id);
  }
  // Drop pending-baseline ids that are no longer subscribed at all.
  const allSet = new Set(allIds);
  for (const id of Array.from(pending)) {
    if (!allSet.has(id)) pending.delete(id);
  }
  store.pendingBaseline = Array.from(pending);
  store.lastSubscribedIds = allIds;

  store.subscriptionLog.push({ at: nowIso, clientIds: cleanClient, injectedIds: cleanInjected });
  if (store.subscriptionLog.length > SUB_LOG_MAX) {
    store.subscriptionLog = store.subscriptionLog.slice(-SUB_LOG_MAX);
  }
  return store;
}
```

Add `recordSubscription` to `module.exports`.

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test test/last-seen-core.test.js`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add last-seen-core.js test/last-seen-core.test.js
git commit -m "feat: last-seen-core recordSubscription with baseline tracking"
```

---

### Task 4: Core module - apply presence events and format transitions

**Files:**
- Modify: `last-seen-core.js`
- Test: `test/last-seen-core.test.js`

**Interfaces:**
- Consumes: `USER_ID_RE`, `emptyStore`, `recordSubscription` (Tasks 1-3).
- Produces:
  - `applyPresenceEvent(store, event, nowIso)` -> `{ store, transitions }`. `event` is `{ ids: string[], presence: 'active'|'away' }` (a single `user` string is also accepted and normalized to a one-element `ids`). For each valid id: if `presence === 'active'` set `lastActiveAt = nowIso`; if `'away'` set `lastAwayAt = nowIso`; always set `lastPresence` and `lastEventAt = nowIso`, and `firstTrackedAt` if unset. A transition record `{ at:nowIso, user, presence, baseline }` is produced only when the presence value actually changed from the stored `lastPresence` (or the user is new), with `baseline:true` iff the id was in `store.pendingBaseline` (the id is then removed from `pendingBaseline`). Unchanged repeats update `lastEventAt` but produce no transition.
  - `formatTransitionLine(transition)` -> a JSON string (single line, no trailing newline) of `{ at, user, presence, baseline }`.
  - `describeLastSeen(entry)` -> `{ state, lastOnlineAt }` where `state` is `'online'` when `entry.lastPresence === 'active'` else `'offline'`, and `lastOnlineAt` is `entry.lastActiveAt || null`.

- [ ] **Step 1: Write the failing test**

Append to `test/last-seen-core.test.js`:

```js
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test test/last-seen-core.test.js`
Expected: FAIL - `core.applyPresenceEvent is not a function`.

- [ ] **Step 3: Write minimal implementation**

In `last-seen-core.js`, add before `module.exports`:

```js
function applyPresenceEvent(store, event, nowIso) {
  const transitions = [];
  if (!event || typeof event !== 'object') return { store, transitions };
  const presence = event.presence;
  if (presence !== 'active' && presence !== 'away') return { store, transitions };

  let ids = event.ids;
  if (!Array.isArray(ids)) ids = event.user ? [event.user] : [];
  const pending = new Set(store.pendingBaseline || []);

  for (const raw of ids) {
    if (typeof raw !== 'string' || !USER_ID_RE.test(raw)) continue;
    const id = raw;
    let entry = store.users[id];
    const isNew = !entry;
    if (isNew) {
      entry = { lastPresence: null, lastActiveAt: null, lastAwayAt: null,
                lastEventAt: null, firstTrackedAt: nowIso };
      store.users[id] = entry;
    }
    const changed = entry.lastPresence !== presence;
    if (presence === 'active') entry.lastActiveAt = nowIso;
    else entry.lastAwayAt = nowIso;
    entry.lastPresence = presence;
    entry.lastEventAt = nowIso;

    const wasPending = pending.has(id);
    if (wasPending) pending.delete(id);
    if (changed) {
      transitions.push({ at: nowIso, user: id, presence, baseline: !!wasPending });
    }
  }
  store.pendingBaseline = Array.from(pending);
  return { store, transitions };
}

function formatTransitionLine(t) {
  return JSON.stringify({ at: t.at, user: t.user, presence: t.presence, baseline: !!t.baseline });
}

function describeLastSeen(entry) {
  const state = entry && entry.lastPresence === 'active' ? 'online' : 'offline';
  return { state, lastOnlineAt: (entry && entry.lastActiveAt) || null };
}
```

Add `applyPresenceEvent`, `formatTransitionLine`, `describeLastSeen` to `module.exports`.

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test test/last-seen-core.test.js`
Expected: PASS (all tests, ~23 total).

- [ ] **Step 5: Commit**

```bash
git add last-seen-core.js test/last-seen-core.test.js
git commit -m "feat: last-seen-core applyPresenceEvent, transition formatting, describeLastSeen"
```

---

### Task 5: Build wiring - copy core module and require it

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (build tail near line ~4936; `main.js` requires near line ~139; `preload.js` requires near line ~1826)

**Interfaces:**
- Consumes: `last-seen-core.js` (Tasks 1-4).
- Produces: `lastSeenCore` in-scope in both `main.js` and `preload.js` heredocs; the file copied into `$APP_DIR` at build time.

- [ ] **Step 1: Add the copy step in the build tail**

Find (near line ~4936):

```bash
# Copy pure export-core module (unit-tested separately) into the app dir
```

and the block that copies `export-core.js`. Immediately after that block's closing `fi`, add:

```bash
# Copy pure last-seen-core module (unit-tested separately) into the app dir
if [[ -f "$SCRIPT_DIR/last-seen-core.js" ]]; then
  cp "$SCRIPT_DIR/last-seen-core.js" "$APP_DIR/last-seen-core.js"
  echo "Copied last-seen-core.js"
else
  echo "WARNING: last-seen-core.js not found next to the script; last-seen feature will not load." >&2
fi
```

- [ ] **Step 2: Require the module in main.js**

Find in the `main.js` heredoc (line ~139):

```js
const exportCore = require('./export-core.js');
```

Add directly below it:

```js
const lastSeenCore = require('./last-seen-core.js');
```

- [ ] **Step 3: Require the module in preload.js**

Find in the `preload.js` heredoc (line ~1826):

```js
  const exportCore = require('./export-core.js');
```

Add directly below it:

```js
  const lastSeenCore = require('./last-seen-core.js');
```

- [ ] **Step 4: Verify the script still parses**

Run: `bash -n slack-autocomplete-electron-app.sh`
Expected: no output (exit 0), meaning no shell syntax error.

- [ ] **Step 5: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "build: copy and require last-seen-core in main and preload"
```

---

### Task 6: Main process - store persistence and transition log

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (`main.js` heredoc; place after the `saveAppSettings`/`effectiveDownloadsDir` block near line ~487)

**Interfaces:**
- Consumes: `lastSeenCore` (Task 5), `app`, `fs`, `path` (already required in main.js).
- Produces (module-scope functions in main.js):
  - `loadLastSeenStore()` - reads `last-seen.json` into `lastSeenStore`, falling back to `lastSeenCore.emptyStore()` and backing up a corrupt file to `.bak`.
  - `scheduleLastSeenSave()` - debounced (2 s) atomic write of `lastSeenStore`.
  - `flushLastSeenStore()` - synchronous atomic write (for `before-quit`).
  - `appendTransitions(transitions)` - appends `formatTransitionLine` output (newline-terminated) to `last-seen-transitions.jsonl`, rotating to `.1` past 5 MB.
  - `lastSeenStorePath()`, `lastSeenTransitionsPath()`.

- [ ] **Step 1: Add the store module**

After the `function effectiveDownloadsDir() { ... }` block (line ~490), add:

```js
// --- Last-seen presence store (local only; never leaves the machine) ---
let lastSeenStore = lastSeenCore.emptyStore();
let lastSeenSaveTimer = null;
const LAST_SEEN_SAVE_DEBOUNCE_MS = 2000;
const LAST_SEEN_LOG_MAX_BYTES = 5 * 1024 * 1024;

function lastSeenStorePath() { return path.join(app.getPath('userData'), 'last-seen.json'); }
function lastSeenTransitionsPath() { return path.join(app.getPath('userData'), 'last-seen-transitions.jsonl'); }

function loadLastSeenStore() {
  try {
    const parsed = JSON.parse(fs.readFileSync(lastSeenStorePath(), 'utf8'));
    if (parsed && typeof parsed === 'object' && parsed.users) {
      lastSeenStore = Object.assign(lastSeenCore.emptyStore(), parsed);
    }
  } catch (err) {
    if (err && err.code !== 'ENOENT') {
      try { fs.copyFileSync(lastSeenStorePath(), lastSeenStorePath() + '.bak'); } catch (e) { /* ignore */ }
      console.warn('last-seen store unreadable; starting fresh', err);
    }
    lastSeenStore = lastSeenCore.emptyStore();
  }
}

function writeLastSeenStoreNow() {
  const tmp = lastSeenStorePath() + '.tmp';
  try {
    fs.writeFileSync(tmp, JSON.stringify(lastSeenStore));
    fs.renameSync(tmp, lastSeenStorePath());
  } catch (err) {
    console.warn('Failed to write last-seen store', err);
    try { fs.unlinkSync(tmp); } catch (e) { /* ignore */ }
  }
}

function scheduleLastSeenSave() {
  if (lastSeenSaveTimer) return;
  lastSeenSaveTimer = setTimeout(() => {
    lastSeenSaveTimer = null;
    writeLastSeenStoreNow();
  }, LAST_SEEN_SAVE_DEBOUNCE_MS);
}

function flushLastSeenStore() {
  if (lastSeenSaveTimer) { clearTimeout(lastSeenSaveTimer); lastSeenSaveTimer = null; }
  writeLastSeenStoreNow();
}

function rotateTransitionsIfNeeded() {
  try {
    const st = fs.statSync(lastSeenTransitionsPath());
    if (st.size > LAST_SEEN_LOG_MAX_BYTES) {
      fs.renameSync(lastSeenTransitionsPath(), lastSeenTransitionsPath() + '.1');
    }
  } catch (err) { /* ENOENT is fine */ }
}

function appendTransitions(transitions) {
  if (!transitions || !transitions.length) return;
  rotateTransitionsIfNeeded();
  const text = transitions.map((t) => lastSeenCore.formatTransitionLine(t)).join('\n') + '\n';
  try { fs.appendFileSync(lastSeenTransitionsPath(), text); }
  catch (err) { console.warn('Failed to append last-seen transitions', err); }
}
```

- [ ] **Step 2: Wire load on startup and flush on quit**

In `app.whenReady().then(() => {` (line ~1758), find `loadAppSettings();` and add below it:

```js
  loadLastSeenStore();
```

In `app.on('before-quit', () => {` (line ~1798), after `saveWindowStateNow();` add:

```js
  flushLastSeenStore();
```

- [ ] **Step 3: Verify the script parses**

Run: `bash -n slack-autocomplete-electron-app.sh`
Expected: exit 0, no output.

- [ ] **Step 4: Run the core tests (regression guard)**

Run: `node --test test/last-seen-core.test.js`
Expected: PASS (unchanged).

- [ ] **Step 5: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: main-process last-seen store persistence and transition log"
```

---

### Task 7: Main process - watchlist file load, watch, and broadcast

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (`main.js` heredoc, after the store module from Task 6)

**Interfaces:**
- Consumes: `lastSeenCore.parseWatchlist` (Task 1), store module (Task 6), `BrowserWindow`, `fs`, `path`, `app`.
- Produces:
  - `lastSeenWatchlistPath()`.
  - `ensureWatchlistFile()` - creates the file with instructions if missing.
  - `loadWatchlist()` - reads + parses the file into `lastSeenWatchlist` (a `string[]`); invalid content logs and yields `[]`.
  - `broadcastWatchlist()` - sends `slack-autocomplete:last-seen-watchlist` with the current ids to every non-pool window.
  - `watchWatchlistFile()` - `fs.watch` (debounced) plus reload; re-broadcasts on change.
  - Module var `lastSeenWatchlist` (array of ids).

- [ ] **Step 1: Add the watchlist module**

After the store module (end of Task 6 block), add:

```js
// --- Last-seen watchlist (hand-edited file; hot-reloaded) ---
let lastSeenWatchlist = [];
let watchlistWatcher = null;
let watchlistReloadTimer = null;

function lastSeenWatchlistPath() { return path.join(app.getPath('userData'), 'last-seen-watchlist.json'); }

const WATCHLIST_TEMPLATE = {
  instructions: [
    'Add Slack user ids (they look like U012ABC or W012ABC) to the "users" array below.',
    'These users are subscribed to for presence in addition to whoever your Slack UI already tracks,',
    'so their online/away changes are recorded even when they are not on screen.',
    'Find a user id from their profile (More > Copy member ID) or the Last Seen export.',
    'At most 100 ids are injected. Save the file; the app reloads it automatically.'
  ],
  users: []
};

function ensureWatchlistFile() {
  try {
    if (!fs.existsSync(lastSeenWatchlistPath())) {
      fs.writeFileSync(lastSeenWatchlistPath(), JSON.stringify(WATCHLIST_TEMPLATE, null, 2));
    }
  } catch (err) { console.warn('Failed to create watchlist file', err); }
}

function loadWatchlist() {
  let raw = null;
  try { raw = fs.readFileSync(lastSeenWatchlistPath(), 'utf8'); }
  catch (err) { lastSeenWatchlist = []; return; }
  const parsed = lastSeenCore.parseWatchlist(raw);
  if (!parsed.ok) console.warn('watchlist parse error:', parsed.error);
  lastSeenWatchlist = parsed.users;
}

function broadcastWatchlist() {
  for (const win of BrowserWindow.getAllWindows()) {
    if (!win || win.isDestroyed() || win.__sawPool) continue;
    try { win.webContents.send('slack-autocomplete:last-seen-watchlist', lastSeenWatchlist); }
    catch (err) { /* ignore */ }
  }
}

function watchWatchlistFile() {
  try {
    if (watchlistWatcher) watchlistWatcher.close();
    watchlistWatcher = fs.watch(lastSeenWatchlistPath(), () => {
      if (watchlistReloadTimer) clearTimeout(watchlistReloadTimer);
      watchlistReloadTimer = setTimeout(() => {
        watchlistReloadTimer = null;
        loadWatchlist();
        broadcastWatchlist();
      }, 300);
    });
  } catch (err) { console.warn('Failed to watch watchlist file', err); }
}
```

- [ ] **Step 2: Wire startup**

In `app.whenReady().then(() => {`, after the `loadLastSeenStore();` line added in Task 6, add:

```js
  ensureWatchlistFile();
  loadWatchlist();
  watchWatchlistFile();
```

- [ ] **Step 3: Verify the script parses**

Run: `bash -n slack-autocomplete-electron-app.sh`
Expected: exit 0, no output.

- [ ] **Step 4: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: main-process watchlist load, watch, and broadcast"
```

---

### Task 8: Main process - IPC handlers for tap events and data access

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (`main.js` heredoc, near the other `ipcMain.handle` calls, e.g. after the `open-import` handler at line ~1697)

**Interfaces:**
- Consumes: `lastSeenCore.applyPresenceEvent`/`recordSubscription` (Tasks 3-4), store + transition + watchlist modules (Tasks 6-7), `isSlackSender`, `ipcMain`, `shell`, `BrowserWindow`, `webContents`.
- Produces IPC endpoints:
  - `on('slack-autocomplete:last-seen:event', (event, payload))` - `payload` is `{ kind:'change'|'sub', ids?, presence?, clientIds?, injectedIds? }`. Applies to the store (stamping `new Date().toISOString()`), appends transitions, schedules a save. Guarded by `isSlackSender`.
  - `handle('slack-autocomplete:last-seen:snapshot')` -> `{ users, subscriptionLog, currentSubscription, watchlist }` for the panel/export.
  - `handle('slack-autocomplete:last-seen:recent-transitions', (event, { limit }))` -> array of the last `limit` (default 50) parsed transition-log lines, most recent first.
  - `handle('slack-autocomplete:last-seen:watchlist')` -> current `lastSeenWatchlist`.
  - `handle('slack-autocomplete:last-seen:open-file', (event, { which }))` -> opens `watchlist` | `transitions` | `store` in the OS default app via `shell.openPath` (creating the watchlist first).

- [ ] **Step 1: Add the handlers**

After the `slack-autocomplete:open-import` handler (ends line ~1697), add:

```js
// --- Last-seen presence IPC ---
let lastSeenCurrentSub = null; // { clientIds, injectedIds, at }

ipcMain.on('slack-autocomplete:last-seen:event', (event, payload = {}) => {
  if (!isSlackSender(event)) return;
  const now = new Date().toISOString();
  try {
    if (payload.kind === 'sub') {
      lastSeenCore.recordSubscription(lastSeenStore, payload.clientIds || [], payload.injectedIds || [], now);
      lastSeenCurrentSub = { clientIds: payload.clientIds || [], injectedIds: payload.injectedIds || [], at: now };
      scheduleLastSeenSave();
    } else if (payload.kind === 'change') {
      const res = lastSeenCore.applyPresenceEvent(
        lastSeenStore, { ids: payload.ids, user: payload.user, presence: payload.presence }, now);
      appendTransitions(res.transitions);
      scheduleLastSeenSave();
    }
  } catch (err) { console.warn('last-seen event error', err); }
});

ipcMain.handle('slack-autocomplete:last-seen:snapshot', (event) => {
  if (!isSlackSender(event)) throw new Error('last-seen rejected: untrusted sender');
  return {
    users: lastSeenStore.users,
    subscriptionLog: lastSeenStore.subscriptionLog,
    currentSubscription: lastSeenCurrentSub,
    watchlist: lastSeenWatchlist
  };
});

ipcMain.handle('slack-autocomplete:last-seen:recent-transitions', (event, payload = {}) => {
  if (!isSlackSender(event)) throw new Error('last-seen rejected: untrusted sender');
  const limit = Math.max(1, Math.min(500, Number(payload.limit) || 50));
  let text = '';
  try { text = fs.readFileSync(lastSeenTransitionsPath(), 'utf8'); }
  catch (err) { return []; }
  const lines = text.split('\n').filter((l) => l.trim());
  const out = [];
  for (let i = lines.length - 1; i >= 0 && out.length < limit; i--) {
    try { out.push(JSON.parse(lines[i])); } catch (e) { /* skip bad line */ }
  }
  return out;
});

ipcMain.handle('slack-autocomplete:last-seen:watchlist', (event) => {
  if (!isSlackSender(event)) throw new Error('last-seen rejected: untrusted sender');
  return lastSeenWatchlist;
});

ipcMain.handle('slack-autocomplete:last-seen:open-file', async (event, payload = {}) => {
  if (!isSlackSender(event)) throw new Error('last-seen rejected: untrusted sender');
  let target;
  if (payload.which === 'watchlist') { ensureWatchlistFile(); target = lastSeenWatchlistPath(); }
  else if (payload.which === 'transitions') target = lastSeenTransitionsPath();
  else target = lastSeenStorePath();
  const err = await shell.openPath(target);
  return { ok: !err, error: err || null };
});
```

- [ ] **Step 2: Verify the script parses**

Run: `bash -n slack-autocomplete-electron-app.sh`
Expected: exit 0, no output.

- [ ] **Step 3: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: main-process IPC for last-seen events, snapshot, transitions, files"
```

---

### Task 9: Main process - File > Last Seen menu submenu

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (`main.js` heredoc, File menu, after the `Channel Sections` submenu block ~line 662)

**Interfaces:**
- Consumes: `BrowserWindow`, `webContents.send` menu pattern (line ~648).
- Produces: menu items that send `slack-autocomplete:last-seen:show-panel`, `slack-autocomplete:last-seen:export`, and invoke `slack-autocomplete:last-seen:open-file` for the focused window.

- [ ] **Step 1: Add the submenu**

After the `Channel Sections` submenu object closes (the `]` and `}` after `Import Sections...`, line ~662, before the `{ type: 'separator' },` that precedes the close item), add a new submenu object:

```js
        {
          label: 'Last Seen',
          submenu: [
            {
              label: 'Show Last Seen Panel',
              click: (_item, focusedWindow) => {
                const w = focusedWindow || BrowserWindow.getFocusedWindow();
                if (w) w.webContents.send('slack-autocomplete:last-seen:show-panel');
              }
            },
            {
              label: 'Export Last Seen...',
              click: (_item, focusedWindow) => {
                const w = focusedWindow || BrowserWindow.getFocusedWindow();
                if (w) w.webContents.send('slack-autocomplete:last-seen:export');
              }
            },
            { type: 'separator' },
            {
              label: 'Open Watchlist',
              click: (_item, focusedWindow) => {
                const w = focusedWindow || BrowserWindow.getFocusedWindow();
                if (w) w.webContents.send('slack-autocomplete:last-seen:open', { which: 'watchlist' });
              }
            },
            {
              label: 'Open Transition Log',
              click: (_item, focusedWindow) => {
                const w = focusedWindow || BrowserWindow.getFocusedWindow();
                if (w) w.webContents.send('slack-autocomplete:last-seen:open', { which: 'transitions' });
              }
            }
          ]
        },
```

Note: "Open" items route through the preload (which invokes the guarded `open-file` IPC) so the sender check passes; the preload handler is added in Task 12.

- [ ] **Step 2: Verify the script parses**

Run: `bash -n slack-autocomplete-electron-app.sh`
Expected: exit 0, no output.

- [ ] **Step 3: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: File > Last Seen menu submenu"
```

---

### Task 10: Preload - main-world WebSocket tap injection

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (`preload.js` heredoc; add a setup function and call it from `init()` at line ~4003)

**Interfaces:**
- Consumes: nothing from other tasks at runtime (the injected script is self-contained; it does NOT import `lastSeenCore` because it runs in the page's main world where `require` is unavailable). The merge/parse logic is inlined into the injected source as a minimal duplicate, kept deliberately tiny.
- Produces:
  - `installPresenceTap()` in the preload: injects a `<script>` into the main world before Slack boots, wrapping `window.WebSocket`. Dispatches `document` `CustomEvent('slack-autocomplete:ls-out', { detail })` for outgoing subs and `('slack-autocomplete:ls-in', { detail })` for incoming changes. Listens for `('slack-autocomplete:ls-watchlist', { detail })` to update the injected id list and proactively re-subscribe.

The injected main-world source is a template string. Watchlist ids are pushed in via a `CustomEvent`, never string-baked, so no escaping issues.

- [ ] **Step 1: Add the injection function**

In the `preload.js` heredoc, before the `function init() {` block (line ~3985), add:

```js
  // ---------------- Last-seen presence tap (main-world WebSocket wrapper) ----------------
  // Injected into the page's main world BEFORE Slack boots so it can wrap
  // window.WebSocket. Fail-open everywhere: any error falls back to Slack's
  // original behavior and the original frame is always sent. Bridges to this
  // isolated world via CustomEvents on document.
  function installPresenceTap() {
    const source = '(' + function () {
      'use strict';
      try {
        var USER_ID_RE = /^[UW][A-Z0-9]{2,}$/;
        var CAP = 100;
        var watchlist = [];
        var lastClientIds = null;   // ids from the most recent client presence_sub
        var taps = [];              // instrumented sockets that have sent a sub

        function dedupeValid(list) {
          var out = [], seen = {};
          if (!list || !list.length) return out;
          for (var i = 0; i < list.length; i++) {
            var id = typeof list[i] === 'string' ? list[i] : '';
            if (!USER_ID_RE.test(id) || seen[id]) continue;
            seen[id] = 1; out.push(id);
          }
          return out;
        }

        function merge(clientIds) {
          var clientSet = {}; for (var i = 0; i < clientIds.length; i++) clientSet[clientIds[i]] = 1;
          var injected = [];
          for (var j = 0; j < watchlist.length && injected.length < CAP; j++) {
            if (!clientSet[watchlist[j]]) injected.push(watchlist[j]);
          }
          return { ids: clientIds.concat(injected), clientIds: clientIds, injectedIds: injected };
        }

        function emit(name, detail) {
          try { document.dispatchEvent(new CustomEvent(name, { detail: JSON.stringify(detail) })); }
          catch (e) { /* ignore */ }
        }

        var NativeWS = window.WebSocket;
        if (!NativeWS) return;

        function WrappedWS(url, protocols) {
          var ws = protocols === undefined ? new NativeWS(url) : new NativeWS(url, protocols);
          var isSlack = false;
          try { isSlack = /(^|\.)slack\.com$/.test(new URL(url).hostname); } catch (e) { isSlack = false; }
          if (!isSlack) return ws;

          ws.addEventListener('message', function (ev) {
            try {
              if (typeof ev.data !== 'string') return;
              var msg = JSON.parse(ev.data);
              if (msg && msg.type === 'presence_change') {
                emit('slack-autocomplete:ls-in', {
                  ids: Array.isArray(msg.users) ? msg.users : (msg.user ? [msg.user] : []),
                  presence: msg.presence
                });
              }
            } catch (e) { /* ignore */ }
          });

          var nativeSend = ws.send.bind(ws);
          ws.send = function (data) {
            try {
              if (typeof data === 'string' && data.indexOf('presence_sub') !== -1) {
                var frame = JSON.parse(data);
                if (frame && frame.type === 'presence_sub') {
                  var clientIds = dedupeValid(frame.ids);
                  lastClientIds = clientIds;
                  if (taps.indexOf(ws) === -1) taps.push(ws);
                  var m = merge(clientIds);
                  emit('slack-autocomplete:ls-out', { clientIds: m.clientIds, injectedIds: m.injectedIds });
                  if (m.injectedIds.length) {
                    frame.ids = m.ids;
                    return nativeSend(JSON.stringify(frame));
                  }
                }
              }
            } catch (e) { /* fall through to original send */ }
            return nativeSend(data);
          };
          return ws;
        }
        WrappedWS.prototype = NativeWS.prototype;
        ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (k) {
          try { WrappedWS[k] = NativeWS[k]; } catch (e) { /* ignore */ }
        });
        window.WebSocket = WrappedWS;

        // Watchlist updates from the isolated world. On change, proactively
        // re-subscribe on any open tapped socket so new ids take effect without
        // waiting for Slack's next presence_sub.
        document.addEventListener('slack-autocomplete:ls-watchlist', function (ev) {
          try {
            watchlist = dedupeValid(JSON.parse(ev.detail));
            if (lastClientIds) {
              var m = merge(lastClientIds);
              for (var i = 0; i < taps.length; i++) {
                var t = taps[i];
                if (t && t.readyState === 1) {
                  try {
                    t.send.__native ? t.send(JSON.stringify({ type: 'presence_sub', ids: m.ids }))
                                    : t.send(JSON.stringify({ type: 'presence_sub', ids: m.ids }));
                  } catch (e) { /* ignore */ }
                  emit('slack-autocomplete:ls-out', { clientIds: m.clientIds, injectedIds: m.injectedIds });
                }
              }
            }
          } catch (e) { /* ignore */ }
        });
      } catch (e) { /* fail open: leave native WebSocket untouched */ }
    }.toString() + ')();';

    try {
      const el = document.createElement('script');
      el.textContent = source;
      (document.head || document.documentElement).appendChild(el);
      el.parentNode.removeChild(el);
    } catch (err) { log('presence tap injection failed', err); }
  }
```

Note on the re-subscribe path: because `ws.send` is our wrapper, calling `t.send(...)` re-enters the wrapper and re-merges - which is correct and idempotent (merging an already-merged list is stable). The ternary above is redundant and simplified in the next step's review; keep the plain `t.send(JSON.stringify({ type: 'presence_sub', ids: m.ids }))`.

- [ ] **Step 2: Simplify the re-subscribe call**

Replace the ternary block inside the `ls-watchlist` listener:

```js
                  try {
                    t.send.__native ? t.send(JSON.stringify({ type: 'presence_sub', ids: m.ids }))
                                    : t.send(JSON.stringify({ type: 'presence_sub', ids: m.ids }));
                  } catch (e) { /* ignore */ }
```

with:

```js
                  try { t.send(JSON.stringify({ type: 'presence_sub', ids: m.clientIds })); }
                  catch (e) { /* ignore */ }
```

Rationale: send the client ids through the wrapper, which merges the current watchlist in. This keeps a single merge path and avoids double-injection.

- [ ] **Step 3: Call it from init(), as early as possible**

In `function init() {` (line ~3985), add `installPresenceTap();` as the FIRST line of the body (before `attachKeyListener();`), so the wrapper is installed before Slack opens its socket:

```js
  function init() {
    installPresenceTap();
    attachKeyListener();
```

- [ ] **Step 4: Verify the script parses**

Run: `bash -n slack-autocomplete-electron-app.sh`
Expected: exit 0, no output.

Then sanity-check the injected function body is valid JS by extracting nothing (it is inside a heredoc); rely on the app-run verification in Task 13.

- [ ] **Step 5: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: preload injects main-world WebSocket presence tap"
```

---

### Task 11: Preload - bridge tap events to main and relay watchlist

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (`preload.js` heredoc, after `installPresenceTap`; call from `init()`)

**Interfaces:**
- Consumes: `ipcRenderer`, the `CustomEvent`s from Task 10, `lastSeenCore` (available in the isolated world via `require`).
- Produces:
  - `installPresenceBridge()` - listens for `slack-autocomplete:ls-in` / `ls-out` document events and forwards them to main over `ipcRenderer.send('slack-autocomplete:last-seen:event', ...)`; receives `slack-autocomplete:last-seen-watchlist` from main and dispatches `slack-autocomplete:ls-watchlist` into the main world; fetches the initial watchlist on startup.

- [ ] **Step 1: Add the bridge function**

After `installPresenceTap` (before `function init()`), add:

```js
  // Bridge between the main-world tap (document CustomEvents) and the main
  // process (IPC). Also relays watchlist updates from main into the main world.
  function installPresenceBridge() {
    if (!ipcRenderer) return;

    function forward(kindEventName, kind) {
      document.addEventListener(kindEventName, (ev) => {
        let detail;
        try { detail = JSON.parse(ev.detail); } catch (e) { return; }
        const payload = Object.assign({ kind }, detail);
        try { ipcRenderer.send('slack-autocomplete:last-seen:event', payload); } catch (e) { /* ignore */ }
      });
    }
    forward('slack-autocomplete:ls-in', 'change');
    forward('slack-autocomplete:ls-out', 'sub');

    function pushWatchlist(ids) {
      try {
        document.dispatchEvent(new CustomEvent('slack-autocomplete:ls-watchlist', {
          detail: JSON.stringify(Array.isArray(ids) ? ids : [])
        }));
      } catch (e) { /* ignore */ }
    }
    ipcRenderer.on('slack-autocomplete:last-seen-watchlist', (_event, ids) => pushWatchlist(ids));
    ipcRenderer.invoke('slack-autocomplete:last-seen:watchlist')
      .then((ids) => pushWatchlist(ids))
      .catch(() => {});
  }
```

- [ ] **Step 2: Call it from init() right after the tap**

In `init()`, add `installPresenceBridge();` immediately after `installPresenceTap();`:

```js
  function init() {
    installPresenceTap();
    installPresenceBridge();
    attachKeyListener();
```

- [ ] **Step 3: Verify the script parses**

Run: `bash -n slack-autocomplete-electron-app.sh`
Expected: exit 0, no output.

- [ ] **Step 4: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: preload bridges presence tap events and watchlist to main"
```

---

### Task 12: Preload - viewer panel, export, and open-file handlers

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (`preload.js` heredoc; add setup + menu listeners; call from `init()`)

**Interfaces:**
- Consumes: `ipcRenderer`, `lastSeenCore.describeLastSeen` (Task 4), the existing `getExportConfig`/`createApiCall`/`buildUserEntry` export helpers (lines ~4472, ~4498; note `buildUserEntry` lives in `exportCore`), the save-export IPC flow (`save-export:begin/write/commit/abort`, line ~1620), and `createExportOverlay` (line ~4546).
- Produces:
  - `setupLastSeenPanel()` - builds a fixed panel (downloads-panel style), fetches `last-seen:snapshot` + `last-seen:recent-transitions`, resolves names via `users.info` (cached), renders warning banner + tracked users + live subscription (client vs injected) + recent transitions. Toggle on `slack-autocomplete:last-seen:show-panel`.
  - `runLastSeenExport()` - resolves names and saves an enriched JSON via the save dialog, on `slack-autocomplete:last-seen:export`.
  - open-file relay on `slack-autocomplete:last-seen:open`.

- [ ] **Step 1: Add a shared name-resolver helper**

Before `function init()`, add a small cached resolver that reuses the export API bridge:

```js
  // Resolve user ids to display names via the existing rate-limited api-call
  // bridge, cached for the window's lifetime. Used by the Last Seen panel/export.
  const lastSeenNameCache = {};
  async function resolveUserNames(ids) {
    const missing = ids.filter((id) => !(id in lastSeenNameCache));
    if (missing.length) {
      let cfg;
      try { cfg = getExportConfig(function () {}, { requireChannel: false }); }
      catch (e) { for (const id of missing) lastSeenNameCache[id] = id; return lastSeenNameCache; }
      const apiCall = createApiCall(cfg, null, function () {});
      for (const id of missing) {
        try {
          const resp = await apiCall('users.info', { user: id });
          if (resp && resp.ok && resp.user) {
            const e = exportCore.buildUserEntry(resp.user);
            lastSeenNameCache[id] = e.name || id;
          } else { lastSeenNameCache[id] = id; }
        } catch (e) { lastSeenNameCache[id] = id; }
      }
    }
    return lastSeenNameCache;
  }
```

Note: confirm `buildUserEntry` is exported by `export-core.js`. If it is not exported, add it to that module's `module.exports` in this step and note it; it is used at `export-core.js:102`.

- [ ] **Step 2: Verify buildUserEntry is exported**

Run: `node -e "console.log(typeof require('./export-core.js').buildUserEntry)"`
Expected: `function`. If it prints `undefined`, add `buildUserEntry` to the `module.exports` object in `export-core.js`, commit that one-line change with message `fix: export buildUserEntry for name resolution`, and re-run until it prints `function`.

- [ ] **Step 3: Add the panel, export, and menu listeners**

Before `function init()`, add:

```js
  // ---------------- Last Seen viewer panel ----------------
  function setupLastSeenPanel() {
    if (!ipcRenderer) return;
    let root = null, visible = false;

    function fmtTime(iso) {
      if (!iso) return '-';
      try { return new Date(iso).toLocaleString(); } catch (e) { return iso; }
    }

    function ensurePanel() {
      if (root) return;
      root = document.createElement('div');
      root.id = 'slack-autocomplete-last-seen-panel';
      root.style.cssText = 'position:fixed;top:44px;right:8px;width:380px;max-height:80vh;z-index:2147483000;'
        + 'background:#1d1c1d;color:#fff;border:1px solid #3a393a;border-radius:10px;'
        + 'box-shadow:0 10px 40px rgba(0,0,0,0.5);display:none;flex-direction:column;'
        + 'font-family:-apple-system,Segoe UI,sans-serif;overflow:hidden;';
      const header = document.createElement('div');
      header.style.cssText = 'display:flex;align-items:center;justify-content:space-between;padding:10px 12px;border-bottom:1px solid #3a393a;';
      const title = document.createElement('div');
      title.textContent = 'Last Seen';
      title.style.cssText = 'font-weight:700;font-size:14px;';
      const closeBtn = document.createElement('button');
      closeBtn.textContent = 'X';
      closeBtn.style.cssText = 'background:none;border:0;color:#9a9a9a;cursor:pointer;font-size:12px;';
      closeBtn.addEventListener('click', () => toggle(false));
      header.appendChild(title); header.appendChild(closeBtn);

      const warn = document.createElement('div');
      warn.style.cssText = 'padding:8px 12px;background:#3d2f00;color:#f5d16a;font-size:11px;line-height:1.4;border-bottom:1px solid #3a393a;';
      warn.textContent = 'Presence is derived from live events: Slack throttles them (up to ~1 min lag), '
        + 'there is no backfill (tracking starts when the app does), and an "away" reading right after '
        + 'tracking a user only means they were already away, not that they just went offline.';

      const body = document.createElement('div');
      body.id = 'slack-autocomplete-last-seen-body';
      body.style.cssText = 'overflow:auto;padding:8px 12px;font-size:12px;';

      root.appendChild(header); root.appendChild(warn); root.appendChild(body);
      (document.body || document.documentElement).appendChild(root);
    }

    function section(titleText) {
      const h = document.createElement('div');
      h.textContent = titleText;
      h.style.cssText = 'font-weight:700;margin:10px 0 4px;color:#cfcfcf;';
      return h;
    }

    async function render() {
      ensurePanel();
      const body = root.querySelector('#slack-autocomplete-last-seen-body');
      body.textContent = 'Loading...';
      let snap, recent;
      try {
        snap = await ipcRenderer.invoke('slack-autocomplete:last-seen:snapshot');
        recent = await ipcRenderer.invoke('slack-autocomplete:last-seen:recent-transitions', { limit: 30 });
      } catch (e) { body.textContent = 'Failed to load last-seen data.'; return; }

      const userIds = Object.keys(snap.users || {});
      const sub = snap.currentSubscription || { clientIds: [], injectedIds: [] };
      const allIds = Array.from(new Set(userIds
        .concat(sub.clientIds || []).concat(sub.injectedIds || [])
        .concat((recent || []).map((t) => t.user))));
      const names = await resolveUserNames(allIds);
      const nameOf = (id) => (names[id] || id);
      const watchSet = new Set(snap.watchlist || []);

      body.textContent = '';

      // Tracked users, most recently online first.
      body.appendChild(section('Tracked users (' + userIds.length + ')'));
      const rows = userIds.map((id) => {
        const d = lastSeenCore.describeLastSeen(snap.users[id]);
        return { id, d, entry: snap.users[id] };
      }).sort((a, b) => String(b.d.lastOnlineAt || '').localeCompare(String(a.d.lastOnlineAt || '')));
      if (!rows.length) { const p = document.createElement('div'); p.textContent = 'No presence recorded yet.'; body.appendChild(p); }
      for (const r of rows) {
        const line = document.createElement('div');
        line.style.cssText = 'padding:3px 0;border-bottom:1px solid #2a292a;';
        const online = r.d.state === 'online';
        const lastOnline = online ? 'online now' : fmtTime(r.d.lastOnlineAt);
        line.textContent = (online ? '● ' : '○ ') + nameOf(r.id)
          + (watchSet.has(r.id) ? '  [watch]' : '')
          + '  -  ' + lastOnline;
        line.style.color = online ? '#2bac76' : '#cccccc';
        body.appendChild(line);
      }

      // Live subscription view.
      body.appendChild(section('Currently subscribed'));
      const subBox = document.createElement('div');
      const cIds = (sub.clientIds || []).map(nameOf).join(', ') || '(none)';
      const iIds = (sub.injectedIds || []).map(nameOf).join(', ') || '(none)';
      subBox.innerHTML = '';
      const cLine = document.createElement('div'); cLine.textContent = 'By Slack client: ' + cIds;
      const iLine = document.createElement('div'); iLine.style.color = '#7aa7ff'; iLine.textContent = 'Injected from watchlist: ' + iIds;
      subBox.appendChild(cLine); subBox.appendChild(iLine);
      body.appendChild(subBox);

      // Recent transitions.
      body.appendChild(section('Recent transitions'));
      if (!recent || !recent.length) { const p = document.createElement('div'); p.textContent = '(none logged yet)'; body.appendChild(p); }
      for (const t of (recent || [])) {
        const line = document.createElement('div');
        line.style.cssText = 'padding:2px 0;color:#bdbdbd;';
        line.textContent = fmtTime(t.at) + '  ' + nameOf(t.user) + '  ' + t.presence + (t.baseline ? '  (baseline)' : '');
        body.appendChild(line);
      }
    }

    function toggle(show) {
      ensurePanel();
      visible = (show === undefined) ? !visible : show;
      root.style.display = visible ? 'flex' : 'none';
      if (visible) render();
    }

    ipcRenderer.on('slack-autocomplete:last-seen:show-panel', () => toggle());
  }

  // ---------------- Last Seen export ----------------
  async function runLastSeenExport() {
    const overlay = createExportOverlay('Exporting last-seen data...');
    const log = (msg) => { try { console.log('[last-seen]', msg); } catch (e) {} overlay.appendLog(msg); };
    let saveToken = null;
    try {
      overlay.setPhase('Reading data...');
      const snap = await ipcRenderer.invoke('slack-autocomplete:last-seen:snapshot');
      const userIds = Object.keys(snap.users || {});
      overlay.setPhase('Resolving names...');
      const names = await resolveUserNames(userIds);
      const users = {};
      for (const id of userIds) {
        users[id] = Object.assign({ id, name: names[id] || id }, snap.users[id]);
      }
      const doc = {
        format: 'slack-last-seen-export',
        version: 1,
        exportedAt: new Date().toISOString(),
        users,
        watchlist: snap.watchlist || [],
        currentSubscription: snap.currentSubscription || null
      };
      overlay.setPhase('Saving file...');
      const suggested = 'slack-last-seen-' + exportTsStamp() + '.json';
      const begin = await ipcRenderer.invoke('slack-autocomplete:save-export:begin', { suggestedName: suggested });
      if (begin && begin.canceled) { overlay.destroy(); return; }
      saveToken = begin.token;
      await ipcRenderer.invoke('slack-autocomplete:save-export:write', { token: saveToken, chunk: JSON.stringify(doc, null, 2) });
      const res = await ipcRenderer.invoke('slack-autocomplete:save-export:commit', { token: saveToken });
      overlay.done('Saved to ' + res.path);
    } catch (e) {
      if (saveToken) { try { await ipcRenderer.invoke('slack-autocomplete:save-export:abort', { token: saveToken }); } catch (e2) { /* ignore */ } }
      overlay.fail(String((e && e.message) || e));
    }
  }

  function setupLastSeenMenuActions() {
    if (!ipcRenderer) return;
    ipcRenderer.on('slack-autocomplete:last-seen:export', () => { runLastSeenExport(); });
    ipcRenderer.on('slack-autocomplete:last-seen:open', (_event, payload) => {
      ipcRenderer.invoke('slack-autocomplete:last-seen:open-file', { which: (payload && payload.which) || 'store' }).catch(() => {});
    });
  }
```

- [ ] **Step 4: Call the setup functions from init()**

In `init()`, near the other setup calls (after `setupDownloadsPanel();`, line ~4004), add:

```js
    setupLastSeenPanel();
    setupLastSeenMenuActions();
```

- [ ] **Step 5: Verify the script parses**

Run: `bash -n slack-autocomplete-electron-app.sh`
Expected: exit 0, no output.

- [ ] **Step 6: Commit**

```bash
git add slack-autocomplete-electron-app.sh export-core.js
git commit -m "feat: Last Seen viewer panel, export, and menu actions in preload"
```

---

### Task 13: Manual end-to-end verification

**Files:** none (verification only).

This task has no automated tests because it exercises Electron, the live Slack web client, and the injected main-world tap, none of which run under `node --test`. Follow the project build/deploy flow (see memory: source is in the `.sh`, the live app is the `/Applications` copy).

- [ ] **Step 1: Build the app**

Run: `./slack-autocomplete-electron-app.sh`
Expected: ends with `Done.` and prints the `.app` path. Confirm the log contains `Copied last-seen-core.js`.

- [ ] **Step 2: Launch and open DevTools console**

Run: `open "$HOME/SlackAutocompleteElectron/dist/SlackAutocompleteElectron-darwin-arm64/SlackAutocompleteElectron.app"`
Sign in if needed. Open a channel. In the renderer console, confirm no errors mention `presence tap injection failed`.

- [ ] **Step 3: Verify passive capture**

Set `localStorage.setItem('slackAutocompleteDebug','1')` and reload. Open a few DMs/channels so Slack subscribes to presence. Then run menu `File > Last Seen > Show Last Seen Panel`.
Expected: the panel shows the warning banner, a "Currently subscribed" list with names under "By Slack client", and tracked users appearing as their presence arrives.

- [ ] **Step 4: Verify watchlist injection**

Run menu `File > Last Seen > Open Watchlist`, add a user id who is NOT in your sidebar (e.g. a colleague found via Copy member ID), save. Reopen the panel.
Expected: that id appears under "Injected from watchlist" in "Currently subscribed", and a `presence_change` for them lands in tracked users / recent transitions within a minute.

- [ ] **Step 5: Verify export and files**

Run `File > Last Seen > Export Last Seen...`, save the JSON, open it - confirm `users` have resolved names and timestamps. Run `Open Transition Log` - confirm JSONL lines with `at`, `user`, `presence`, `baseline`.

- [ ] **Step 6: Verify official-behavior parity (fail-open)**

Confirm Slack itself behaves normally: presence dots, messaging, huddles unaffected. Temporarily rename `last-seen-core.js` away and rebuild to confirm the app still launches (the tap simply does nothing) - then restore it. This confirms fail-open.

- [ ] **Step 7: Record the verification result**

No commit. Note in the PR/hand-off which steps passed and any Slack UI dependency observed (frame shapes). If `presence_sub`/`presence_change` shapes differ from the assumptions in Tasks 4/10, open a follow-up before merging.

---

### Task 14: Documentation

**Files:**
- Modify: `README.md` (feature list, ~line 27)

- [ ] **Step 1: Add a README bullet**

In `README.md`, in the "What it adds on top of official Slack" list (after the Channel sections bullet, line ~27), add:

```markdown
- Last seen (presence) tracking: records when tracked users were last online by
  tapping the client's presence WebSocket, injects a hand-edited watchlist of extra
  user ids into presence subscriptions, and shows current subscriptions, per-user
  last-online, and a transition log in a "Last Seen" panel (File menu). Presence is
  derived from live events only (throttled, no backfill); the data stays local.
```

- [ ] **Step 2: Verify no Unicode dashes were introduced**

Run: `rg -n $'[‐-―]' README.md last-seen-core.js || echo "clean"`
Expected: `clean`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README entry for last-seen presence tracking"
```

---

## Self-Review

**Spec coverage:**
- Background / subscription model -> informs Tasks 2, 3, 10 (merge + record + tap). Covered.
- Passive tap plus watchlist injection -> Tasks 10, 11 (tap + bridge), Task 2 (merge). Covered.
- Main-world WebSocket wrapper, injected before Slack boots, fail-open -> Task 10 (injected first in `init()`, try/catch throughout, original frame always sent). Covered.
- Section 1b coexistence with Slack overrides -> Task 10 (rewrite at `send()` boundary catches every frame; proactive re-subscribe on watchlist change). Covered.
- Store `last-seen.json` with the documented per-user fields + subscriptionLog ring buffer -> Tasks 3, 4, 6. Covered.
- Transition log JSONL with baseline flag + rotation -> Tasks 4, 6, 8. Covered.
- Watchlist file, hot-reload, cap 100, instructions, invalid -> empty -> Tasks 1, 2, 7. Covered.
- Viewer panel: warning banner, tracked users, live subscription (client vs injected, names), recent transitions -> Task 12. Covered.
- Menu: Show Panel, Export, Open Watchlist, Open Transition Log -> Tasks 9, 12. Covered.
- Names resolved in viewer and on export via existing api-call bridge, cached -> Task 12. Covered.
- Error handling: fail-open tap, silent-off on injection failure (logged), corrupt store -> fresh + `.bak` -> Tasks 6, 10. Covered.
- Testing: `last-seen-core.js` pure functions with `node --test`; manual verification -> Tasks 1-4 (tests), Task 13 (manual). Covered.

**Placeholder scan:** No TBD/TODO; every code step has complete code. Task 12 Step 2 guards the one external assumption (`buildUserEntry` export) with a concrete check-and-fix.

**Type consistency:** `mergePresenceSub` returns `{changed, frame, clientIds, injectedIds}` used consistently. `applyPresenceEvent` returns `{store, transitions}` used in Task 8. `recordSubscription` mutates the store used in Task 8. IPC channel names match between main (Tasks 8, 9) and preload (Tasks 11, 12): `last-seen:event`, `:snapshot`, `:recent-transitions`, `:watchlist`, `:open-file`, `:show-panel`, `:export`, `:open`, and `last-seen-watchlist` (broadcast). `describeLastSeen` shape `{state, lastOnlineAt}` used in Task 12.
