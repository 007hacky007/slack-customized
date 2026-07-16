# Last Seen panel live refresh - design

Date: 2026-07-16
Status: approved (push-on-change chosen over polling)

## Problem

The Last Seen panel renders its data once, inside `toggle(true)`. While it stays
open, presence transitions, subscription changes, and watchlist edits applied in
the main process are invisible; the user must close and re-open the panel to see
fresh data.

## Approach

Push-based refresh. The main process already receives every relevant mutation
(`slack-autocomplete:last-seen:event` for presence/subscription,
`slack-autocomplete:last-seen:watchlist-update` for watchlist edits). After
applying a mutation it broadcasts a change notification to all Slack windows;
an open panel re-renders itself. No polling.

Alternatives considered and rejected:

- Periodic polling (30s timer while open): simpler wiring but up to 30s stale
  and re-renders when nothing changed.
- Push plus fallback poll: extra code with no identified missed-event path.

## Main process changes

- New helper `broadcastLastSeenChanged()`, mirroring `broadcastWatchlist()`:
  sends `slack-autocomplete:last-seen:changed` (no payload) to all Slack
  windows.
- Throttled in main: at most one broadcast per second, trailing edge, so
  bursts of presence events coalesce into one notification.
- Called from:
  - the `last-seen:event` handler, for both `kind === 'sub'` and
    `kind === 'change'` (the panel shows the current subscription, so
    subscription changes count as visible data changes);
  - the `watchlist-update` handler after a successful write, so panels in
    other windows pick up watchlist edits (the originating panel already
    re-renders itself).

## Renderer changes (`setupLastSeenPanel`)

- Listen for `slack-autocomplete:last-seen:changed`. Ignore it when the panel
  is not visible. When visible, schedule `render()` debounced ~500 ms.
- Guards so the refresh never fights the user:
  - If the watchlist search input has focus, do not rebuild the DOM. Set a
    dirty flag and re-render on the input's blur (or on a later change event
    once focus has moved away).
  - Preserve `body.scrollTop` across the rebuild and restore it after, so the
    list does not jump to the top.
- In-flight guard on `render()`: if a refresh arrives while a render is
  running, queue at most one follow-up render instead of racing.
- Existing closure state (`searchQuery`, `txLimit`, name cache) already
  survives a re-render, so search text and "Load more" depth are kept.

## Error handling

Unchanged: a failed `render()` already replaces the body with a failure
message; the next change event retries naturally.

## Testing

The change is Electron IPC/DOM glue with no pure-logic surface, so no new unit
tests in `test/`. Verification is manual: rebuild via the .sh script, replace
the `/Applications` copy, open the panel, and confirm it updates in place when
a watched user flips presence and when the watchlist is edited.
