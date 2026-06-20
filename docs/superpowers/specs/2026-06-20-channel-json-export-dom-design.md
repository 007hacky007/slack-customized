# Export Channel as JSON (DOM-scraping) - Design

Date: 2026-06-20
Status: Approved (pending spec review)

## Overview

This is an **alternative** implementation of the "Export Channel as JSON" feature that
extracts data by **scraping the rendered DOM** instead of calling Slack's web API. It
defeats Slack's lazy-loading by **auto-scrolling** the message list, and captures threads
by **programmatically opening each thread pane**.

It is a sibling to the API-based design
(`2026-06-20-channel-json-export-design.md`). The two are independent; only one needs to be
implemented, and the choice can be made after seeing both. This spec reuses the API spec's
**output JSON schema, save flow, and progress-UI conventions** so the two exports are
interchangeable downstream.

The DOM approach trades completeness and robustness for not touching the API:

- It needs no token and issues no API calls (no rate-limit handling).
- It is inherently **fragile** (depends on Slack's CSS/markup) and **slower** (scroll waits,
  thread open/close, reaction hovers).
- It **cannot guarantee full reaction-author lists** (the DOM truncates them).

## Goals

- One-click export of the current channel to a JSON file, using only the rendered page.
- Capture the full message history by auto-scrolling to the top of the channel.
- Capture all threads by opening each thread pane and scrolling it fully.
- Capture reactions with **best-effort** author names (hovering each reaction).
- Visible progress bar with a cancel control; restore the UI afterward.

## Non-goals (out of scope)

- Guaranteed-complete reaction-author lists (DOM-limited; see Reactions).
- Faithful capture of rich message structure (Slack `blocks`, raw attachment objects). DOM
  mode captures rendered text + best-effort structured bits, not the raw API objects.
- File attachment bytes (metadata/links only, as rendered).
- Incremental/resumable exports; DMs as a first-class target (works if open, untuned).

## Architecture

Mirrors the existing `main.js` / `preload.js` split.

1. **Main process (`main.js`)**
   - New menu item **File -> "Export Channel as JSON (DOM scrape)..."**, accelerator
     `Cmd+Shift+D` (distinct from the API export's `Cmd+Shift+E` so both can coexist).
   - On click: send IPC `slack-autocomplete:export-channel-dom` to the focused window.
   - **Reuses** the API spec's `slack-autocomplete:save-export` IPC handler (save dialog +
     file write). No new save code.

2. **Preload (`preload.js`)** - performs the scrape in the page context where it can read
   and drive the DOM.
   - Listens for `slack-autocomplete:export-channel-dom`.
   - Runs the scrape pipeline (below) behind a **modal progress overlay that blocks user
     input**, so manual interaction can't disturb scrolling/thread state mid-export.
   - On completion, calls `slack-autocomplete:save-export` with the JSON + suggested name.

All scrape logic lives in one clearly-delimited preload section: a centralized **selector
map**, plus focused helpers (scroller, message scraper, thread driver, reaction hover
scraper, user/name collector, overlay UI, orchestrator).

## Selector strategy (fragility containment)

Every DOM dependency is defined once in a single `SELECTORS` object so breakage from Slack
updates is fixable in one place. The values below are **representative and MUST be verified
against the live DOM at implementation time** (Slack changes markup frequently). Each
helper degrades gracefully (skips/logs) if a selector misses, rather than throwing.

Representative selectors:

- Message pane + scroll container: `[data-qa="message_pane"]`,
  `[data-qa="slack_kit_list"] .c-virtual_list__scroll_container`.
- Message rows (virtualized): `[data-qa="virtual-list-item"]` / `[role="listitem"]`; the row
  id / `data-item-key` carries the message `ts`.
- Timestamp: `a.c-timestamp[data-ts]` (authoritative `ts`).
- Author: `[data-qa="message_sender_name"]` (display name); user id when present via
  `data-message-sender` / profile link `data-member-id`.
