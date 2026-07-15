# Last Seen Interactive Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the raw-file "Open Watchlist" / "Open Transition Log" menu actions with in-panel UI: a name-search watchlist editor and a transition log with resolved usernames.

**Architecture:** Pure logic (watchlist mutation, roster search filter) goes in `last-seen-core.js` with `node --test` coverage. The main process gains a `watchlist-update` IPC that rewrites `last-seen-watchlist.json` atomically and broadcasts; the `open-file` IPC is removed. The preload's Last Seen panel gains a Watchlist section (search over a once-per-window `users.list` roster) and a fuller Transition log section; menu items open the panel scrolled to a section.

**Tech Stack:** Electron (main + preload), Node.js `node:test`, plain DOM. No new dependencies.

## Global Constraints

- All source lives inside heredocs in `slack-autocomplete-electron-app.sh` (`main.js` and `preload.js`). Pure modules are real files copied into the app dir by the build tail. Line numbers below are as of commit 098e599 and may shift; anchor on the quoted code, not the numbers.
- Every renderer-reachable `ipcMain.handle`/`.on` MUST guard with `isSlackSender(event)`.
- No Unicode dashes anywhere (hyphen-minus `-` only).
- Watchlist file writes are atomic (temp file + rename) and preserve the template's `instructions` block; the file stays hand-editable and fs.watch hot-reload keeps working.
- Injected watchlist cap stays 100 (`WATCHLIST_CAP`); the editor may store more, the merge caps.
- Git identity for this repo is already configured (007hacky007). Never use the real name/email here.
- Build/deploy (`./slack-autocomplete-electron-app.sh`, then replace `/Applications/SlackAutocompleteElectron.app`) happens only in the final verification task, which the user has been approving per-run this session.
- Spec: `docs/superpowers/specs/2026-07-15-last-seen-interactive-panel-design.md`.

---

## File Structure

- **Modify `last-seen-core.js`**: add `applyWatchlistUpdate`, `filterRoster`.
- **Modify `test/last-seen-core.test.js`**: tests for both.
- **Modify `slack-autocomplete-electron-app.sh`**:
  - `main.js` heredoc: `writeWatchlistFile`, `watchlist-update` IPC, remove `open-file` IPC, retarget two menu items.
  - `preload.js` heredoc: roster fetch helper, rebuilt `setupLastSeenPanel`, trimmed `setupLastSeenMenuActions`.
- **Modify `README.md`**: extend the Last Seen bullet.

---

### Task 1: Core module - applyWatchlistUpdate

**Files:**
- Modify: `last-seen-core.js`
- Test: `test/last-seen-core.test.js`

**Interfaces:**
- Consumes: `USER_ID_RE`, `dedupeValidIds` (already in the module).
- Produces: `applyWatchlistUpdate(users, change)` -> `{ users: string[], changed: boolean }`. `change` is `{ add?: string, remove?: string }` (add wins if both). Invalid ids, duplicate adds, and missing remove targets are safe no-ops (`changed:false`). The input array is not mutated.

- [ ] **Step 1: Write the failing test**

Append to `test/last-seen-core.test.js`:

```js
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test test/last-seen-core.test.js`
Expected: FAIL - `core.applyWatchlistUpdate is not a function`.

- [ ] **Step 3: Write minimal implementation**

In `last-seen-core.js`, add before `module.exports`:

```js
function applyWatchlistUpdate(users, change) {
  const current = dedupeValidIds(users);
  if (!change || typeof change !== 'object') return { users: current, changed: false };
  if (typeof change.add === 'string') {
    const id = change.add.trim();
    if (USER_ID_RE.test(id) && current.indexOf(id) === -1) {
      return { users: current.concat([id]), changed: true };
    }
    return { users: current, changed: false };
  }
  if (typeof change.remove === 'string') {
    const id = change.remove.trim();
    const next = current.filter((u) => u !== id);
    return { users: next, changed: next.length !== current.length };
  }
  return { users: current, changed: false };
}
```

