# Last Seen Panel: Interactive Watchlist and Named Transition Log

Date: 2026-07-15
Status: approved for planning
Builds on: `2026-07-15-last-seen-presence-tracking-design.md` (implemented on branch `feature/last-seen-presence-tracking`)

## Problem

The `File > Last Seen > Open Watchlist` and `Open Transition Log` menu items open
raw JSON/JSONL files in an external editor. The transition log shows only user ids.
Editing the watchlist requires hand-editing JSON and knowing user ids.

## Goals

- Show resolved usernames everywhere the transition log is displayed.
- Manage the watchlist interactively inside the app: search workspace users by
  name, add and remove entries with clicks.
- Never open the raw JSON/JSONL files from the menu. The files remain on disk as
  the storage format and stay hand-editable (hot-reload keeps working).

## Non-goals

- No changes to the tap, bridge, presence recording, or store schema.
- No per-keystroke server-side people search (undocumented APIs; not needed at
  this workspace size).
- No editing of the transition log (view only).

## Design

### Panel layout

The existing Last Seen panel gains one section and renames another. Order top to
bottom: warning banner (unchanged), **Watchlist** (new), Tracked users
(unchanged), Currently subscribed (unchanged), **Transition log** (renamed from
"Recent transitions", more rows).

Menu retargeting: `Open Watchlist` and `Open Transition Log` now open the panel
and scroll to their section. The `slack-autocomplete:last-seen:open-file` IPC
handler and the preload `last-seen:open` relay are removed along with the menu
items' shell.openPath path. (The handler for opening files goes away entirely;
nothing else uses it.)

### Watchlist section

- Search input at the top. Debounced ~250 ms, minimum 2 characters. Filters a
  cached workspace roster by substring match on username, real name, and display
  name (case-insensitive). Shows up to 10 matches as `name - id` rows, each with
  an **Add** button. Users already on the watchlist render with a disabled
  "added" marker instead of the button.
- Roster: fetched once per window on first search via the existing rate-limited
  `apiCall` bridge using `users.list` (limit 200 per page, cursor pagination,
  hard cap 25 pages / 5000 users). Deleted users and bots are excluded. While
  fetching, the section shows "Loading directory...". The roster also pre-fills
  the name cache used by the rest of the panel.
- Roster fetch failure: show "directory unavailable - paste a user ID instead".
  The same input then accepts a raw id matching `/^[UW][A-Z0-9]{2,}$/` and offers
  an Add row for it (name resolved via `users.info` if possible, id otherwise).
- Below the input: current watchlist entries as rows with resolved names and a
  **Remove** button each, plus a count line `N watched (100 injected max)`.

### Persistence path

New guarded IPC `slack-autocomplete:last-seen:watchlist-update` with payload
`{ add?: string, remove?: string }` (one of the two). Main process:

1. Applies the change via the new pure helper (below) to the in-memory list.
2. If changed, rewrites `last-seen-watchlist.json` atomically (temp + rename),
   preserving the instructions block from the template.
3. Reloads `lastSeenWatchlist` and broadcasts
   `slack-autocomplete:last-seen-watchlist` (same as the fs.watch path).
4. Returns `{ ok, users }` so the panel re-renders immediately.

Hand edits to the file keep working: fs.watch hot-reload is unchanged. A write
triggered by the app also fires fs.watch; the debounced reload is idempotent so
this is harmless.

### Transition log section

- Renders from the existing `last-seen:recent-transitions` IPC. Names come from
  the shared name cache (roster or `users.info`), falling back to the raw id.
- Starts at 50 rows; a **Load more** button doubles the limit per click up to
  the IPC's 500 cap, then disappears.

### Core module addition

`applyWatchlistUpdate(users, change)` in `last-seen-core.js`:

- `users`: current array of ids. `change`: `{ add?: string, remove?: string }`.
- Returns `{ users, changed }`. Validates ids against the user id regex, dedupes,
  preserves order, no-ops safely on invalid input, duplicate add, or missing
  remove target.
- Unit-tested in `test/last-seen-core.test.js`.

## Error handling

- Watchlist write failures return `{ ok: false, error }` and the panel shows the
  error inline; the in-memory list is only updated when the write succeeds.
- All new IPC handlers guard with `isSlackSender`.
- Search and roster code is wrapped so failures degrade to the paste-an-id path,
  never break the rest of the panel.

## Testing

- `node --test`: `applyWatchlistUpdate` cases (add, remove, duplicate, invalid,
  no-op).
- Live verification via the CDP harness (relaunch with
  `--remote-debugging-port`): search, add, remove, file contents, broadcast to
  the main-world tap, transition log names, menu retargeting.
