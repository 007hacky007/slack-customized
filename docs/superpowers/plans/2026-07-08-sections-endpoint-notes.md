# users.channelSections.* endpoint shapes - live verification notes (2026-07-08)

Verified live against the running custom app (CDP `Runtime.evaluate` inside the
Slack page at `https://app.slack.com/client/<teamId>/...`), Task 1 of
`2026-07-08-channel-sections-export-import.md`. All identifying values below are
redacted: tokens and cookies are never shown, the workspace id is shown as
`T0XXXXXXX`, and real section/channel names are replaced with `redacted-N`
placeholders. Section ids (`L...`) and the one probe channel id are opaque and
kept as observed.

## Transport findings (matter for how the calls are made)

- All endpoints are plain `POST` with an `application/x-www-form-urlencoded`
  body; `token` (xoxc, from `localStorage.localConfig_v2` -> `teams[teamId].token`)
  goes in the body, `?slack_route=<teamId>` in the query string.
- The xoxc token alone is NOT enough: the session `d` cookie must accompany it.
  A page-context `fetch` to the workspace host (`https://<workspace>.slack.com/api/...`)
  without credentials returns `{"ok":false,"error":"invalid_auth"}`; with
  `credentials: 'include'` it dies on CORS (`TypeError: Failed to fetch`).
  Same-origin `https://app.slack.com/api/<method>?slack_route=<teamId>` works
  (cookies sent by default). The app's existing `slack-autocomplete:api-call`
  handler uses main-process `net.fetch` with the default cookie jar, which is
  not subject to page CORS, so either host works there.
- Every response carries `"warning":"superfluous_charset"` and
  `response_metadata.warnings` (caused by the `charset=utf-8` in the
  content type); harmless, ignore it.

## users.channelSections.list

Request params: `token` only (plus `slack_route` in the query).

Response (values redacted, structure exact):

```json
{
  "ok": true,
  "channel_sections": [
    {
      "channel_section_id": "L0BF4CMDZ5Y",
      "name": "redacted-1",
      "type": "standard",
      "emoji": "",
      "next_channel_section_id": "L07TS8PF1QX",
      "last_updated": 1783148050,
      "channel_ids_page": {
        "channel_ids": ["C0XXXXXXX", "C0XXXXXXX"],
        "count": 2,
        "cursor": "C0XXXXXXX"
      },
      "is_redacted": false
    }
  ],
  "count": 32,
  "cursor": "L08M7DN4ZT4",
  "entities": [],
  "last_updated": 1783148050,
  "warning": "superfluous_charset",
  "response_metadata": { "warnings": ["superfluous_charset"] }
}
```

Key observations:

- Key names match the plan assumptions: `channel_section_id` (not `id`),
  `name`, `emoji`, `type`, `channel_ids_page.channel_ids`.
- `type` values observed in this workspace: `standard` (all user-created
  sections), plus built-ins `stars` (NOT `starred`), `channels`,
  `direct_messages`, `slack_connect`, `recent_apps`, `agents`,
  `salesforce_records`. Only `standard` is user-created.
- Emoji is returned WITHOUT colons: `""` for none, `"wrench"`, `"cry"`,
  `"house_buildings"`, custom emoji names, and skin-tone variants as
  `"older_man::skin-tone-6"` (interior double colon, still no wrapping
  colons). Consequence: stripping ALL colons would corrupt skin-tone
  values; only wrapping colons may be stripped.
- `channel_ids_page.count` can EXCEED `channel_ids.length` (observed e.g.
  count 10 with 4 ids, count 7 with 3 ids, but also count 26 with 26 ids in
  the same response, so it is not a page-size cap). The surplus is almost
  certainly channels the user left or that were archived but are still
  assigned to the section; `channel_ids` matches what the sidebar shows.
  `channel_ids_page.cursor` is present whenever ids exist and equals the
  last id in the list; the built-in sections with 0 ids have no `cursor`
  key. Export should use `channel_ids` as-is and ignore `count`/`cursor`.