Add `applyWatchlistUpdate` to `module.exports`.

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test test/last-seen-core.test.js`
Expected: PASS (30 tests).

- [ ] **Step 5: Commit**

```bash
git add last-seen-core.js test/last-seen-core.test.js
git commit -m "feat: last-seen-core applyWatchlistUpdate"
```

---

### Task 2: Core module - filterRoster

**Files:**
- Modify: `last-seen-core.js`
- Test: `test/last-seen-core.test.js`

**Interfaces:**
- Produces: `filterRoster(roster, query, max)` -> array of roster entries. Roster entries are objects shaped like `exportCore.buildUserEntry` output: `{ id, name, real_name, display_name, ... }`. Case-insensitive substring match on `name`, `real_name`, and `display_name`. Queries shorter than 2 chars (after trim) return `[]`. `max` defaults to 10. Order of the input is preserved.

- [ ] **Step 1: Write the failing test**

Append to `test/last-seen-core.test.js`:

```js
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test test/last-seen-core.test.js`
Expected: FAIL - `core.filterRoster is not a function`.

- [ ] **Step 3: Write minimal implementation**

In `last-seen-core.js`, add before `module.exports`:

```js
function filterRoster(roster, query, max) {
  const q = String(query || '').trim().toLowerCase();
  const limit = max || 10;
  const out = [];
  if (!Array.isArray(roster) || q.length < 2) return out;
  for (const e of roster) {
    if (!e || typeof e !== 'object') continue;
    const fields = [e.name, e.real_name, e.display_name];
    for (const f of fields) {
      if (typeof f === 'string' && f.toLowerCase().indexOf(q) !== -1) {
        out.push(e);
        break;
      }
    }
    if (out.length >= limit) break;
  }
  return out;
}
```

Add `filterRoster` to `module.exports`.

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test test/last-seen-core.test.js`
Expected: PASS (34 tests).

- [ ] **Step 5: Commit**

```bash
git add last-seen-core.js test/last-seen-core.test.js
git commit -m "feat: last-seen-core filterRoster name search"
```

---

### Task 3: Main process - watchlist-update IPC, remove open-file

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (`main.js` heredoc)

**Interfaces:**
- Consumes: `lastSeenCore.applyWatchlistUpdate` (Task 1), existing `lastSeenWatchlist`, `WATCHLIST_TEMPLATE`, `lastSeenWatchlistPath()`, `broadcastWatchlist()`, `isSlackSender`.
- Produces: `handle('slack-autocomplete:last-seen:watchlist-update', (event, { add?, remove? }))` -> `{ ok, users, error? }`. Removes `handle('slack-autocomplete:last-seen:open-file', ...)` entirely.

- [ ] **Step 1: Add writeWatchlistFile next to the watchlist module**

In the `main.js` heredoc, find `function watchWatchlistFile() {` (line ~602) and add BEFORE it:

```js
function writeWatchlistFile(users) {
  const doc = { instructions: WATCHLIST_TEMPLATE.instructions, users };
  const tmp = lastSeenWatchlistPath() + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(doc, null, 2));
  fs.renameSync(tmp, lastSeenWatchlistPath());
}
```

- [ ] **Step 2: Replace the open-file handler with watchlist-update**

Find the whole block (line ~1905):

```js
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

Replace it with:

```js
ipcMain.handle('slack-autocomplete:last-seen:watchlist-update', (event, payload = {}) => {
  if (!isSlackSender(event)) throw new Error('last-seen rejected: untrusted sender');
  const res = lastSeenCore.applyWatchlistUpdate(lastSeenWatchlist, {
    add: typeof payload.add === 'string' ? payload.add : undefined,
    remove: typeof payload.remove === 'string' ? payload.remove : undefined
  });
  if (!res.changed) return { ok: true, users: lastSeenWatchlist };
  try {
    writeWatchlistFile(res.users);
  } catch (err) {
    return { ok: false, users: lastSeenWatchlist, error: String((err && err.message) || err) };
  }
  lastSeenWatchlist = res.users;
  broadcastWatchlist();
  return { ok: true, users: lastSeenWatchlist };
});
```

Note: the file write also triggers fs.watch, whose debounced reload re-parses the same content and re-broadcasts; that is idempotent and harmless.

- [ ] **Step 3: Check shell is still used elsewhere in main.js**

Run: `grep -c "shell\." slack-autocomplete-electron-app.sh`
Expected: count > 0 (the downloads panel uses `shell.showItemInFolder` etc.). Do NOT remove the `shell` import. If the count is 0, something unrelated broke; stop and investigate.

- [ ] **Step 4: Verify the script parses**

Run: `bash -n slack-autocomplete-electron-app.sh`
Expected: exit 0, no output.

- [ ] **Step 5: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: watchlist-update IPC replaces open-file in main"
```

