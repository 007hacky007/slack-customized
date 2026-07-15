# Last Seen (Presence) Tracking - Design

Date: 2026-07-15
Status: Approved (pending spec review)

## Overview

Slack exposes no "last seen" / "last online" timestamp for other users anywhere in its
client protocol or Web API (`users.getPresence` returns only `"active"` / `"away"` for
others). Last-seen information can therefore only be derived: observe live presence
transitions over time and record when each user was last seen `active`. There is no
backfill; tracking starts when the app starts listening.

This feature makes the wrapper record those transitions persistently, and additionally
injects a user-defined watchlist into the client's presence subscriptions so that chosen
users are tracked even when Slack's own UI would not subscribe to them.

Immediate motivation: validating a presence-related bug before reporting it, which
requires knowing (a) when users were actually seen online and (b) whether the client was
even subscribed to a given user at a given time.

## Background: how Slack delivers presence

- The web client keeps a WebSocket to Slack's message server (`wss-primary.slack.com`,
  with backup hosts). Presence is push-based over this socket.
- Since Slack's 2017 presence redesign, `presence_change` events are sent only for user
  ids the client has explicitly subscribed to with `{"type":"presence_sub","ids":[...]}`
  frames. Each `presence_sub` replaces the previous subscription list.
- The client subscribes to whoever it currently renders a presence dot for: sidebar DM
  conversations (pinned and recent), the open conversation's header/member pane, visible
  profile cards and avatars. The set changes as the UI changes.
- `presence_change` events carry `user` (or a batched `users` array) and `presence`
  (`active`/`away`), no timestamp; events are throttled server-side and can lag by up to
  about a minute. Immediately after subscribing, Slack pushes the current presence of the
  newly subscribed ids, which gives a baseline reading.

## Decisions (from brainstorming)

- **Coverage: passive tap plus watchlist injection.** Record everything the client
  already receives, and merge a user-maintained list of extra user ids into outgoing
  `presence_sub` frames so Slack also pushes presence for them.
