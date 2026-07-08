# Channel Sections Export/Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export the user's Slack sidebar sections-to-channels mapping to a JSON file, and additively import such a file back (create missing sections, move channels into them).

**Architecture:** Pure logic (normalization, doc building, validation, plan computation) goes in `export-core.js` with `node:test` unit tests. Wiring (menu items, IPC handlers, renderer flows with progress overlay) goes into the `main.js` / `preload.js` heredocs inside `slack-autocomplete-electron-app.sh`, mirroring the existing "Export Channel List" feature line by line. Slack is driven through its undocumented client endpoints (`users.channelSections.list/create/channels.bulkUpdate`) via the existing `slack-autocomplete:api-call` IPC bridge.

**Tech Stack:** Electron (main + preload heredocs in a bash build script), plain Node.js CommonJS for `export-core.js`, `node:test` + `node:assert/strict` for tests.

**Spec:** `docs/superpowers/specs/2026-07-08-channel-sections-export-import-design.md` (read it before starting).

## Global Constraints

- Source of truth for app code is the heredocs in `slack-autocomplete-electron-app.sh`; never edit `~/SlackAutocompleteElectron/` directly.
- Pure functions in `export-core.js` must not touch DOM, IPC, fetch, `Date.now()` (take timestamps as inputs).
- Every new `ipcMain.handle` must start with the `isSlackSender(event)` check.
- Import is additive: never delete sections, never remove a channel from a section except as the "remove" half of a move the file requests.
- Import mutates nothing before the user clicks Apply in the overlay.
- File format: `format: "slack-sections-export"`, `version: 1`; import rejects `version > 1` with a "newer version of the app" error and rejects workspace-ID mismatches.
- No em-dashes or en-dashes anywhere (code, comments, docs); hyphen-minus only.
- Tests run with: `node --test test/export-core.test.js` from the repo root.
- Endpoint shapes (VERIFIED live by Task 1 on 2026-07-08; details in `2026-07-08-sections-endpoint-notes.md`):
  - `users.channelSections.list` -> `{ ok, channel_sections: [{ channel_section_id, name, emoji, type, channel_ids_page: { channel_ids: [...], count, cursor } }] }`; user-created sections have `type: "standard"` (built-ins observed: `stars`, `channels`, `direct_messages`, `slack_connect`, `recent_apps`, `agents`, `salesforce_records`). Emoji comes back WITHOUT wrapping colons (`""` for none; skin tones as `older_man::skin-tone-6` with an interior `::`). `channel_ids_page.count` may exceed `channel_ids.length` (left/archived channels); use `channel_ids` as-is. The default `channels` bucket returns no ids, so unsectioned channels must be computed as member channels minus sectioned ids.
  - `users.channelSections.create` params `name`, `emoji` (BARE emoji name, e.g. `wrench`; colon-wrapped `:wrench:` fails with `emoji_invalid`; the param is MANDATORY - omitting it fails with `invalid_arguments`, send `""` when there is no emoji) -> `{ ok, channel_section_id }`.
  - `users.channelSections.channels.bulkUpdate` params `insert`, `remove`, each a JSON-encoded array of `{ channel_section_id, channel_ids: [...] }` -> `{ ok }`; either param may be an empty array or omitted entirely.
  - `users.channelSections.delete` params `channel_section_id` -> `{ ok }` (used ONLY for Task 1 cleanup, never by the feature).

---

### Task 1: Verify users.channelSections.* endpoint shapes live

**Files:**
- Create: `docs/superpowers/plans/2026-07-08-sections-endpoint-notes.md` (verification findings)

**Interfaces:**
- Produces: confirmed request/response shapes for `users.channelSections.list`, `.create`, `.channels.bulkUpdate` (+ `.delete` for cleanup). Later tasks contain code written against the assumed shapes in Global Constraints; if reality differs, THIS task's findings amend the code blocks in Tasks 2, 7, and 8 before they are executed.

The custom app normally runs with `--remote-debugging-port=9222` (raw CDP; the chrome-devtools MCP is not attached to it). All calls run inside the Slack page context, so the page's own cookies apply; the xoxc token comes from `localStorage.localConfig_v2`.

- [x] **Step 1: Confirm the app is running with CDP available**

Run: `curl -s http://127.0.0.1:9222/json | head -40`
Expected: JSON array of targets; find the one whose `url` contains `app.slack.com/client` (or the workspace domain). Note its `webSocketDebuggerUrl`.
If the curl fails, ask the user to start `/Applications/SlackAutocompleteElectron.app` (it already ships with the debug port) and wait for it.

- [x] **Step 2: Write the CDP probe script**

Create `scratchpad/sections-probe.mjs` (in the session scratchpad directory, not the repo). Node 20+ has a global `WebSocket`.

```js
// Usage: node sections-probe.mjs <webSocketDebuggerUrl> <expression-file>
// Sends one Runtime.evaluate with the given JS expression (awaited) and prints the result.
const [wsUrl, exprFile] = process.argv.slice(2);
const fs = await import('node:fs');
const expression = fs.readFileSync(exprFile, 'utf8');
const ws = new WebSocket(wsUrl);
ws.onopen = () => ws.send(JSON.stringify({
  id: 1, method: 'Runtime.evaluate',
  params: { expression, awaitPromise: true, returnByValue: true }
}));
ws.onmessage = (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id === 1) {
    console.log(JSON.stringify(msg.result, null, 2));
    ws.close(); process.exit(0);
  }
};
setTimeout(() => { console.error('timeout'); process.exit(1); }, 30000);
```

- [x] **Step 3: Probe users.channelSections.list**

Create `scratchpad/expr-list.js`:

```js
(async () => {
  const cfg = JSON.parse(localStorage.getItem('localConfig_v2'));
  const teamId = (location.pathname.match(/^\/client\/(T[A-Z0-9]+)/) || [])[1]
    || Object.keys(cfg.teams)[0];
  const team = cfg.teams[teamId];
  const base = team.url; // e.g. https://<workspace>.slack.com/
  const body = new URLSearchParams({ token: team.token });
  const r = await fetch(base + 'api/users.channelSections.list?slack_route=' + teamId,
    { method: 'POST', body });
  return await r.text();
})()
```

Run: `node scratchpad/sections-probe.mjs "<webSocketDebuggerUrl>" scratchpad/expr-list.js`
Expected: JSON with `ok: true` and a `channel_sections` array. Record in the notes file: the exact key names (`channel_section_id` vs `id`), the `type` values present, how emoji is encoded (with or without colons), and where channel ids live (`channel_ids_page.channel_ids` or elsewhere).
If the fetch is blocked by CORS (page origin is `app.slack.com`, API host is the workspace domain), retry with `base = 'https://app.slack.com/'` if `cfg.teams[teamId]` has no url, or fall back to observing traffic: send `Network.enable` over the same WebSocket, ask the user to collapse/expand a section in the sidebar, and read the request/response of the `users.channelSections.list` call Slack itself makes.

- [x] **Step 4: Probe create, bulkUpdate, delete on a throwaway section**

