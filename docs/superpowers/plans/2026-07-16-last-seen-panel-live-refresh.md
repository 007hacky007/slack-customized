# Last Seen Panel Live Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the open Last Seen panel refresh in place when presence, subscription, or watchlist data changes, instead of requiring close/re-open.

**Architecture:** The main process already receives every mutation via IPC. It gains a throttled `broadcastLastSeenChanged()` that notifies all Slack windows over a new `slack-autocomplete:last-seen:changed` channel. The panel (in preload) listens and re-renders, debounced, with guards for typing focus, scroll position, and overlapping renders.

**Tech Stack:** Electron IPC inside the two heredocs of `slack-autocomplete-electron-app.sh` (main.js heredoc: lines ~122-2052; preload.js heredoc: lines ~2053-5700). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-16-last-seen-panel-live-refresh-design.md`

## Global Constraints

- All app source lives inside heredocs in `slack-autocomplete-electron-app.sh`. Edit the heredoc text, never generated files.
- No new unit tests (change is IPC/DOM glue); existing tests must keep passing: `node --test test/*.test.js`.
- IPC channel names use the existing `slack-autocomplete:` prefix.
- Windows with `win.__sawPool` set are excluded from broadcasts (existing convention, see `broadcastWatchlist`).
- No Unicode dashes in any authored text; hyphen-minus only.

---

### Task 1: Main process - throttled change broadcast

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (main.js heredoc: `broadcastWatchlist` at ~line 593; `last-seen:event` handler at ~line 1866)

**Interfaces:**
- Produces: main sends `slack-autocomplete:last-seen:changed` (no payload) to every non-pool Slack window, coalesced to at most one send per second (trailing edge). Task 2 listens on this channel.
- Consumes: existing `broadcastWatchlist()`, `scheduleLastSeenSave()`, `BrowserWindow`.

- [ ] **Step 1: Add the helper next to `broadcastWatchlist`**

Directly after the closing brace of `broadcastWatchlist()` (~line 599), insert:

```js
let lastSeenChangedTimer = null;
function broadcastLastSeenChanged() {
  if (lastSeenChangedTimer) return; // trailing-edge throttle: one send per second max
  lastSeenChangedTimer = setTimeout(() => {
    lastSeenChangedTimer = null;
    for (const win of BrowserWindow.getAllWindows()) {
      if (!win || win.isDestroyed() || win.__sawPool) continue;
      try { win.webContents.send('slack-autocomplete:last-seen:changed'); }
      catch (err) { /* ignore */ }
    }
  }, 1000);
}
```

- [ ] **Step 2: Fire it from `broadcastWatchlist`**

Watchlist changes (IPC updates AND external file edits picked up by `watchWatchlistFile`) all funnel through `broadcastWatchlist()`. Add one line at the end of its body:

```js
function broadcastWatchlist() {
  for (const win of BrowserWindow.getAllWindows()) {
    if (!win || win.isDestroyed() || win.__sawPool) continue;
    try { win.webContents.send('slack-autocomplete:last-seen-watchlist', lastSeenWatchlist); }
    catch (err) { /* ignore */ }
  }
  broadcastLastSeenChanged();
}
```

- [ ] **Step 3: Fire it from the presence event handler**

In `ipcMain.on('slack-autocomplete:last-seen:event', ...)` (~line 1866), add `broadcastLastSeenChanged();` inside BOTH branches, after each `scheduleLastSeenSave();`:

```js
    if (payload.kind === 'sub') {
      lastSeenCore.recordSubscription(lastSeenStore, payload.clientIds || [], payload.injectedIds || [], now);
      lastSeenCurrentSub = { clientIds: payload.clientIds || [], injectedIds: payload.injectedIds || [], at: now };
      scheduleLastSeenSave();
      broadcastLastSeenChanged();
    } else if (payload.kind === 'change') {
      const res = lastSeenCore.applyPresenceEvent(
        lastSeenStore, { ids: payload.ids, user: payload.user, presence: payload.presence }, now);
      appendTransitions(res.transitions);
      scheduleLastSeenSave();
      broadcastLastSeenChanged();
    }
```

No change needed in the `watchlist-update` handler: it already calls `broadcastWatchlist()`, which now triggers the changed broadcast.

- [ ] **Step 4: Syntax-check the shell script and the generated main.js**

```bash
bash -n slack-autocomplete-electron-app.sh
awk "/^cat > main.js <<'EOF'\$/{f=1;next} f&&/^EOF\$/{exit} f" slack-autocomplete-electron-app.sh > "$TMPDIR/ls-main-check.js" && node --check "$TMPDIR/ls-main-check.js"
```

Expected: both commands exit 0, no output. Also confirm the extraction was non-empty: `wc -l "$TMPDIR/ls-main-check.js"` should report roughly 1900+ lines.

- [ ] **Step 5: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: main broadcasts throttled last-seen:changed on presence/watchlist updates"
```

---

### Task 2: Renderer - panel re-renders on change

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (preload.js heredoc, `setupLastSeenPanel()` at ~line 4430-4695)

**Interfaces:**
- Consumes: `slack-autocomplete:last-seen:changed` broadcasts from Task 1.
- Produces: nothing new outward; panel behavior only.

- [ ] **Step 1: Add refresh state and helpers inside `setupLastSeenPanel`**

At the top of `setupLastSeenPanel()`, extend the existing state block (`let root = null, visible = false; ...`) with:

```js
    let refreshTimer = null;
    let rendering = false, renderQueued = false;
    let dirtyWhileTyping = false;
```

