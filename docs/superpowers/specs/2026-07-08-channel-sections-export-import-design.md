# Channel Sections Export/Import - Design

Date: 2026-07-08
Status: Approved (pending spec review)

## Overview

Slack's sidebar "channel sections" are useful for organizing channels, but reorganizing a
large number of channels by hand in the UI is slow. This feature adds:

1. **Export Sections**: dump the current sections-to-channels mapping (plus all member
   channels not yet in any section) to a JSON file.
2. **Import Sections**: read such a JSON file (typically the export, reorganized by hand or
   by a script/LLM) and apply it: create missing sections, move the listed channels into
   their target sections.

Sections live server-side and are managed by Slack's undocumented client endpoints
(`users.channelSections.list`, `users.channelSections.create`,
`users.channelSections.channels.bulkUpdate`), called with the same xoxc token mechanism the
app already uses for `client.counts` and `users.prefs.get`. Changes made through these
endpoints sync to all of the user's Slack clients, exactly as if done in the official app.

## Decisions (from brainstorming)

- **Use case: same-workspace round-trip.** Channels are matched by their stable IDs;
  channel names in the file are informational for hand-editing.
- **Import mode: additive apply.** Import only creates missing sections and moves listed
  channels into target sections. Nothing is deleted; sections not mentioned in the file are
  untouched. Re-importing the same file is a no-op (idempotent).
- **Format: JSON only.** Matches the existing export features and is trivially scriptable.
- **Mechanism: Slack client API** (not DOM automation), through the existing `api-call`
  IPC bridge (main-process `net.fetch`, session cookie + CORS handled, tier-based rate
  limiting and 429/5xx retry already built into `createApiCall`).

## File format

```json
{
  "format": "slack-sections-export",
  "version": 1,
  "exportedAt": "2026-07-08T12:00:00.000Z",
  "workspace": { "id": "T123", "name": "acme" },
  "sections": [
    {
      "name": "Infra",
      "emoji": "wrench",
      "channels": [
        { "id": "C0AAA", "name": "backbone" },
        { "id": "C0BBB", "name": "dns" }
      ]
    }
  ],
  "unsectioned": [
    { "id": "C0CCC", "name": "random" }
  ]
}
```

- `sections` contains only user-created sections (Slack `type: "standard"`). System
  sections (Starred, default Channels, DMs) are excluded from export and are never an
  import target.
- `unsectioned` lists member channels that are in no custom section, so the user can
  assign them in the file. On import this list is **ignored** (additive mode never removes
  a channel from a section).
- `emoji` is the section's emoji name without colons, or absent/null when the section has
  none.
- `format`/`version` allow import to reject files that are not a sections export.

## Menu (main process)

`File -> Channel Sections` submenu, placed next to the existing "Export Channel List"
submenu, with two items:

- **Export Sections...** sends IPC `slack-autocomplete:export-sections` to the focused
  Slack window's `webContents`.
- **Import Sections...** sends IPC `slack-autocomplete:import-sections`.

No accelerators (the existing export items have none either).

## Export flow (renderer, preload.js)

Follows the existing "Export Channel List" flow structure exactly (overlay, log,
AbortController, save-export IPC):

1. `getExportConfig(log, { requireChannel: false })` - token/apiBase from
   `localConfig_v2`, workspace identity from the URL.
2. `users.channelSections.list` via `createApiCall` -> normalize sections (pure helper),
   keep only `type: "standard"`.
3. `exportCore.fetchAllMemberChannels(apiCall, { types: 'public_channel,private_channel' })`
   (existing helper) -> id-to-name map for resolving section channel names, and the
   `unsectioned` computation (member channels not present in any standard section).
4. `exportCore.buildSectionsDoc(...)` (new pure function) -> the JSON doc above.
5. Save through the existing `save-export:begin/write/commit` IPC flow with suggested name
   `slack-sections-<workspace>-<timestamp>.json` (JSON only, no `allowText`).

Progress overlay reuses `createExportOverlay` with phases "Fetching sections", "Fetching
channels", "Saving file".

## Import flow (renderer, preload.js)