Create `scratchpad/expr-create.js` (same structure as expr-list.js, body params: `name=zz-sections-verify`, `emoji=:wrench:`). Record the response shape (where the new section id is).
Then `scratchpad/expr-bulk.js`: pick one public channel id from the list probe's default "channels" bucket or from `unsectioned`, and send `insert=[{"channel_section_id":"<newId>","channel_ids":["<C...>"]}]` and `remove=[]` to `users.channelSections.channels.bulkUpdate`. Record whether `remove` may be empty/omitted and whether values must be JSON strings.
Then move it back out: `insert=[]`, `remove=[{"channel_section_id":"<newId>","channel_ids":["<C...>"]}]`.
Finally `scratchpad/expr-delete.js`: `users.channelSections.delete` with `channel_section_id=<newId>`. Verify via a final list probe that `zz-sections-verify` is gone and the moved channel is back where it was.

- [x] **Step 5: Write the findings file and reconcile the plan**

Write `docs/superpowers/plans/2026-07-08-sections-endpoint-notes.md` with: each endpoint, exact params sent, exact response received (redact tokens and real channel names if any). If any shape differs from the Global Constraints assumptions, update the affected code blocks in Tasks 2, 7, 8 of this plan file now, before those tasks run.

- [x] **Step 6: Commit**

```bash
git add docs/superpowers/plans/2026-07-08-sections-endpoint-notes.md docs/superpowers/plans/2026-07-08-channel-sections-export-import.md
git commit -m "docs: verified users.channelSections endpoint shapes"
```

---

### Task 2: export-core: normalizeSections

**Files:**
- Modify: `export-core.js` (add function + export)
- Test: `test/export-core.test.js` (append tests)

**Interfaces:**
- Consumes: raw `users.channelSections.list` response object (shape per Task 1).
- Produces: `normalizeSections(resp)` -> `[{ id: string, name: string, emoji: string|null, type: string, channelIds: string[] }]`. Throws `Error('users.channelSections.list failed: ...')` when `resp.ok === false` or resp is falsy. Emoji is stored WITHOUT colons; empty emoji becomes `null`.

- [ ] **Step 1: Write the failing tests**

Append to `test/export-core.test.js`:

```js
test('normalizeSections maps list response, strips only wrapping emoji colons', () => {
  // Live-verified: list returns emoji WITHOUT wrapping colons ('' for none),
  // and skin-tone emoji keep an interior '::' that must survive normalization.
  const resp = { ok: true, channel_sections: [
    { channel_section_id: 'S1', name: 'Infra', emoji: ':wrench:', type: 'standard',
      channel_ids_page: { channel_ids: ['C1', 'C2'], count: 2, cursor: 'C2' } },
    { channel_section_id: 'S2', name: 'Starred', emoji: '', type: 'stars',
      channel_ids_page: { channel_ids: [], count: 0 } },
    { channel_section_id: 'S3', name: 'People', emoji: 'older_man::skin-tone-6', type: 'standard',
      channel_ids_page: { channel_ids: ['C3'], count: 1, cursor: 'C3' } },
  ]};
  assert.deepEqual(core.normalizeSections(resp), [
    { id: 'S1', name: 'Infra', emoji: 'wrench', type: 'standard', channelIds: ['C1', 'C2'] },
    { id: 'S2', name: 'Starred', emoji: null, type: 'stars', channelIds: [] },
    { id: 'S3', name: 'People', emoji: 'older_man::skin-tone-6', type: 'standard', channelIds: ['C3'] },
  ]);
});

test('normalizeSections tolerates missing pieces and drops id-less entries', () => {
  const resp = { ok: true, channel_sections: [
    { channel_section_id: 'S1', type: 'standard' },
    { name: 'ghost', type: 'standard' },
  ]};
  assert.deepEqual(core.normalizeSections(resp), [
    { id: 'S1', name: '', emoji: null, type: 'standard', channelIds: [] },
  ]);
  assert.deepEqual(core.normalizeSections({ ok: true }), []);
});

test('normalizeSections throws on error responses', () => {
  assert.throws(() => core.normalizeSections({ ok: false, error: 'invalid_auth' }), /invalid_auth/);
  assert.throws(() => core.normalizeSections(null), /users\.channelSections\.list failed/);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --test test/export-core.test.js 2>&1 | tail -20`
Expected: the three new tests FAIL with `core.normalizeSections is not a function`.

- [ ] **Step 3: Implement normalizeSections**

In `export-core.js`, after `formatChannelListText` (around line 380), add:

```js
// ===================== Channel sections export/import =====================

// Normalizes a users.channelSections.list response into plain section objects.
// Live-verified: the API returns emoji WITHOUT wrapping colons already ("" for
// none, "wrench", skin tones as "older_man::skin-tone-6"). Strip only wrapping
// colons (defensive, e.g. ":wrench:" -> "wrench") so the interior "::" of a
// skin-tone emoji survives; empty -> null.
function normalizeSections(resp) {
  if (!resp || resp.ok === false) {
    throw new Error('users.channelSections.list failed: ' + (resp && resp.error));
  }
  const raw = Array.isArray(resp.channel_sections) ? resp.channel_sections : [];
  return raw
    .map((s) => ({
      id: (s && (s.channel_section_id || s.id)) || null,
      name: (s && typeof s.name === 'string') ? s.name : '',
      emoji: (s && typeof s.emoji === 'string' && s.emoji.replace(/^:+|:+$/g, '')) || null,
      type: (s && s.type) || 'standard',
      channelIds: (s && s.channel_ids_page && Array.isArray(s.channel_ids_page.channel_ids))
        ? s.channel_ids_page.channel_ids.slice()
        : ((s && Array.isArray(s.channel_ids)) ? s.channel_ids.slice() : []),
    }))
    .filter((s) => s.id);
}
```

Add `normalizeSections` to `module.exports` at the bottom of the file (append to the existing object; a new line grouping the sections functions is fine).

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test test/export-core.test.js 2>&1 | tail -5`
Expected: all tests pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: normalizeSections parses users.channelSections.list responses"
```

---

### Task 3: export-core: sections doc constants + buildSectionsDoc

**Files:**
- Modify: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Consumes: `normalizeSections` output; member channel objects `{ id, name, is_private }` from the existing `fetchAllMemberChannels`.
- Produces:
  - `SECTIONS_EXPORT_FORMAT` = `'slack-sections-export'`, `SECTIONS_EXPORT_VERSION` = `1` (exported constants).
  - `buildSectionsDoc(sections, channels, ctx)` -> the export doc. `ctx = { exportedAt: string, teamId: string, workspace: { team_id, name } }` (workspace as returned by the existing `workspaceFromConfig`). Only `type === 'standard'` sections are included. Doc contains `format`, `version`, `exportedAt`, `workspace: { id, name }`, `instructions` (string[]), `schema` (object), `sections`, `unsectioned`.

- [ ] **Step 1: Write the failing tests**

Append to `test/export-core.test.js`:

```js
test('buildSectionsDoc builds doc with standard sections, unsectioned, schema and instructions', () => {
  const sections = [
    { id: 'S1', name: 'Infra', emoji: 'wrench', type: 'standard', channelIds: ['C1', 'D9'] },
    { id: 'S2', name: 'Starred', emoji: null, type: 'stars', channelIds: ['C2'] },
  ];
  const channels = [
    { id: 'C1', name: 'backbone', is_private: false },
    { id: 'C2', name: 'dns', is_private: false },
    { id: 'C3', name: 'random', is_private: false },
  ];
  const doc = core.buildSectionsDoc(sections, channels, {
    exportedAt: '2026-07-08T12:00:00.000Z', teamId: 'T123',
    workspace: { team_id: 'T123', name: 'acme' },
  });
  assert.equal(doc.format, 'slack-sections-export');
  assert.equal(doc.version, 1);
  assert.equal(doc.exportedAt, '2026-07-08T12:00:00.000Z');
  assert.deepEqual(doc.workspace, { id: 'T123', name: 'acme' });
  assert.ok(Array.isArray(doc.instructions) && doc.instructions.length >= 5);
  assert.equal(doc.schema.properties.format.const, 'slack-sections-export');
  // starred section excluded; D9 kept with null name (not a member channel)
  assert.deepEqual(doc.sections, [
    { name: 'Infra', emoji: 'wrench', channels: [
      { id: 'C1', name: 'backbone' }, { id: 'D9', name: null } ] },
  ]);
  // C2 is only in a non-standard section, so it counts as unsectioned
  assert.deepEqual(doc.unsectioned, [
    { id: 'C2', name: 'dns' }, { id: 'C3', name: 'random' },
  ]);
});

```

- [ ] **Step 2: Run tests to verify the new one fails**

Run: `node --test test/export-core.test.js 2>&1 | tail -20`
Expected: `buildSectionsDoc...` FAILS with `core.buildSectionsDoc is not a function`.

- [ ] **Step 3: Implement constants and buildSectionsDoc**

In `export-core.js`, below `normalizeSections`, add:

```js
const SECTIONS_EXPORT_FORMAT = 'slack-sections-export';
const SECTIONS_EXPORT_VERSION = 1;

// Baked into every exported file so a human or an LLM editing it has the
// contract inline. Import ignores these fields (it has its own validation).
const SECTIONS_EXPORT_INSTRUCTIONS = [
  "This file maps Slack sidebar sections to channels. To reorganize, move channel objects between the 'channels' arrays of sections, or from 'unsectioned' into a section.",
  "To create a new section, add an object to 'sections' with a 'name', an optional 'emoji' (emoji name without colons), and a 'channels' array.",
  "Channels are matched by 'id' on import; 'name' is informational only. Do not invent channel ids.",
  "Import is additive: it creates missing sections and moves the listed channels into them. It never deletes sections or removes channels from sections. Channels left in 'unsectioned' are ignored on import.",
  "Each channel id should appear at most once across all sections; if it appears more than once, the first placement wins.",
  "Do not modify 'format', 'version', 'workspace', or 'schema'.",
];

const SECTIONS_EXPORT_SCHEMA = {
  $schema: 'http://json-schema.org/draft-07/schema#',
  type: 'object',
  required: ['format', 'version', 'workspace', 'sections'],
  properties: {
    format: { const: SECTIONS_EXPORT_FORMAT },
    version: { type: 'integer' },
    exportedAt: { type: 'string' },
    workspace: {
      type: 'object',
      required: ['id'],
      properties: { id: { type: 'string' }, name: { type: 'string' } },
    },
    instructions: { type: 'array', items: { type: 'string' } },
    sections: {
      type: 'array',
      items: {
        type: 'object',
        required: ['name', 'channels'],
        properties: {
          name: { type: 'string', minLength: 1 },
          emoji: { type: ['string', 'null'] },
          channels: { $ref: '#/definitions/channelList' },
        },
      },
    },
    unsectioned: { $ref: '#/definitions/channelList' },
  },
  definitions: {
    channelList: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id'],
        properties: {
          id: { type: 'string', pattern: '^[CDG][A-Z0-9]+$' },
          name: { type: ['string', 'null'] },
        },
      },
    },
  },
};

function buildSectionsDoc(sections, channels, ctx) {
  ctx = ctx || {};
  const standard = (sections || []).filter((s) => s.type === 'standard');
  const nameById = new Map((channels || []).map((c) => [c.id, c.name || null]));
  const sectioned = new Set();
  const outSections = standard.map((s) => ({
    name: s.name,
    emoji: s.emoji || null,
    channels: s.channelIds.map((id) => {
      sectioned.add(id);
      return { id, name: nameById.get(id) || null };
    }),
  }));
  const unsectioned = (channels || [])
    .filter((c) => !sectioned.has(c.id))
    .map((c) => ({ id: c.id, name: c.name || null }));
  return {
    format: SECTIONS_EXPORT_FORMAT,
    version: SECTIONS_EXPORT_VERSION,
    exportedAt: ctx.exportedAt || null,
    workspace: {
      id: ctx.teamId || null,
      name: (ctx.workspace && ctx.workspace.name) || null,
    },
    instructions: SECTIONS_EXPORT_INSTRUCTIONS.slice(),
    schema: SECTIONS_EXPORT_SCHEMA,
    sections: outSections,
    unsectioned,
  };
}
```

Add to `module.exports`: `SECTIONS_EXPORT_FORMAT, SECTIONS_EXPORT_VERSION, buildSectionsDoc` (on the same new line as `normalizeSections`).

- [ ] **Step 4: Run tests**

Run: `node --test test/export-core.test.js 2>&1 | tail -10`
Expected: all tests pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: buildSectionsDoc with embedded schema and LLM editing instructions"
```

---

### Task 4: export-core: parseSectionsDoc

**Files:**
- Modify: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Consumes: raw file text, current team id string.
- Produces: `parseSectionsDoc(text, currentTeamId)` -> parsed doc object. Throws `Error` with a user-facing message on: invalid JSON, wrong `format`, missing/non-integer `version`, `version > SECTIONS_EXPORT_VERSION`, missing `workspace.id`, workspace mismatch (when `currentTeamId` is truthy), missing/malformed `sections`, section without a non-blank `name`, non-array `channels`, channel id failing `/^[CDG][A-Z0-9]+$/`. Embedded `instructions`/`schema` are ignored entirely.

- [ ] **Step 1: Write the failing tests**

Append to `test/export-core.test.js`:

```js
function validSectionsDoc() {
  return {
    format: 'slack-sections-export', version: 1,
    workspace: { id: 'T123', name: 'acme' },
    sections: [
      { name: 'Infra', emoji: 'wrench', channels: [{ id: 'C0AAA', name: 'backbone' }] },
    ],
    unsectioned: [{ id: 'C0CCC', name: 'random' }],
  };
}

test('parseSectionsDoc accepts a valid doc', () => {
  const doc = core.parseSectionsDoc(JSON.stringify(validSectionsDoc()), 'T123');
  assert.equal(doc.sections[0].name, 'Infra');
});