- Body text: `[data-qa="message-text"]` / `.c-message_kit__blocks` (use `innerText`).
- Edited / files indicators: `.c-message_kit__edited`, file/attachment blocks within the row.
- Reactions: `.c-reaction_bar .c-reaction`, count in `.c-reaction__count`, emoji name from
  `data-stringify-emoji` / `aria-label`.
- Reply (thread) affordance: `[data-qa="reply_bar"]` / `.c-message_kit__thread_replies` with
  its clickable open-thread control.
- Thread flexpane: `[data-qa="threads_flexpane"]`, its own
  `.c-virtual_list__scroll_container`, and close control `[data-qa="close_flexpane"]`.
- Top-of-channel marker: `[data-qa="channel_welcome_message"]` / channel intro block
  (signals the history top has been reached).

## Scrape pipeline

### Phase 0 - Resolve context

- Parse `teamId` + `channelId` from the URL (`/client/<TEAM_ID>/<CHANNEL_ID>`).
- Read channel display name from the channel header DOM (best-effort; fall back to id).
- Abort with an overlay error if no message pane is present.

### Phase 1 - Auto-scroll and scrape top-level messages

Because the list is virtualized (off-screen rows are removed from the DOM), we **scrape
while scrolling**, accumulating into a `Map` keyed by message `ts` (dedupe across overlaps).

1. Jump to the bottom (newest) to establish a known anchor.
2. Repeatedly: scrape all currently-rendered message rows into the map, then scroll the
   container **upward** by a fraction of the viewport (overlapping steps so nothing between
   frames is skipped), and `await` a short settle delay for Slack to render/load older rows.
3. Stop when the **top is reached**: the top-of-channel marker is visible, or `scrollTop`
   stays at 0 with no new message ids added across several consecutive attempts (safety
   counter to avoid infinite loops).
4. Each scraped row yields: `ts`, author name (+ id if available), `text` (innerText), an
   ISO timestamp derived from `ts`, and flags (`edited`, `has_files`). Reaction elements are
   recorded now (emoji + count + DOM handle reference deferred to Phase 3).

### Phase 2 - Open and scrape threads

For every message whose row shows a reply bar (`reply_count > 0`):

1. Click the open-thread control to open the thread flexpane; `await` it to render.
2. Auto-scroll the flexpane's own scroll container to the top (threads lazy-load too),
   scraping replies into a per-thread `Map` keyed by `ts`, same extraction as Phase 1.
3. Drop the parent message from the replies (it is already the top-level message); attach
   the remaining replies to the parent.
4. Close the flexpane (`close_flexpane`) before moving to the next thread, restoring the
   main pane.

Threads are processed one at a time to keep UI state deterministic.

### Phase 3 - Reaction authors (best-effort, hover)

For every reaction on every message and reply:

1. Scroll the reaction into view (re-locating its row by `ts` since virtualization may have
   recycled the node), dispatch hover/`mouseenter` to trigger Slack's reaction tooltip.
2. `await` the tooltip, scrape the author names it lists.
3. If the tooltip shows "...and N others" (or names < count), record the partial names and
   set `users_truncated: true`. Move the mouse away to dismiss the tooltip.

This is the slow, fragile phase; it is paced and fully cancelable. If a reaction's tooltip
can't be read, we keep the emoji + count and mark it truncated.

### Phase 4 - Build users map

Collect distinct `(id, name)` pairs seen across authors and reaction tooltips. Since DOM
gives display names directly, the map is built from scraped data (no API). Where a user id
was extractable it keys the map; otherwise a stable synthetic key derived from the display
name is used and flagged `id_unknown: true`. Inline `user_name` / `user_names` are populated
directly from the scrape.

## Pacing & robustness

- No API rate limits apply, but each scroll/hover/thread step `await`s a short settle delay
  so Slack can render; delays are small constants centralized for tuning.
- Infinite-loop guards: max consecutive no-progress iterations for both main-pane and
  thread-pane scrolling.
- Graceful degradation: any missing selector or unreadable element is skipped and logged
  (counted in a "skipped" tally surfaced at the end), never aborting the whole export.