- **Mechanism: main-world WebSocket wrapper**, injected from the preload before Slack's
  code runs (preload executes first; `webFrame.executeJavaScript` reaches the main
  world). Rejected alternatives: CDP debugger tap (receives all network traffic, can
  conflict with DevTools) and `users.getPresence` polling (rate-limited, inefficient,
  exactly what Slack's subscription model exists to avoid).
- **Storage: main process**, `userData/last-seen.json`, debounced writes. Data stays
  local; nothing leaves the machine.
- **Watchlist: hand-edited JSON file** in `userData`, opened via a menu item, hot-reloaded
  on change. No in-app editor UI (YAGNI).
- **Accessible transition log** (spec review feedback): every presence transition is
  appended to a plain JSONL file the user can open and grep, in addition to the derived
  per-user state.
- **Viewer: in-page panel** following the downloads-panel pattern (preload-rendered
  fixed pane, data over IPC), showing per-user last-seen state, recent transitions, the
  live subscription list, and a warning about presence event semantics.
- **Names resolved in the viewer and on export**, reusing the existing preload
  `api-call` bridge and rate-limited `users.info` pattern from the channel export
  features (with an in-memory cache). The live store keeps ids only.

## Architecture

### 1. Main-world socket tap (injected script)

Injected by the preload into the page's main world before Slack boots. Wraps
`window.WebSocket`:

- Only instruments sockets whose URL host ends in `.slack.com`; skips binary frames;
  every parse sits behind try/catch. On any error the wrapper falls back to
  pass-through - it must never break or delay Slack's own traffic.
- **Incoming**: on `message`, if the JSON has `type === "presence_change"`, dispatch a
  `CustomEvent` on `document` (string detail) with `{kind:"change", ids, presence}`.
- **Outgoing**: wraps `send()`. If the frame is a `presence_sub`, it records the client's
  id list, merges the current watchlist ids (deduplicated, capped), sends the rewritten
  frame, and dispatches `{kind:"sub", clientIds, injectedIds}`. If rewriting fails for
  any reason, the original frame is sent unmodified.
- **Watchlist updates** arrive from the isolated world via a second `CustomEvent`. On a
  change, if an instrumented socket is open and a previous client `presence_sub` was
  seen, the tap proactively re-sends the merged subscription so new watchlist entries
  take effect without waiting for the client's next re-subscribe.

### 1b. How the injected watchlist coexists with Slack's own subscriptions

Slack's client treats the subscription list as full-replace: every `presence_sub` frame
it sends overwrites the server-side list with exactly the ids in that frame. The tap
therefore never needs to "defend" its ids against the client:

- The rewrite happens at the socket boundary, inside `send()`. The client builds its
  frame normally (it never sees our modification), and every frame - initial subscribe,
  every UI-driven re-subscribe, every reconnect's first subscribe - gets the watchlist
  merged in at transmit time. The server-side subscription is therefore always
  `client ids UNION watchlist`, no matter how often Slack replaces its list.
- There is no state where Slack "wins" and drops watchlist ids: a client override is
  just another outgoing frame, and it gets rewritten like all the others. The only gap
  is between watchlist-file edit and the next outgoing frame, which the proactive
  re-send (previous client ids + new watchlist) closes immediately.
- Reconnects create a fresh socket; the wrapper instruments it like the first one, so
  coverage survives reconnects.
- Failure mode: if a rewrite ever throws, the original frame goes out unmodified - the
  watchlist ids drop off until the next `presence_sub`, and Slack's own behavior is
  never affected.

### 2. Preload bridge (isolated world)

Listens for the tap's `CustomEvent`s and relays them to the main process over IPC.
Receives the current watchlist from main at startup and on file change, and forwards it
into the main world. Also hosts the name-resolving export flow (see Surface).

### 3. Main-process store

`userData/last-seen.json`:

```json
{
  "users": {
    "U0123ABC": {
      "lastPresence": "away",
      "lastActiveAt": "2026-07-15T09:12:00.000Z",
      "lastAwayAt": "2026-07-15T09:40:00.000Z",
      "lastEventAt": "2026-07-15T09:40:00.000Z",
      "firstTrackedAt": "2026-07-14T08:00:00.000Z"
    }
  },
  "subscriptionLog": [
    { "at": "2026-07-15T08:00:01.000Z", "clientIds": ["U1", "U2"], "injectedIds": ["U9"] }
  ]
}
```

- Semantics: `active` event sets `lastPresence` and `lastActiveAt`; `away` event sets
  `lastPresence` and `lastAwayAt`. A user's "last online" is `lastAwayAt` when the
  preceding state was `active`, or "now" while `lastPresence` is `active`. A first-ever
  `away` baseline right after subscribing means only "was already away when tracking
  began" - `firstTrackedAt` disambiguates this.
- Timestamps are stamped at receipt (frames carry none).
- `subscriptionLog` is a ring buffer (last 100 entries) answering "was the client
  subscribed to user X at time T" - the evidence needed for the bug report.
- Writes are debounced (2 s) and atomic (write temp file, rename). Events from multiple
  windows (pop-outs have their own sockets) are idempotent updates, so duplicates are
  harmless (same-timestamp same-state repeats are skipped for the transition log).

### 3b. Transition log

`userData/last-seen-transitions.jsonl` - one line appended per observed transition:

```json
{"at":"2026-07-15T09:40:00.000Z","user":"U0123ABC","presence":"away","baseline":false}
```

- `baseline: true` marks the initial presence reading Slack pushes right after an id is
  newly subscribed (best-effort: the id was in the most recent `presence_sub`'s
  newly-added set and this is its first event since). Baseline `away` means "was already
  away when tracking began", not "went offline now".
- Plain JSONL so it is greppable and script-friendly; rotated at 5 MB to a single `.1`
  suffix. Presence transitions are low-volume (at most a few per tracked user per day),
  so rotation is a safety valve, not an expected event.
- The viewer panel reads the tail of this file for its "recent transitions" list.

### 4. Watchlist file

`userData/last-seen-watchlist.json`: `{ "instructions": "...", "users": ["U0123ABC"] }`.
Created with instructions on first run. Main process watches it (`fs.watch` plus re-read
on window focus as fallback), validates, and broadcasts to all windows. Invalid content
is logged and treated as empty. Injected ids are capped at 100 to keep merged
`presence_sub` frames well within sizes Slack accepts.

### 5. Surface: viewer panel plus menu

**Viewer panel** - the primary surface. An in-page fixed pane rendered by the preload,
same technique as the existing downloads panel (`position:fixed` pane, high z-index,
data fetched from main via `ipcRenderer.invoke`, user names resolved through the
existing rate-limited `api-call` bridge with an in-memory cache). Sections, top to
bottom:

1. **Warning banner** (always visible): presence events are throttled server-side and
   can lag by up to about a minute; there is no backfill (tracking starts when the app
   does); a baseline `away` reading means "already away when tracking began", not "just
   went offline".
2. **Tracked users table**: display name (falls back to id until resolved), current
   presence, "last online" (per the semantics above, "online now" while active),
   first-tracked date. Sorted by most recently online. Watchlist members are marked.
3. **Live subscription view**: the ids from the most recent `presence_sub`, with names,
   split into "subscribed by Slack client" and "injected from watchlist" - this shows
   at a glance which users presence is currently flowing for and why.
4. **Recent transitions**: tail of the transition log (most recent first), with names
   and baseline markers.

**Menu** - a `Last Seen` submenu under `File`, next to `Channel Sections`:

- **Show Last Seen Panel** - toggles the viewer panel in the focused window.
- **Export Last Seen...** - sends the store to the focused window's preload, which
  resolves display names (`users.info`, cached) and saves an enriched JSON through the
  existing save-dialog flow.
- **Open Watchlist** - opens the watchlist file in the default editor (creating it
  with instructions first if missing).
- **Open Transition Log** - opens the JSONL log file.

## Error handling

- The tap is fail-open: any exception in wrapping, parsing, or rewriting leaves Slack's
  original behavior intact; `send()` always transmits the original frame if the rewrite
  path throws.
- If main-world injection fails, the feature is silently off (logged via the existing
  debug logging switch).
- Store file corrupt or unreadable: start fresh, keep the corrupt file as `.bak`.

## Testing

Following the repo pattern (pure logic in a required module, `node --test`):

- New `last-seen-core.js` with pure functions: `mergePresenceSub(frameString,
  watchlistIds)` (rewrite logic including cap and malformed-frame pass-through),
  `applyPresenceEvent(store, event, now)` (state reducer), `parseWatchlist(raw)`.
- Tests cover: merge dedupe/cap/pass-through, active/away transition semantics, away
  baseline vs real transition (baseline flag detection), transition-log line formatting
  and duplicate suppression, subscription-log ring buffer, invalid watchlist handling.
- Manual verification: add a non-sidebar user id to the watchlist, confirm a
  `presence_change` baseline arrives for them (debug log) and the store updates; confirm
  official-behavior parity with the tap disabled.

## Risks

- Slack may move presence to another transport or change frame shapes; the tap then
  simply records nothing and Slack behavior is unaffected.
- `presence_sub` full-replace semantics are assumed; if Slack switches to incremental
  subscriptions the merge logic needs revisiting.
- Injected subscriptions send modified frames to Slack (indistinguishable in shape from
  a client with those users on screen, but still more ids than the UI would produce).