test('parseSectionsDoc rejects bad json, format, version', () => {
  assert.throws(() => core.parseSectionsDoc('{nope', 'T123'), /JSON/);
  const wrongFormat = Object.assign(validSectionsDoc(), { format: 'other' });
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(wrongFormat), 'T123'), /format/);
  const newer = Object.assign(validSectionsDoc(), { version: 2 });
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(newer), 'T123'), /newer version/);
  const noVersion = validSectionsDoc(); delete noVersion.version;
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(noVersion), 'T123'), /version/);
});

test('parseSectionsDoc rejects workspace mismatch and missing workspace', () => {
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(validSectionsDoc()), 'T999'), /Workspace mismatch/);
  const noWs = validSectionsDoc(); delete noWs.workspace;
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(noWs), 'T123'), /workspace/);
  // no currentTeamId -> mismatch check skipped
  assert.ok(core.parseSectionsDoc(JSON.stringify(validSectionsDoc()), null));
});

test('parseSectionsDoc round-trips a buildSectionsDoc export', () => {
  const doc = core.buildSectionsDoc(
    [{ id: 'S1', name: 'A', emoji: null, type: 'standard', channelIds: ['C1'] }],
    [{ id: 'C1', name: 'one', is_private: false }],
    { exportedAt: 'x', teamId: 'T123', workspace: { team_id: 'T123', name: 'acme' } });
  const parsed = core.parseSectionsDoc(JSON.stringify(doc), 'T123');
  assert.equal(parsed.sections.length, 1);
});

test('parseSectionsDoc rejects malformed sections and channel ids', () => {
  const noName = validSectionsDoc(); noName.sections[0].name = '  ';
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(noName), 'T123'), /name/);
  const badId = validSectionsDoc(); badId.sections[0].channels[0].id = 'lowercase';
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(badId), 'T123'), /channel id/);
  const noChannels = validSectionsDoc(); delete noChannels.sections[0].channels;
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(noChannels), 'T123'), /channels/);
  const notArray = Object.assign(validSectionsDoc(), { sections: 'x' });
  assert.throws(() => core.parseSectionsDoc(JSON.stringify(notArray), 'T123'), /sections/);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --test test/export-core.test.js 2>&1 | tail -20`
Expected: the five new tests FAIL with `core.parseSectionsDoc is not a function`.

- [ ] **Step 3: Implement parseSectionsDoc**

In `export-core.js`, below `buildSectionsDoc`, add:

```js
const SECTIONS_CHANNEL_ID_RE = /^[CDG][A-Z0-9]+$/;

// Validates an imported sections file. Throws Error with a user-facing message.
// The embedded `instructions` and `schema` fields are intentionally ignored.
function parseSectionsDoc(text, currentTeamId) {
  let doc;
  try {
    doc = JSON.parse(text);
  } catch (e) {
    throw new Error('Not valid JSON: ' + e.message);
  }
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) {
    throw new Error('Not a sections export (expected a JSON object).');
  }
  if (doc.format !== SECTIONS_EXPORT_FORMAT) {
    throw new Error('Not a sections export (expected format "' + SECTIONS_EXPORT_FORMAT + '").');
  }
  if (!Number.isInteger(doc.version)) {
    throw new Error('Missing or invalid "version" (integer required).');
  }
  if (doc.version > SECTIONS_EXPORT_VERSION) {
    throw new Error('This file was created by a newer version of the app (file version '
      + doc.version + ', supported up to ' + SECTIONS_EXPORT_VERSION + ').');
  }
  if (!doc.workspace || typeof doc.workspace.id !== 'string' || !doc.workspace.id) {
    throw new Error('Missing "workspace.id".');
  }
  if (currentTeamId && doc.workspace.id !== currentTeamId) {
    throw new Error('Workspace mismatch: file is for ' + doc.workspace.id
      + (doc.workspace.name ? ' (' + doc.workspace.name + ')' : '')
      + ', current workspace is ' + currentTeamId + '.');
  }
  if (!Array.isArray(doc.sections)) {
    throw new Error('Missing "sections" array.');
  }
  doc.sections.forEach((s, i) => {
    const where = 'sections[' + i + ']';
    if (!s || typeof s !== 'object' || Array.isArray(s)) throw new Error(where + ' is not an object.');
    if (typeof s.name !== 'string' || !s.name.trim()) throw new Error(where + ' has no name.');
    if (s.emoji != null && typeof s.emoji !== 'string') throw new Error(where + ' ("' + s.name + '"): emoji must be a string or null.');
    if (!Array.isArray(s.channels)) throw new Error(where + ' ("' + s.name + '") has no channels array.');
    s.channels.forEach((c, j) => {
      if (!c || typeof c.id !== 'string' || !SECTIONS_CHANNEL_ID_RE.test(c.id)) {
        throw new Error(where + ' ("' + s.name + '") channels[' + j + '] has a bad channel id'
          + (c && typeof c.id === 'string' ? ': "' + c.id + '"' : '.'));
      }
    });
  });
  return doc;
}
```

Add `parseSectionsDoc` to `module.exports`.

- [ ] **Step 4: Run tests**

Run: `node --test test/export-core.test.js 2>&1 | tail -5`
Expected: ALL tests pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: parseSectionsDoc validates imported sections files (format, version, workspace)"
```

---

### Task 5: export-core: computeSectionsImportPlan

**Files:**
- Modify: `export-core.js`
- Test: `test/export-core.test.js`

**Interfaces:**
- Consumes: parsed doc (from `parseSectionsDoc`), current sections (from `normalizeSections`), member channels (from `fetchAllMemberChannels`).
- Produces: `computeSectionsImportPlan(doc, currentSections, memberChannels)` ->

```js
{
  create: [{ name, emoji }],            // sections in the file with no existing standard section of that exact (trimmed) name
  moves: [{                             // one entry per file section that has channels to place
    sectionName,                        // trimmed name, used to look up ids of just-created sections
    sectionId,                          // existing standard section id, or null when the section is in `create`
    insertChannelIds: [...],
    removeGroups: [{ sectionId, channelIds }],  // the "remove from old section" half of each move
  }],
  skips: [{ channelId, name, reason }],
  counts: { create, move, skip },       // move = total inserted channel ids
}
```

Rules: sections matched by exact trimmed name against standard sections only (first match wins). A channel id is placeable when it is a member channel OR currently present in any section (covers DMs in sections). Channels are removed only from standard sections they currently sit in. Skip reasons: duplicate placement (first wins), unknown channel, already in the target section. Idempotence: importing an unmodified export yields empty `create`/`moves`.

- [ ] **Step 1: Write the failing tests**

Append to `test/export-core.test.js`:

```js
const PLAN_CURRENT = () => [
  { id: 'S1', name: 'Infra', emoji: 'wrench', type: 'standard', channelIds: ['C1'] },
  { id: 'S2', name: 'Team', emoji: null, type: 'standard', channelIds: ['C2'] },
  { id: 'SSTAR', name: 'Starred', emoji: null, type: 'stars', channelIds: ['C3'] },
];
const PLAN_MEMBERS = () => [
  { id: 'C1', name: 'backbone' }, { id: 'C2', name: 'dns' },
  { id: 'C3', name: 'alerts' }, { id: 'C4', name: 'random' },
];

test('computeSectionsImportPlan: idempotent re-import is an empty plan', () => {
  const doc = { sections: [
    { name: 'Infra', emoji: 'wrench', channels: [{ id: 'C1', name: 'backbone' }] },
    { name: 'Team', emoji: null, channels: [{ id: 'C2', name: 'dns' }] },
  ]};
  const plan = core.computeSectionsImportPlan(doc, PLAN_CURRENT(), PLAN_MEMBERS());
  assert.deepEqual(plan.create, []);
  assert.deepEqual(plan.moves, []);
  assert.equal(plan.counts.move, 0);
  assert.equal(plan.skips.length, 2); // both "already in" skips
  assert.match(plan.skips[0].reason, /already in/);
});

test('computeSectionsImportPlan: creates missing sections and moves channels', () => {
  const doc = { sections: [
    { name: 'New Stuff', emoji: 'tada', channels: [
      { id: 'C2', name: 'dns' },   // currently in S2 -> move with remove
      { id: 'C4', name: 'random' } // unsectioned -> insert only
    ]},
  ]};
  const plan = core.computeSectionsImportPlan(doc, PLAN_CURRENT(), PLAN_MEMBERS());
  assert.deepEqual(plan.create, [{ name: 'New Stuff', emoji: 'tada' }]);
  assert.deepEqual(plan.moves, [{
    sectionName: 'New Stuff', sectionId: null,
    insertChannelIds: ['C2', 'C4'],
    removeGroups: [{ sectionId: 'S2', channelIds: ['C2'] }],
  }]);
  assert.deepEqual(plan.counts, { create: 1, move: 2, skip: 0 });
});

test('computeSectionsImportPlan: moving into an existing section by name', () => {
  const doc = { sections: [
    { name: 'Infra', emoji: null, channels: [{ id: 'C2', name: 'dns' }] },
  ]};
  const plan = core.computeSectionsImportPlan(doc, PLAN_CURRENT(), PLAN_MEMBERS());
  assert.deepEqual(plan.create, []);
  assert.deepEqual(plan.moves, [{
    sectionName: 'Infra', sectionId: 'S1',
    insertChannelIds: ['C2'],
    removeGroups: [{ sectionId: 'S2', channelIds: ['C2'] }],
  }]);
});

test('computeSectionsImportPlan: skips unknown channels and duplicates (first wins)', () => {
  const doc = { sections: [
    { name: 'A', emoji: null, channels: [{ id: 'C4', name: 'random' }, { id: 'C0NOPE', name: 'gone' }] },
    { name: 'B', emoji: null, channels: [{ id: 'C4', name: 'random' }] },
  ]};
  const plan = core.computeSectionsImportPlan(doc, PLAN_CURRENT(), PLAN_MEMBERS());
  assert.deepEqual(plan.create.map((c) => c.name), ['A', 'B']); // B still created (empty)
  assert.equal(plan.moves.length, 1);
  assert.deepEqual(plan.moves[0].insertChannelIds, ['C4']);
  assert.equal(plan.skips.length, 2);
  assert.match(plan.skips.find((s) => s.channelId === 'C0NOPE').reason, /not a member|unknown/i);
  assert.match(plan.skips.find((s) => s.channelId === 'C4').reason, /more than once/);
});

test('computeSectionsImportPlan: channel only known from a section (e.g. a DM) is movable; starred is never a remove source', () => {
  const doc = { sections: [
    { name: 'Infra', emoji: null, channels: [{ id: 'C3', name: 'alerts' }, { id: 'D7', name: null }] },
  ]};
  const current = PLAN_CURRENT();
  current.push({ id: 'S3', name: 'Misc', emoji: null, type: 'standard', channelIds: ['D7'] });
  const plan = core.computeSectionsImportPlan(doc, current, PLAN_MEMBERS());
  assert.deepEqual(plan.moves[0].insertChannelIds, ['C3', 'D7']);
  // C3 sits only in the starred (non-standard) section: insert without removing from Starred
  assert.deepEqual(plan.moves[0].removeGroups, [{ sectionId: 'S3', channelIds: ['D7'] }]);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --test test/export-core.test.js 2>&1 | tail -20`
Expected: the five new tests FAIL with `core.computeSectionsImportPlan is not a function`.

- [ ] **Step 3: Implement computeSectionsImportPlan**

In `export-core.js`, below `parseSectionsDoc`, add:

```js
// Computes the additive plan for applying an imported sections doc.
// Never plans deletions; channels are only removed from a standard section
// as the "remove" half of a move requested by the file.
function computeSectionsImportPlan(doc, currentSections, memberChannels) {
  const standard = (currentSections || []).filter((s) => s.type === 'standard');
  const sectionIdByName = new Map();
  for (const s of standard) {
    if (!sectionIdByName.has(s.name)) sectionIdByName.set(s.name, s.id);
  }
  // channel id -> the standard section it currently sits in (remove source)
  const currentSectionByChannel = new Map();
  for (const s of standard) {
    for (const id of s.channelIds) {
      if (!currentSectionByChannel.has(id)) currentSectionByChannel.set(id, s.id);
    }
  }
  // A channel is placeable if we are a member of it or it already sits in any
  // section (covers DMs/group DMs that users.conversations does not return).
  const known = new Set((memberChannels || []).map((c) => c.id));
  for (const s of (currentSections || [])) for (const id of s.channelIds) known.add(id);

  const create = [];
  const moves = [];
  const skips = [];
  const seen = new Set();
  for (const fileSection of (doc.sections || [])) {
    const name = fileSection.name.trim();
    const targetId = sectionIdByName.get(name) || null;
    if (!targetId) create.push({ name, emoji: fileSection.emoji || null });
    const insertChannelIds = [];
    const removeBySection = new Map();
    for (const ch of (fileSection.channels || [])) {
      if (seen.has(ch.id)) {
        skips.push({ channelId: ch.id, name: ch.name || null, reason: 'listed more than once; first placement wins' });
        continue;
      }
      seen.add(ch.id);
      if (!known.has(ch.id)) {
        skips.push({ channelId: ch.id, name: ch.name || null, reason: 'not a member of this channel (unknown id)' });
        continue;
      }
      const from = currentSectionByChannel.get(ch.id) || null;
      if (targetId && from === targetId) {
        skips.push({ channelId: ch.id, name: ch.name || null, reason: 'already in "' + name + '"' });
        continue;
      }
      insertChannelIds.push(ch.id);
      if (from) {
        if (!removeBySection.has(from)) removeBySection.set(from, []);
        removeBySection.get(from).push(ch.id);
      }
    }
    if (insertChannelIds.length) {
      moves.push({
        sectionName: name,
        sectionId: targetId,
        insertChannelIds,
        removeGroups: Array.from(removeBySection, ([sectionId, channelIds]) => ({ sectionId, channelIds })),
      });
    }
  }
  const moveCount = moves.reduce((n, m) => n + m.insertChannelIds.length, 0);
  return {
    create, moves, skips,
    counts: { create: create.length, move: moveCount, skip: skips.length },
  };
}
```