---

### Task 4: Main process - retarget menu items to panel sections

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (`main.js` heredoc, File > Last Seen submenu, line ~800)

**Interfaces:**
- Produces: `Open Watchlist` / `Open Transition Log` send `slack-autocomplete:last-seen:show-panel` with `{ section: 'watchlist' }` / `{ section: 'transitions' }`. The preload handler for the payload is added in Task 6.

- [ ] **Step 1: Replace the two menu items**

Find (line ~802):

```js
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
```

Replace with:

```js
            {
              label: 'Open Watchlist',
              click: (_item, focusedWindow) => {
                const w = focusedWindow || BrowserWindow.getFocusedWindow();
                if (w) w.webContents.send('slack-autocomplete:last-seen:show-panel', { section: 'watchlist' });
              }
            },
            {
              label: 'Open Transition Log',
              click: (_item, focusedWindow) => {
                const w = focusedWindow || BrowserWindow.getFocusedWindow();
                if (w) w.webContents.send('slack-autocomplete:last-seen:show-panel', { section: 'transitions' });
              }
            }
```

- [ ] **Step 2: Verify no sender of last-seen:open remains in main.js**

Run: `grep -n "last-seen:open" slack-autocomplete-electron-app.sh`
Expected: only the preload's listener line (removed in Task 6) or nothing from main.js menu code. `last-seen:open-file` must not appear at all (removed in Task 3).

- [ ] **Step 3: Verify the script parses**

Run: `bash -n slack-autocomplete-electron-app.sh`
Expected: exit 0, no output.

- [ ] **Step 4: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: Last Seen menu opens panel sections instead of raw files"
```

---

### Task 5: Preload - workspace roster fetch helper

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (`preload.js` heredoc, directly after the `resolveUserNames` function, line ~4380)

**Interfaces:**
- Consumes: `getExportConfig(log, { requireChannel: false })`, `createApiCall(cfg, null, log)`, `exportCore.buildUserEntry(user)` -> `{ id, kind, is_bot, name, real_name, display_name }`, `lastSeenNameCache`.
- Produces: `fetchLastSeenRoster()` -> Promise resolving to an array of buildUserEntry objects (deleted users, bots, and USLACKBOT excluded), cached for the window's lifetime; concurrent callers share one in-flight fetch; a failed fetch clears the in-flight promise so a later attempt can retry. Also pre-fills `lastSeenNameCache`.

- [ ] **Step 1: Add the roster fetcher**

Directly after the closing brace of `resolveUserNames` (before `// ---------------- Last Seen viewer panel ----------------`), add:

```js
  // Workspace roster for watchlist name search. Fetched once per window via
  // the rate-limited api-call bridge; also pre-fills the name cache.
  let lastSeenRoster = null;
  let lastSeenRosterPromise = null;
  function fetchLastSeenRoster() {
    if (lastSeenRoster) return Promise.resolve(lastSeenRoster);
    if (!lastSeenRosterPromise) {
      lastSeenRosterPromise = (async () => {
        const cfg = getExportConfig(function () {}, { requireChannel: false });
        const apiCall = createApiCall(cfg, null, function () {});
        const out = [];
        let cursor;
        for (let page = 0; page < 25; page++) {
          const params = { limit: 200 };
          if (cursor) params.cursor = cursor;
          const resp = await apiCall('users.list', params);
          if (!resp || !resp.ok) throw new Error('users.list failed: ' + ((resp && resp.error) || 'unknown'));
          for (const u of (resp.members || [])) {
            if (!u || u.deleted || u.is_bot || u.id === 'USLACKBOT') continue;
            const e = exportCore.buildUserEntry(u);
            out.push(e);
            lastSeenNameCache[e.id] = e.name || e.id;
          }
          cursor = resp.response_metadata && resp.response_metadata.next_cursor;
          if (!cursor) break;
        }
        lastSeenRoster = out;
        return out;
      })();
      lastSeenRosterPromise.catch(() => { lastSeenRosterPromise = null; });
    }
    return lastSeenRosterPromise;
  }
```