Below `fmtTime`, add:

```js
    function searchHasFocus() {
      const a = document.activeElement;
      return !!(root && a && root.contains(a) && a.tagName === 'INPUT');
    }

    function scheduleRefresh() {
      if (!visible) return;
      if (refreshTimer) clearTimeout(refreshTimer);
      refreshTimer = setTimeout(() => {
        refreshTimer = null;
        if (!visible) return;
        if (searchHasFocus()) { dirtyWhileTyping = true; return; }
        render();
      }, 500);
    }
```

- [ ] **Step 2: Wrap `render()` with an in-flight guard and rename the body to `renderNow()`**

Rename the existing `async function render()` to `async function renderNow()` and add above it:

```js
    async function render() {
      if (rendering) { renderQueued = true; return; }
      rendering = true;
      try { await renderNow(); }
      finally {
        rendering = false;
        if (renderQueued) { renderQueued = false; render(); }
      }
    }
```

All existing internal callers (`updateWatchlist`, the Load more button, `toggle`) keep calling `render()` and get the guard for free. The recursive `render()` calls inside `renderNow` do not exist; only the Load more button and updateWatchlist call render, from event handlers.

- [ ] **Step 3: Make `renderNow()` refresh-friendly (no Loading flash, keep scroll)**

At the top of `renderNow()`, replace:

```js
      const body = root.querySelector('#slack-autocomplete-last-seen-body');
      body.textContent = 'Loading...';
```

with:

```js
      const body = root.querySelector('#slack-autocomplete-last-seen-body');
      const prevScroll = body.scrollTop;
      if (!body.childNodes.length) body.textContent = 'Loading...';
```

(First open still shows Loading...; background refreshes keep the old content visible until the rebuilt content swaps in.)

At the bottom of `renderNow()`, immediately BEFORE the existing `if (pendingSection) {` block, add:

```js
      body.scrollTop = prevScroll;
```

(so an explicit menu jump to a section still wins over scroll restore).

- [ ] **Step 4: Re-render on blur if a refresh was suppressed while typing**

In `buildWatchlistSection`, right after the existing `search.addEventListener('input', ...)` registration, add:

```js
      search.addEventListener('blur', () => {
        setTimeout(() => {
          if (dirtyWhileTyping && visible && !searchHasFocus()) {
            dirtyWhileTyping = false;
            render();
          }
        }, 150);
      });
```

The 150 ms delay lets a click on an Add/Remove button complete before the DOM is rebuilt underneath it (those buttons re-render anyway via `updateWatchlist`).

- [ ] **Step 5: Subscribe to the change broadcast**

Next to the existing `ipcRenderer.on('slack-autocomplete:last-seen:show-panel', ...)` at the end of `setupLastSeenPanel`, add:

```js
    ipcRenderer.on('slack-autocomplete:last-seen:changed', () => scheduleRefresh());
```

- [ ] **Step 6: Syntax-check the shell script and the generated preload.js**

```bash
bash -n slack-autocomplete-electron-app.sh
awk "/^cat > preload.js <<'EOF'\$/{f=1;next} f&&/^EOF\$/{exit} f" slack-autocomplete-electron-app.sh > "$TMPDIR/ls-preload-check.js" && node --check "$TMPDIR/ls-preload-check.js"
```

Expected: both exit 0. Confirm non-empty extraction: `wc -l "$TMPDIR/ls-preload-check.js"` roughly 3600+ lines.

- [ ] **Step 7: Run existing unit tests**

```bash
node --test test/*.test.js
```

Expected: all pass (this change touches no tested module; a failure means an unrelated break).

- [ ] **Step 8: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: Last Seen panel refreshes in place on change broadcasts"
```

---

### Task 3: README note and manual end-to-end verification

**Files:**
- Modify: `README.md:28-34` (Last seen feature bullet)

**Interfaces:**
- Consumes: the finished behavior from Tasks 1-2.
- Produces: documentation only.

- [ ] **Step 1: Update the README bullet**

In the "Last seen (presence) tracking" bullet, change the sentence describing the panel so it mentions live refresh. Replace:

```
  ids into presence subscriptions. The "Last Seen" panel (File menu) shows current
  subscriptions, per-user last-online, a transition log with resolved names, and
```

with:

```
  ids into presence subscriptions. The "Last Seen" panel (File menu) refreshes in
  place while open and shows current subscriptions, per-user last-online, a
  transition log with resolved names, and
```

- [ ] **Step 2: Rebuild the app**

```bash
./slack-autocomplete-electron-app.sh
```

Expected: script completes, electron-packager produces the app bundle without errors.

- [ ] **Step 3: Manual verification (requires the running app)**

Replace the `/Applications` copy with the fresh build (manual, per project convention), launch, then:

1. Open the Last Seen panel (File menu) and leave it open.
2. Edit the watchlist file on disk (`last-seen-watchlist.json` in userData) - add or remove an id and save. Expected: within ~2 s the panel's Watchlist and Currently subscribed sections update without closing the panel.
3. Leave the panel open while presence events arrive (e.g. a tracked coworker goes online/away). Expected: Tracked users and Transition log update in place.
4. Focus the watchlist search box and type; trigger a change (step 2 again). Expected: the panel does NOT rebuild while typing; after clicking elsewhere (blur) it refreshes.
5. Scroll the panel halfway down, trigger a change. Expected: scroll position is preserved after the refresh.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: README notes Last Seen panel live refresh"
```