Add `computeSectionsImportPlan` to `module.exports`.

- [ ] **Step 4: Run tests**

Run: `node --test test/export-core.test.js 2>&1 | tail -5`
Expected: all tests pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add export-core.js test/export-core.test.js
git commit -m "feat: computeSectionsImportPlan - additive, idempotent sections import planning"
```

---

### Task 6: main.js: Channel Sections menu + open-import IPC handler

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (the `main.js` heredoc; menu template around line 616-641, IPC handlers area around line 1651-1660)

**Interfaces:**
- Consumes: nothing new.
- Produces: IPC events `slack-autocomplete:export-sections` and `slack-autocomplete:import-sections` sent to the focused window (Task 7/8 listen for them); `ipcMain.handle('slack-autocomplete:open-import')` returning `{ canceled: true }` or `{ ok: true, path, content }` (rejects files over 5 MB).

- [ ] **Step 1: Add the Channel Sections submenu**

In `slack-autocomplete-electron-app.sh`, inside the File menu template, directly AFTER the `Export Channel List` submenu's closing `},` (the line after `label: 'All Channels...'` block closes, currently line 640) and BEFORE the `{ type: 'separator' },` that precedes the close/quit role, insert:

```js
        {
          label: 'Channel Sections',
          submenu: [
            {
              label: 'Export Sections...',
              click: (_item, focusedWindow) => {
                const w = focusedWindow || BrowserWindow.getFocusedWindow();
                if (w) w.webContents.send('slack-autocomplete:export-sections');
              }
            },
            {
              label: 'Import Sections...',
              click: (_item, focusedWindow) => {
                const w = focusedWindow || BrowserWindow.getFocusedWindow();
                if (w) w.webContents.send('slack-autocomplete:import-sections');
              }
            }
          ]
        },
```

- [ ] **Step 2: Add the open-import IPC handler**

In the same heredoc, after the `slack-autocomplete:save-export:abort` handler (around line 1659) and before the `slack-autocomplete:open-external` handler, insert:

```js
// Sections import: file-open dialog + size-capped read, all in the main
// process so the renderer never touches the filesystem.
ipcMain.handle('slack-autocomplete:open-import', async (event) => {
  if (!isSlackSender(event)) throw new Error('import rejected: untrusted sender');
  const win = BrowserWindow.fromWebContents(event.sender);
  const res = await dialog.showOpenDialog(win, {
    defaultPath: app.getPath('downloads'),
    filters: [{ name: 'JSON', extensions: ['json'] }],
    properties: ['openFile']
  });
  if (res.canceled || !res.filePaths || !res.filePaths[0]) return { canceled: true };
  const filePath = res.filePaths[0];
  const st = await fs.promises.stat(filePath);
  if (st.size > 5 * 1024 * 1024) throw new Error('File too large (max 5 MB).');
  const content = await fs.promises.readFile(filePath, 'utf8');
  return { ok: true, path: filePath, content };
});
```

(`dialog`, `fs`, `app`, `BrowserWindow` are already imported at the top of the heredoc; verify with a grep before assuming, e.g. `grep -n "dialog," slack-autocomplete-electron-app.sh | head -3`.)

- [ ] **Step 3: Syntax-check the generated main.js**

Run:

```bash
bash -n slack-autocomplete-electron-app.sh
```

Expected: no output (bash syntax OK). Then extract and check the generated JS without running the full build: the heredoc writes `main.js` into `~/SlackAutocompleteElectron/`. If a previous build exists there, regenerate ONLY by running the script is slow; instead do a targeted check:

```bash
awk "/^cat > main.js <<'EOF'\$/{flag=1;next} /^EOF\$/{if(flag){exit}} flag" slack-autocomplete-electron-app.sh > /tmp/main-check.js && node --check /tmp/main-check.js && echo MAIN_OK
```

Expected: `MAIN_OK`. (The heredoc opener is exactly `cat > main.js <<'EOF'` at line 122; if it has moved, adjust the pattern; do not skip this check.)

- [ ] **Step 4: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: Channel Sections menu + open-import IPC handler"
```

---

### Task 7: preload.js: Export Sections flow

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (the `preload.js` heredoc; add a listener after the `export-channel-list` listener, around line 4697)

**Interfaces:**
- Consumes: `slack-autocomplete:export-sections` IPC event (Task 6); `exportCore.normalizeSections`, `exportCore.buildSectionsDoc`, `exportCore.fetchAllMemberChannels`, `exportCore.workspaceFromConfig` (Tasks 2-3); existing preload helpers `getExportConfig`, `createApiCall`, `createExportOverlay`, `exportTsStamp`, `phaseLabel`, `exportInProgress`, and the `save-export:begin/write/commit/abort` IPC flow.
- Produces: working "File -> Channel Sections -> Export Sections..." end to end.

- [ ] **Step 1: Add the export-sections listener**

In the preload heredoc, after the `export-channel-list` listener's closing `});` (the line before `// =================== end channel list export ===================`), insert:

```js
  // ===================== Channel sections export (web API) =====================
  ipcRenderer.on('slack-autocomplete:export-sections', async () => {
    if (exportInProgress) return;
    exportInProgress = true;
    const overlay = createExportOverlay('Exporting channel sections...');
    const log = (msg) => { try { console.log('[slack-sections]', msg); } catch (e) {} overlay.appendLog(msg); };
    const ac = new AbortController();
    overlay.onCancel(() => { log('cancel requested'); ac.abort(); });
    let saveToken = null;
    try {
      log('starting sections export');
      const cfg = getExportConfig(log, { requireChannel: false });
      const apiCall = createApiCall(cfg, ac.signal, log);
      const workspace = exportCore.workspaceFromConfig(cfg.localConfigRaw, cfg.teamId);

      overlay.setPhase('Fetching sections...');
      const listResp = await apiCall('users.channelSections.list', {});
      const sections = exportCore.normalizeSections(listResp);
      log('sections: ' + sections.filter((s) => s.type === 'standard').length
        + ' custom of ' + sections.length + ' total');

      const channels = await exportCore.fetchAllMemberChannels(apiCall,
        { types: 'public_channel,private_channel' }, {
          signal: ac.signal,
          onProgress: (p, cur, total) => {
            overlay.setProgress(phaseLabel(p), cur, total);
            log(phaseLabel(p) + ': ' + cur + ' so far');
          },
        });
      log('fetched ' + channels.length + ' member channels');

      const doc = exportCore.buildSectionsDoc(sections, channels, {
        exportedAt: new Date().toISOString(), teamId: cfg.teamId, workspace,
      });
      log('doc: ' + doc.sections.length + ' sections, ' + doc.unsectioned.length + ' unsectioned');

      const suggested = 'slack-sections-' + (workspace.name || cfg.teamId) + '-' + exportTsStamp() + '.json';
      log('choosing save destination...');
      const begin = await ipcRenderer.invoke('slack-autocomplete:save-export:begin', { suggestedName: suggested });
      if (begin && begin.canceled) { log('save dialog canceled'); overlay.destroy(); return; }
      saveToken = begin.token;

      overlay.setPhase('Saving file...');
      await ipcRenderer.invoke('slack-autocomplete:save-export:write', {
        token: saveToken, chunk: JSON.stringify(doc, null, 2) + '\n',
      });
      const res = await ipcRenderer.invoke('slack-autocomplete:save-export:commit', { token: saveToken });
      log('saved: ' + res.path);
      overlay.done('Saved ' + doc.sections.length + ' sections ('
        + doc.unsectioned.length + ' unsectioned channels) to ' + res.path);
    } catch (e) {
      log('FAILED: ' + ((e && e.message) || e));
      if (saveToken) { try { await ipcRenderer.invoke('slack-autocomplete:save-export:abort', { token: saveToken }); } catch (e2) { /* ignore */ } }
      if (e && e.name === 'AbortError') overlay.done('Export canceled.');
      else overlay.fail(String((e && e.message) || e));
    } finally {
      exportInProgress = false;
    }
  });
  // =================== end channel sections export ===================
```