1. **New IPC handler in main:** `slack-autocomplete:open-import`. Shows a file-open dialog
   (JSON filter), reads the chosen file with a size cap (5 MB), returns
   `{ canceled }` or `{ path, content }`. Sender-validated with the existing
   `isSlackSender` check, like every other handler.
2. **Validate:** `exportCore.parseSectionsDoc(content)` (new pure function) - checks
   `format`/`version`, shape of `sections`/`channels`, returns the parsed doc or a
   descriptive error. A workspace-ID mismatch between the file and the current workspace is
   a hard error (this feature is same-workspace by design; channel IDs would not match
   anyway).
3. **Fetch current state:** `users.channelSections.list` + `fetchAllMemberChannels` (same
   calls as export).
4. **Compute plan:** `exportCore.computeSectionsImportPlan(doc, currentSections,
   memberChannels)` (new pure function) returns:
   - `create`: sections in the file with no existing standard section of the **exact same
     name** (first name match wins if Slack somehow holds duplicates).
   - `moves`: per target section, the channel IDs to insert, each with the source section
     ID to remove from (or none if currently unsectioned).
   - `skips`: channels with reasons - not a member of the channel, already in the target
     section (idempotent no-op), duplicate channel entry in the file (first placement
     wins).
5. **Confirm:** the overlay shows the plan summary ("create 3 sections, move 47 channels,
   skip 2 - see log") with **Apply / Cancel** buttons. No mutation happens before Apply.
   Skip reasons are listed in the overlay log before confirmation.
6. **Execute:**
   - `users.channelSections.create` for each section in `create` (name + emoji). The
     returned section ID feeds the moves targeting that section.
   - `users.channelSections.channels.bulkUpdate` per target section: `insert` into the
     target and `remove` from each channel's current section, mirroring how the official
     client moves channels. Batched per section to keep request counts low.
   - All calls go through `createApiCall` (tier spacing, 429 Retry-After, 5xx backoff,
     abort support).
   - A failed create or bulkUpdate is logged and execution **continues** with the
     remaining sections; the failure is reported in the final summary.
7. **Summary:** "Created X sections, moved Y channels, skipped Z, failed W" in the overlay
   `done`/`fail` state, details in the log.

## Endpoint verification (implementation prerequisite)

The `users.channelSections.*` request/response shapes are undocumented and must be
verified live before the import logic is finalized: capture the official Slack.app's
network traffic via CDP (the established verification approach in
`docs/official-slack-mimicry.md`) while listing/creating/moving sections, and match our
requests to it. The pure functions take normalized inputs, so shape corrections stay
confined to the thin normalization layer and the apiCall call sites.

## Code layout

- **`export-core.js`** (pure, unit-tested): `normalizeSections` (raw list response ->
  `[{ id, name, emoji, type, channelIds }]`), `buildSectionsDoc`, `parseSectionsDoc`,
  `computeSectionsImportPlan`. No DOM, no IPC, no fetch.
- **`test/export-core.test.js`**: unit tests for the four functions - happy path,
  idempotent re-import produces an empty plan, unknown channel IDs skipped, non-standard
  sections excluded, malformed docs rejected with useful messages, duplicate channel
  placements resolved first-wins.
- **`slack-autocomplete-electron-app.sh`** heredocs:
  - `main.js`: menu submenu + two `webContents.send` calls; `open-import` IPC handler.
  - `preload.js`: `export-sections` and `import-sections` IPC listeners following the
    existing export listeners' structure; small overlay extension for the Apply/Cancel
    confirmation state.

## Error handling

- No token/config found, no workspace in URL: same errors as existing exports.
- File dialog canceled: silent cleanup (overlay destroyed), like existing exports.
- Malformed/wrong-workspace file: overlay `fail` with the parse error; nothing mutated.
- Mid-execution failures: per-section, logged, execution continues, surfaced in summary.
- Cancel: AbortController wired to overlay Cancel, as in existing exports. Cancel during
  execution stops after the in-flight call; already-applied changes remain (documented in
  the overlay summary as partial).

## Non-goals

- Controlling section **order** in the sidebar (additive apply does not reorder).
- Updating emoji or renaming existing sections (emoji applies only on create).
- Deleting sections or removing channels from sections (no "full sync" mode).
- Cross-workspace import (workspace mismatch is a hard error).
- DM/system sections.