- [ ] **Step 2: Verify the script parses**

Run: `bash -n slack-autocomplete-electron-app.sh`
Expected: exit 0, no output.

- [ ] **Step 3: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: preload workspace roster fetch for watchlist search"
```

---

### Task 6: Preload - panel rework (watchlist editor, named transition log, section scroll)

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (`preload.js` heredoc: replace `setupLastSeenPanel` wholesale, trim `setupLastSeenMenuActions`)

**Interfaces:**
- Consumes: `fetchLastSeenRoster` (Task 5), `lastSeenCore.filterRoster`/`applyWatchlistUpdate` semantics via IPC (Tasks 1-3), `lastSeenCore.describeLastSeen`, `lastSeenCore.USER_ID_RE`, `resolveUserNames`, `ipcRenderer`, IPC `slack-autocomplete:last-seen:watchlist-update` (Task 3), menu payload `{ section }` (Task 4).
- Produces: rebuilt panel with sections Watchlist / Tracked users / Currently subscribed / Transition log; `show-panel` handler accepting `{ section }`; `setupLastSeenMenuActions` without the `last-seen:open` relay.

- [ ] **Step 1: Replace setupLastSeenPanel entirely**

Find `function setupLastSeenPanel() {` (line ~4384) and replace the ENTIRE function - everything through the line `ipcRenderer.on('slack-autocomplete:last-seen:show-panel', () => toggle());` and its closing `  }` - with:

```js
  function setupLastSeenPanel() {
    if (!ipcRenderer) return;
    let root = null, visible = false;
    let txLimit = 50;
    let searchQuery = '';
    let searchTimer = null;
    let pendingSection = null;

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

    function section(titleText, anchorId) {
      const h = document.createElement('div');
      h.textContent = titleText;
      if (anchorId) h.id = anchorId;
      h.style.cssText = 'font-weight:700;margin:10px 0 4px;color:#cfcfcf;';
      return h;
    }

    function rowButton(labelText) {
      const b = document.createElement('button');
      b.textContent = labelText;
      b.style.cssText = 'background:#2a292a;color:#ddd;border:1px solid #4a494a;border-radius:5px;'
        + 'padding:1px 8px;margin-left:8px;cursor:pointer;font-size:11px;flex:none;';
      return b;
    }

    async function updateWatchlist(change, statusEl) {
      try {
        const res = await ipcRenderer.invoke('slack-autocomplete:last-seen:watchlist-update', change);
        if (!res || !res.ok) throw new Error((res && res.error) || 'update failed');
        render();
      } catch (e) {
        if (statusEl) statusEl.textContent = 'Watchlist update failed: ' + String((e && e.message) || e);
      }
    }

    function buildWatchlistSection(body, watchlist, names) {
      body.appendChild(section('Watchlist', 'slack-autocomplete-ls-sec-watchlist'));
      const watchSet = new Set(watchlist);

      const search = document.createElement('input');
      search.type = 'text';
      search.placeholder = 'Search users by name (or paste a user ID)...';
      search.value = searchQuery;
      search.style.cssText = 'width:100%;box-sizing:border-box;background:#121212;color:#fff;'
        + 'border:1px solid #3a393a;border-radius:6px;padding:5px 8px;font-size:12px;';
      const status = document.createElement('div');
      status.style.cssText = 'font-size:11px;color:#9a9a9a;padding:3px 0;min-height:14px;';
      const results = document.createElement('div');

      function matchRow(entry) {
        const line = document.createElement('div');
        line.style.cssText = 'display:flex;align-items:center;justify-content:space-between;padding:3px 0;';
        const label = document.createElement('span');
        label.textContent = (entry.name || entry.id) + '  (' + entry.id + ')';
        label.style.cssText = 'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
        line.appendChild(label);
        if (watchSet.has(entry.id)) {
          const mark = document.createElement('span');
          mark.textContent = 'added';
          mark.style.cssText = 'color:#2bac76;font-size:11px;margin-left:8px;flex:none;';
          line.appendChild(mark);
        } else {
          const add = rowButton('Add');
          add.addEventListener('click', () => updateWatchlist({ add: entry.id }, status));
          line.appendChild(add);
        }
        return line;
      }

      async function refreshResults() {
        const q = searchQuery.trim();
        results.textContent = '';
        status.textContent = '';
        if (q.length < 2) return;
        let roster = null;
        try {
          if (!lastSeenRoster) status.textContent = 'Loading directory...';
          roster = await fetchLastSeenRoster();
          status.textContent = '';
        } catch (e) {
          status.textContent = 'directory unavailable - paste a user ID instead';
        }
        if (q !== searchQuery.trim()) return; // stale response, a newer query took over
        let matches = roster ? lastSeenCore.filterRoster(roster, q, 10) : [];
        if (!matches.length && lastSeenCore.USER_ID_RE.test(q.toUpperCase())) {
          const id = q.toUpperCase();
          const names2 = await resolveUserNames([id]);
          matches = [{ id, name: names2[id] || id }];
        }
        results.textContent = '';
        if (!matches.length && q.length >= 2 && roster) {
          const p = document.createElement('div');
          p.textContent = '(no matches)';
          p.style.color = '#9a9a9a';
          results.appendChild(p);
        }
        for (const m of matches) results.appendChild(matchRow(m));
      }

      search.addEventListener('input', () => {
        searchQuery = search.value;
        if (searchTimer) clearTimeout(searchTimer);
        searchTimer = setTimeout(() => { searchTimer = null; refreshResults(); }, 250);
      });

      body.appendChild(search);
      body.appendChild(status);
      body.appendChild(results);

      const count = document.createElement('div');
      count.textContent = watchlist.length + ' watched (100 injected max)';
      count.style.cssText = 'font-size:11px;color:#9a9a9a;padding:4px 0;';
      body.appendChild(count);
      if (!watchlist.length) {
        const p = document.createElement('div');
        p.textContent = '(watchlist is empty)';
        body.appendChild(p);
      }
      for (const id of watchlist) {
        const line = document.createElement('div');
        line.style.cssText = 'display:flex;align-items:center;justify-content:space-between;padding:3px 0;border-bottom:1px solid #2a292a;';
        const label = document.createElement('span');
        label.textContent = (names[id] || id) + '  (' + id + ')';
        label.style.cssText = 'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
        const rm = rowButton('Remove');
        rm.addEventListener('click', () => updateWatchlist({ remove: id }, status));
        line.appendChild(label); line.appendChild(rm);
        body.appendChild(line);
      }
      if (searchQuery.trim().length >= 2) refreshResults();
    }

    async function render() {
      ensurePanel();
      const body = root.querySelector('#slack-autocomplete-last-seen-body');
      body.textContent = 'Loading...';
      let snap, recent;
      try {
        snap = await ipcRenderer.invoke('slack-autocomplete:last-seen:snapshot');
        recent = await ipcRenderer.invoke('slack-autocomplete:last-seen:recent-transitions', { limit: txLimit });
      } catch (e) { body.textContent = 'Failed to load last-seen data.'; return; }

      const userIds = Object.keys(snap.users || {});
      const sub = snap.currentSubscription || { clientIds: [], injectedIds: [] };
      const allIds = Array.from(new Set(userIds
        .concat(sub.clientIds || []).concat(sub.injectedIds || [])
        .concat(snap.watchlist || [])
        .concat((recent || []).map((t) => t.user))));
      const names = await resolveUserNames(allIds);
      const nameOf = (id) => (names[id] || id);
      const watchSet = new Set(snap.watchlist || []);

      body.textContent = '';

      // Watchlist editor.
      buildWatchlistSection(body, snap.watchlist || [], names);

      // Tracked users, most recently online first.
      body.appendChild(section('Tracked users (' + userIds.length + ')'));
      const rows = userIds.map((id) => {
        const d = lastSeenCore.describeLastSeen(snap.users[id]);
        return { id, d };
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
      const cLine = document.createElement('div'); cLine.textContent = 'By Slack client: ' + cIds;
      const iLine = document.createElement('div'); iLine.style.color = '#7aa7ff'; iLine.textContent = 'Injected from watchlist: ' + iIds;
      subBox.appendChild(cLine); subBox.appendChild(iLine);
      body.appendChild(subBox);

      // Transition log with resolved names.
      body.appendChild(section('Transition log', 'slack-autocomplete-ls-sec-transitions'));
      if (!recent || !recent.length) { const p = document.createElement('div'); p.textContent = '(none logged yet)'; body.appendChild(p); }
      for (const t of (recent || [])) {
        const line = document.createElement('div');
        line.style.cssText = 'padding:2px 0;color:#bdbdbd;';
        line.textContent = fmtTime(t.at) + '  ' + nameOf(t.user) + '  ' + t.presence + (t.baseline ? '  (baseline)' : '');
        body.appendChild(line);
      }
      if (recent && recent.length >= txLimit && txLimit < 500) {
        const more = rowButton('Load more');
        more.style.marginLeft = '0';
        more.style.marginTop = '6px';
        more.addEventListener('click', () => { txLimit = Math.min(txLimit * 2, 500); render(); });
        body.appendChild(more);
      }

      if (pendingSection) {
        const el = root.querySelector('#slack-autocomplete-ls-sec-' + pendingSection);
        if (el) { try { el.scrollIntoView({ block: 'start' }); } catch (e) { /* ignore */ } }
        pendingSection = null;
      }
    }

    function toggle(show) {
      ensurePanel();
      visible = (show === undefined) ? !visible : show;
      root.style.display = visible ? 'flex' : 'none';
      if (visible) render();
    }

    ipcRenderer.on('slack-autocomplete:last-seen:show-panel', (_event, payload) => {
      if (payload && payload.section) {
        pendingSection = payload.section;
        toggle(true);
      } else {
        toggle();
      }
    });
  }
```

- [ ] **Step 2: Remove the open relay from setupLastSeenMenuActions**

Find:

```js
  function setupLastSeenMenuActions() {
    if (!ipcRenderer) return;
    ipcRenderer.on('slack-autocomplete:last-seen:export', () => { runLastSeenExport(); });
    ipcRenderer.on('slack-autocomplete:last-seen:open', (_event, payload) => {
      ipcRenderer.invoke('slack-autocomplete:last-seen:open-file', { which: (payload && payload.which) || 'store' }).catch(() => {});
    });
  }
```

Replace with:

```js
  function setupLastSeenMenuActions() {
    if (!ipcRenderer) return;
    ipcRenderer.on('slack-autocomplete:last-seen:export', () => { runLastSeenExport(); });
  }
```

- [ ] **Step 3: Verify nothing references the removed channels**

Run: `grep -n "last-seen:open" slack-autocomplete-electron-app.sh`
Expected: no output.

- [ ] **Step 4: Verify the script parses and tests still pass**

Run: `bash -n slack-autocomplete-electron-app.sh && node --test test/last-seen-core.test.js`
Expected: parse OK, 34 tests pass.

- [ ] **Step 5: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: interactive watchlist editor and named transition log in panel"
```

---

### Task 7: README update

**Files:**
- Modify: `README.md` (Last Seen bullet, line ~28)

- [ ] **Step 1: Extend the bullet**

Replace the existing Last Seen bullet:

```markdown
- Last seen (presence) tracking: records when tracked users were last online by
  tapping the client's presence WebSocket, injects a hand-edited watchlist of extra
  user ids into presence subscriptions, and shows current subscriptions, per-user
  last-online, and a transition log in a "Last Seen" panel (File menu). Presence is
  derived from live events only (throttled, no backfill); the data stays local.
```

with:

```markdown
- Last seen (presence) tracking: records when tracked users were last online by
  tapping the client's presence WebSocket and injects a watchlist of extra user
  ids into presence subscriptions. The "Last Seen" panel (File menu) shows current
  subscriptions, per-user last-online, a transition log with resolved names, and
  an interactive watchlist editor with workspace name search (the watchlist file
  stays hand-editable). Presence is derived from live events only (throttled, no
  backfill); the data stays local.
```

- [ ] **Step 2: Verify no Unicode dashes**

Run: `rg -n $'[‐-―]' README.md last-seen-core.js || echo "clean"`
Expected: `clean`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README notes interactive watchlist editor and named transition log"
```

---

### Task 8: Build, deploy, and live verification

**Files:** none (verification only). Build/deploy per the user-approved flow from this session.

- [ ] **Step 1: Build and deploy**

```bash
bash -n slack-autocomplete-electron-app.sh
./slack-autocomplete-electron-app.sh   # expect "Copied last-seen-core.js" and "Done."
osascript -e 'tell application "SlackAutocompleteElectron" to quit'; sleep 2
rm -rf /Applications/SlackAutocompleteElectron.app
ditto ~/SlackAutocompleteElectron/dist/SlackAutocompleteElectron-darwin-arm64/SlackAutocompleteElectron.app /Applications/SlackAutocompleteElectron.app
```

- [ ] **Step 2: Launch and verify in the app**

Launch normally (`open /Applications/SlackAutocompleteElectron.app`). Then:

- `File > Last Seen > Open Watchlist`: panel opens scrolled to the Watchlist section.
- Type a colleague's name: "Loading directory..." appears once, then matches with Add buttons.
- Add one: row moves to the current-entries list; `last-seen-watchlist.json` on disk contains the id and keeps the instructions block; within a minute the id shows under "Injected from watchlist".
- Remove it: row disappears, file updated.
- `File > Last Seen > Open Transition Log`: panel opens scrolled to "Transition log"; entries show usernames, not raw ids; "Load more" appears when 50+ entries exist and loads more.
- Hand-edit the watchlist file externally: panel data updates after reopening (hot-reload broadcast still works).

- [ ] **Step 3: Record results**

Note any deviations; if `users.list` is denied for the session token, confirm the "directory unavailable - paste a user ID instead" fallback path works.

---

## Self-Review

**Spec coverage:**
- Panel layout + section order -> Task 6 render(). Covered.
- Menu retargeting, no raw file opening, open-file removal -> Tasks 3, 4, 6. Covered.
- Search input, debounce 250 ms, min 2 chars, 10 matches, "added" marker -> Tasks 2 (min-2/cap in filterRoster), 6 (debounce, matchRow). Covered.
- Roster once per window, 200/page, 25-page cap, deleted/bots excluded, pre-fills name cache, "Loading directory..." -> Task 5, 6. Covered.
- Roster failure fallback to pasted id -> Task 6 refreshResults (USER_ID_RE branch + status text). Covered.
- Current entries with names, Remove, count line -> Task 6 buildWatchlistSection. Covered.
- watchlist-update IPC, atomic write preserving instructions, reload + broadcast + return list -> Task 3. Covered.
- Hand edits keep working -> unchanged fs.watch path; noted in Task 3. Covered.
- Transition log 50 rows, Load more doubling to 500, names -> Task 6. Covered.
- applyWatchlistUpdate pure + tested -> Task 1. Covered.
- Error handling: ok:false surfaces inline (statusEl), isSlackSender guards, search degrades -> Tasks 3, 6. Covered.

**Placeholder scan:** none; all code steps carry complete code.

**Type consistency:** `applyWatchlistUpdate` returns `{ users, changed }` consumed in Task 3. `filterRoster(roster, q, 10)` matches Task 2 signature. IPC names match: `watchlist-update` (Tasks 3, 6), `show-panel` payload `{ section }` (Tasks 4, 6). Section anchor ids `slack-autocomplete-ls-sec-watchlist`/`-transitions` consistent between builder and scroll code. `fetchLastSeenRoster`/`lastSeenRoster` names consistent (Tasks 5, 6).