- [ ] **Step 2: Syntax-check the generated preload.js**

```bash
bash -n slack-autocomplete-electron-app.sh
awk "/^cat > preload.js <<'EOF'\$/{flag=1;next} /^EOF\$/{if(flag){exit}} flag" slack-autocomplete-electron-app.sh > /tmp/preload-check.js && node --check /tmp/preload-check.js && echo PRELOAD_OK
```

Expected: `PRELOAD_OK` (adjust the awk marker to the actual `cat >` line if needed; do not skip).

- [ ] **Step 3: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: Export Sections flow in preload (sections + unsectioned channels to JSON)"
```

---

### Task 8: preload.js: overlay confirm() + Import Sections flow

**Files:**
- Modify: `slack-autocomplete-electron-app.sh` (preload heredoc: `createExportOverlay` around line 4509, and a new listener after the export-sections listener from Task 7)

**Interfaces:**
- Consumes: `slack-autocomplete:import-sections` IPC event and `slack-autocomplete:open-import` handler (Task 6); `exportCore.parseSectionsDoc`, `exportCore.computeSectionsImportPlan`, `exportCore.normalizeSections`, `exportCore.fetchAllMemberChannels` (Tasks 2, 4, 5); existing preload helpers as in Task 7.
- Produces: `overlay.confirm(text)` -> `Promise<boolean>` (Apply = true, Cancel = false); working "File -> Channel Sections -> Import Sections..." end to end with an Apply/Cancel gate before any mutation.

- [ ] **Step 1: Add confirm() to createExportOverlay**

Inside `createExportOverlay`, in the returned object (after the `setProgress` method, before `done`), add:

```js
      // Plan confirmation gate: shows an Apply button next to Cancel and
      // resolves true (Apply) or false (Cancel). Nothing is mutated before Apply.
      confirm(text) {
        phase.textContent = text;
        barDeterminate(0);
        return new Promise((resolve) => {
          const applyBtn = document.createElement('button');
          applyBtn.textContent = 'Apply';
          applyBtn.style.cssText = 'background:#007a5a;color:#fff;border:0;border-radius:6px;padding:7px 14px;cursor:pointer;font-size:13px;margin-right:8px;';
          box.insertBefore(applyBtn, cancelBtn);
          applyBtn.addEventListener('click', () => { applyBtn.remove(); resolve(true); });
          const prevCancel = cancelCb;
          cancelCb = () => { applyBtn.remove(); resolve(false); if (prevCancel) prevCancel(); };
        });
      },
```

- [ ] **Step 2: Add the import-sections listener**

After the export-sections listener from Task 7 (before its `// =================== end` comment or right after it), insert:

```js
  // ===================== Channel sections import (web API) =====================
  // Additive apply: creates missing sections, moves listed channels into them.
  // Never deletes anything. Nothing is mutated before the user clicks Apply.
  ipcRenderer.on('slack-autocomplete:import-sections', async () => {
    if (exportInProgress) return;
    exportInProgress = true;
    const overlay = createExportOverlay('Importing channel sections...', { noun: 'Import' });
    const log = (msg) => { try { console.log('[slack-sections]', msg); } catch (e) {} overlay.appendLog(msg); };
    const ac = new AbortController();
    overlay.onCancel(() => { log('cancel requested'); ac.abort(); });
    // Once true, a cancel may leave changes applied; stays false during the read-only phase.
    let mutationStarted = false;
    try {
      const picked = await ipcRenderer.invoke('slack-autocomplete:open-import');
      if (picked && picked.canceled) { overlay.destroy(); return; }
      log('file: ' + picked.path);

      const cfg = getExportConfig(log, { requireChannel: false });
      const apiCall = createApiCall(cfg, ac.signal, log);
      const doc = exportCore.parseSectionsDoc(picked.content, cfg.teamId);
      log('file ok: ' + doc.sections.length + ' sections (version ' + doc.version + ')');

      overlay.setPhase('Fetching current sections...');
      const currentSections = exportCore.normalizeSections(await apiCall('users.channelSections.list', {}));
      const channels = await exportCore.fetchAllMemberChannels(apiCall,
        { types: 'public_channel,private_channel' }, {
          signal: ac.signal,
          onProgress: (p, cur, total) => {
            overlay.setProgress(phaseLabel(p), cur, total);
            log(phaseLabel(p) + ': ' + cur + ' so far');
          },
        });

      const plan = exportCore.computeSectionsImportPlan(doc, currentSections, channels);
      for (const s of plan.skips) {
        log('skip ' + (s.name ? '#' + s.name : s.channelId) + ': ' + s.reason);
      }
      log('plan: create ' + plan.counts.create + ' sections, move '
        + plan.counts.move + ' channels, skip ' + plan.counts.skip);

      if (plan.counts.create === 0 && plan.counts.move === 0) {
        overlay.done('Nothing to do: everything in the file is already in place'
          + (plan.counts.skip ? ' (' + plan.counts.skip + ' skipped, see log)' : '') + '.');
        return;
      }

      const ok = await overlay.confirm('Create ' + plan.counts.create + ' sections, move '
        + plan.counts.move + ' channels, skip ' + plan.counts.skip + '. Apply?');
      if (!ok) { log('canceled at confirmation'); overlay.done('Import canceled. Nothing was changed.'); return; }
      mutationStarted = true;

      // The plan above was computed from a pre-confirmation snapshot: sidebar
      // changes made by the user (or another client) while the dialog was open
      // are not re-checked, so an individual remove can become a stale no-op.
      // Execute: create sections first so moves have a target id.
      const idByName = new Map();
      let created = 0, moved = 0, failed = 0;
      let step = 0;
      const totalSteps = plan.create.length + plan.moves.length;
      for (const s of plan.create) {
        if (ac.signal.aborted) { const e = new Error('aborted'); e.name = 'AbortError'; throw e; }
        overlay.setProgress('Applying', ++step, totalSteps);
        // Live-verified: create takes a BARE emoji name ('wrench'); the
        // colon-wrapped form ':wrench:' fails with emoji_invalid, and OMITTING
        // the param fails with invalid_arguments - it must always be sent,
        // as an empty string when the section has no emoji.
        const params = { name: s.name, emoji: s.emoji || '' };
        // createApiCall retries 5xx/transport errors, and create is not
        // idempotent: if the request actually succeeded but the success
        // response was lost, the retry creates a duplicate section. Accepted
        // risk - import is additive-only, so this cannot lose data.
        const r = await apiCall('users.channelSections.create', params);
        if (!r || r.ok === false || !r.channel_section_id) {
          failed++; log('create "' + s.name + '" FAILED: ' + ((r && r.error) || 'no id returned'));
          continue;
        }
        created++; idByName.set(s.name, r.channel_section_id);
        log('created "' + s.name + '" (' + r.channel_section_id + ')');
      }
      for (const m of plan.moves) {
        if (ac.signal.aborted) { const e = new Error('aborted'); e.name = 'AbortError'; throw e; }
        overlay.setProgress('Applying', ++step, totalSteps);
        const targetId = m.sectionId || idByName.get(m.sectionName);
        if (!targetId) {
          failed++; log('move into "' + m.sectionName + '" SKIPPED: section was not created');
          continue;
        }
        const params = {
          insert: JSON.stringify([{ channel_section_id: targetId, channel_ids: m.insertChannelIds }]),
          remove: JSON.stringify(m.removeGroups.map((g) => ({ channel_section_id: g.sectionId, channel_ids: g.channelIds }))),
        };
        const r = await apiCall('users.channelSections.channels.bulkUpdate', params);
        if (!r || r.ok === false) {
          failed++; log('move ' + m.insertChannelIds.length + ' channels into "' + m.sectionName + '" FAILED: ' + ((r && r.error) || 'unknown'));
          continue;
        }
        moved += m.insertChannelIds.length;
        log('moved ' + m.insertChannelIds.length + ' channels into "' + m.sectionName + '"');
      }

      const summary = 'Created ' + created + ' sections, moved ' + moved + ' channels, skipped '
        + plan.counts.skip + (failed ? ', FAILED ' + failed + ' operations (see log)' : '') + '.';
      if (failed) overlay.fail(summary); else overlay.done(summary);
    } catch (e) {
      log('FAILED: ' + ((e && e.message) || e));
      if (e && e.name === 'AbortError') overlay.done(mutationStarted ? 'Import canceled. Changes applied before canceling remain.' : 'Import canceled. Nothing was changed.');
      else overlay.fail(String((e && e.message) || e));
    } finally {
      exportInProgress = false;
    }
  });
  // =================== end channel sections import ===================
```