- The export is **atomic**: the file is written only after the pipeline completes
  successfully; cancel writes nothing.
- **State restoration**: on completion/cancel/error, close any open flexpane and dismiss
  tooltips so the UI is left as found.

## Progress UI

Same floating overlay as the API spec, but **modal** (blocks page input during the scrape):

- Phase 1 - Messages: progress bar driven by scroll position (`1 - scrollTop/scrollHeight`
  as an approximate fraction) plus a live scraped-count.
- Phase 2 - Threads: "Thread X / Y" determinate.
- Phase 3 - Reactions: "Reaction X / Y" determinate.
- A **Cancel** button (abort flag) that stops promptly and restores UI.
- Final state: "Saved to <path>" / "Export canceled" / error, then dismiss.

## Save flow

Identical to the API spec: preload `JSON.stringify`s the result and invokes
`slack-autocomplete:save-export` with `{ json, suggestedName }`; main shows the save dialog
(default `~/Downloads/slack-export-<channel>-<YYYYMMDD-HHMMSS>.json`) and writes the file.

## Output JSON schema

Same shape as the API spec, so consumers can treat both exports identically, with two
additions/caveats:

- Top-level `export.source` is `"dom-scrape"` (the API export uses `"web-api"`).
- Fields not reliably available from the DOM are omitted rather than guessed: raw `blocks`,
  raw `attachments` objects, and precise `edited` timestamps. `text` is the rendered
  `innerText`. Reaction `users`/`user_names` may be partial with `users_truncated: true`.

```json
{
  "export": { "exported_at": "...", "exported_by": "slack-autocomplete-electron",
              "version": 1, "source": "dom-scrape" },
  "workspace": { "team_id": "T02MCKX93", "name": "..." },
  "channel": { "id": "C09LGFFFSD9", "name": "...", "is_private": true },
  "users": { "U01AGR328JC": { "id": "U01AGR328JC", "name": "John Doe",
                              "id_unknown": false } },
  "messages": [
    {
      "ts": "1779807375.562979",
      "user": "U01AGR328JC",
      "user_name": "John Doe",
      "text": "...rendered text...",
      "edited": true,
      "has_files": false,
      "reactions": [
        { "name": "+1", "count": 12,
          "user_names": ["John Doe", "Jane Roe"], "users_truncated": true }
      ],
      "reply_count": 2,
      "replies": [
        { "ts": "1779807400.000100", "user_name": "Jane Roe", "text": "...",
          "reactions": [] }
      ]
    }
  ]
}
```

Messages and replies are ordered chronologically (oldest first).

## Error handling summary

- No channel/message pane open -> overlay error, no file.
- Selector misses on individual rows/reactions/threads -> skip + tally, export continues.
- Fatal DOM failure (e.g. scroll container not found) -> overlay error, UI restored, no file.
- User cancel -> abort, UI restored, no file.

## Assumptions / risks

1. **Selector drift** is the dominant risk: Slack ships markup changes regularly. All
   selectors are centralized and must be validated against the live DOM during
   implementation, and may need maintenance over time.
2. **Reaction-author completeness** is not achievable for high-count reactions (tooltip
   truncation); partial lists are flagged.
3. **Speed**: large channels with many threads/reactions can take considerably longer than
   the API approach due to per-step UI waits.
4. **UI disruption**: the export drives scroll position and opens/closes threads; mitigated
   by the modal overlay and end-state restoration, but the window must remain on the channel
   during export.
5. **Virtualization edge cases**: aggressive scroll steps could skip rows; mitigated by
   overlapping steps + `ts`-keyed dedupe + no-progress guards.

## Manual verification plan

1. Open the test channel, run File -> Export Channel as JSON (DOM scrape).
2. Confirm the overlay blocks input, the bar advances through phases, threads open/close,
   and a file is written.
3. Compare message/thread counts and a few reactions against the API export of the same
   channel to quantify DOM completeness gaps.
4. Confirm a high-count reaction is flagged `users_truncated: true` with a partial list.
5. Cancel mid-scroll and confirm the UI is restored (no open flexpane) and no file written.