- The default `channels` bucket (type `channels`) returns an EMPTY
  `channel_ids_page` - unsectioned channels are not enumerated by this
  endpoint, confirming the plan's approach of computing "unsectioned" as
  member channels minus sectioned ids.
- Channel ids observed in sections here were `C...` and `G...`; `D...` ids
  are possible for DMs in sections (none present in this sidebar).
- Extra fields not in the plan assumptions (all ignorable):
  top-level `count` (number of sections), `cursor` (last section id),
  `entities`, `last_updated`; per section `next_channel_section_id`
  (sidebar ordering linked list), `last_updated`, `is_redacted`.

## users.channelSections.create

Request params sent: `token`, `name=zz-sections-verify`, `emoji=wrench`.

- FIRST ATTEMPT with the plan-assumed colon-wrapped form `emoji=:wrench:`
  FAILED: `{"ok":false,"error":"emoji_invalid",...}`.
- Bare emoji name `emoji=wrench` succeeded:

```json
{
  "ok": true,
  "channel_section_id": "L0BFZBYF7C1",
  "warning": "superfluous_charset",
  "response_metadata": { "warnings": ["superfluous_charset"] }
}
```

- The new section id lives at top-level `channel_section_id`, as assumed.
- A follow-up `list` showed the new section appended last
  (`next_channel_section_id: null`) with `emoji: "wrench"` echoed back bare.
- No-emoji create, verified live during the Task 9 smoke test (2026-07-08):
  OMITTING the `emoji` param fails with `invalid_arguments`; sending
  `emoji=""` (param present, empty string) succeeds. The `emoji` param is
  therefore mandatory and the client always sends it, empty when the
  section has no emoji.

## users.channelSections.channels.bulkUpdate

Insert probe params: `token`,
`insert=[{"channel_section_id":"L0BFZBYF7C1","channel_ids":["C064JKR09"]}]`,
`remove=[]`.

Response: `{"ok":true,"warning":"superfluous_charset",...}` - no other fields.

- `insert`/`remove` are JSON-encoded arrays of
  `{ channel_section_id, channel_ids: [...] }` passed as form-field string
  values, exactly as assumed.
- `remove=[]` (empty JSON array) is accepted.
- Follow-up `list` confirmed the channel appeared in the section
  (`channel_ids: ["C064JKR09"], count: 1`).

Remove probe params: `token`,
`remove=[{"channel_section_id":"L0BFZBYF7C1","channel_ids":["C064JKR09"]}]`,
with `insert` OMITTED entirely.

Response: `{"ok":true,...}` - so a missing `insert` (and by symmetry
`remove`) param is fine; empty-array and omitted are both acceptable.

## users.channelSections.delete

Request params: `token`, `channel_section_id=L0BFZBYF7C1`.

Response: `{"ok":true,"warning":"superfluous_charset",...}`.

## Cleanup verification

A final `users.channelSections.list` was diffed against the pre-probe
snapshot: identical 32 sections, no `zz-sections-verify`, no section's
name/emoji/type/channel_ids changed, and the probe channel `C064JKR09` is
back to unsectioned (not present in any section). Sidebar restored exactly.

## Deviations from the plan's assumed shapes (plan file amended accordingly)

1. `users.channelSections.create` takes a BARE emoji name (`wrench`);
   colon-wrapped `:wrench:` returns `emoji_invalid`. Task 8's create call
   was changed to send the stored bare emoji and to omit the param when
   there is none.
2. `list` returns emoji without wrapping colons, and skin-tone emoji
   contain an interior `::` (`older_man::skin-tone-6`). Task 2's
   `normalizeSections` was changed to strip only leading/trailing colons
   instead of all colons, with a test for the skin-tone form.
3. The built-in starred section's `type` is `stars`, not `starred`; test
   fixtures in Tasks 2, 3, 5 were updated for fidelity (behavior only ever
   branches on `type === 'standard'`, which is confirmed correct).
4. Everything else matched: response key names, where the created section
   id lives, bulkUpdate param encoding and `{ ok }` responses, delete
   params.