- [ ] **Step 3: Syntax-check the generated preload.js**

```bash
bash -n slack-autocomplete-electron-app.sh
awk "/^cat > preload.js <<'EOF'\$/{flag=1;next} /^EOF\$/{if(flag){exit}} flag" slack-autocomplete-electron-app.sh > /tmp/preload-check.js && node --check /tmp/preload-check.js && echo PRELOAD_OK
```

Expected: `PRELOAD_OK`.

- [ ] **Step 4: Run the full unit test suite once more**

Run: `node --test test/export-core.test.js 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add slack-autocomplete-electron-app.sh
git commit -m "feat: Import Sections flow with plan preview and Apply/Cancel gate"
```

---

### Task 9: Build, deploy, live smoke test, README

**Files:**
- Modify: `README.md` (feature list)
- No repo code changes expected; fixes discovered here go back through the relevant task's files.

**Interfaces:**
- Consumes: everything above.
- Produces: verified end-to-end feature in the packaged app.

- [ ] **Step 1: Build**

Run: `bash slack-autocomplete-electron-app.sh 2>&1 | tail -15`
Expected: packaging succeeds, code-signing lines appear, "Done." printed.

- [ ] **Step 2: Deploy the live copy**

The user launches `/Applications/SlackAutocompleteElectron.app`, which must be replaced manually. Ask the user to quit the app, then:

```bash
ditto ~/SlackAutocompleteElectron/dist/SlackAutocompleteElectron-darwin-arm64/SlackAutocompleteElectron.app /Applications/SlackAutocompleteElectron.app
open /Applications/SlackAutocompleteElectron.app
```

- [ ] **Step 3: Smoke test export**

In the running app: File -> Channel Sections -> Export Sections... and save to the Downloads folder. Then verify the file from the terminal:

```bash
ls -t ~/Downloads/slack-sections-*.json | head -1
node -e "const d=require(process.argv[1]); console.log(d.format, d.version, 'sections:', d.sections.length, 'unsectioned:', d.unsectioned.length, 'schema:', !!d.schema, 'instructions:', d.instructions.length)" "$(ls -t ~/Downloads/slack-sections-*.json | head -1)"
```

Expected: `slack-sections-export 1 sections: <N> unsectioned: <M> schema: true instructions: 6` with N/M matching what the sidebar shows.

- [ ] **Step 4: Smoke test import (reversible)**

1. Copy the exported file, edit the copy: add a new section `zz-import-test` with one channel moved into it from `unsectioned`.
2. File -> Channel Sections -> Import Sections..., pick the edited copy, check the plan says "create 1 sections, move 1 channels", click Apply.
3. Verify in the sidebar: `zz-import-test` exists with that channel; also verify official parity by checking another Slack client if available.
4. Re-import the SAME edited file: plan must be "Nothing to do" (idempotence).
5. Import the ORIGINAL export: the channel moves back out of `zz-import-test` into no section... note: the original file lists it in `unsectioned`, which import ignores, so the channel STAYS in `zz-import-test`. To revert fully, remove the channel from the section by hand in the UI (drag out or "Remove from section"), then delete the `zz-import-test` section via the sidebar context menu. This is expected additive behavior; confirm the UI cleanup works.
6. Also test the failure paths quickly: import a random non-sections JSON (expect a format error before any dialog beyond the file picker), and cancel at the Apply gate (expect "Import canceled. Nothing was changed.").

- [ ] **Step 5: Update README**

Add one line to the features list in `README.md` describing the feature, matching the style of neighboring entries, for example: `- Channel Sections export/import: dump your sidebar sections (plus unsectioned channels) to JSON, reorganize the file (by hand or with an LLM - the file embeds its own schema and editing instructions), and import it back; import is additive and previews the plan before applying.`

- [ ] **Step 6: Final verification and commit**

```bash
node --test test/export-core.test.js 2>&1 | tail -3
bash -n slack-autocomplete-electron-app.sh
git add README.md
git commit -m "docs: README entry for channel sections export/import"
```

Expected: tests pass, bash syntax OK, commit created.
