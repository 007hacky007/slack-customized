# Custom Slack Electron Wrapper

TL;DR: an unofficial macOS desktop app for Slack that wraps the official Slack
web client (app.slack.com) in Electron and applies patches on top of it. The
guiding principle: behave exactly like the official Slack.app in core UX, then
add extra features the official app does not have.

Everything is generated from a single build script,
`slack-autocomplete-electron-app.sh`, which writes the Electron app (main
process + preload), copies the pure logic module `export-core.js`, and packages
a signed arm64 `.app`.

## Why it exists

The original itch: Slack's autocomplete no longer preselects the first result,
so muscle-memory `@name<enter>` mentions broke. The wrapper fixes that, and
over time grew a set of power features while keeping official-app behavior
everywhere else.

## What it adds on top of official Slack

- Autocomplete fix: the first suggestion is auto-selected again (disabled the
  moment you use the mouse in the list)
- Channel export to JSON: full message history with threads, reactions
  (author lists backfilled), and resolved user names
- Channel list export: public/private/all membership as JSON or plain text
- Channel sections export/import: sidebar sections plus unsectioned channels to JSON, file embeds its own schema and editing instructions for hand- or LLM-editing, import is additive and previews a plan with Apply/Cancel before changing anything
- Last seen (presence) tracking: records when tracked users were last online by
  tapping the client's presence WebSocket, injects a hand-edited watchlist of extra
  user ids into presence subscriptions, and shows current subscriptions, per-user
  last-online, and a transition log in a "Last Seen" panel (File menu). Presence is
  derived from live events only (throttled, no backfill); the data stays local.
- Reaction analytics CLI (`analyze-reactions.js`)
- Thread pop-out button in every thread header
- Esc closes attachment views; "Clear Cache (Keep Login)" menu item
- Workspace menu with Cmd+1..9 switching

## Official-app parity features (replicated, not inherited)

The web client alone does not provide these; the wrapper implements them the
way the official desktop app does (see `docs/official-slack-mimicry.md` for
how that was reverse-engineered):

- Native notifications with inline reply from the banner, replace-by-tag
  deduping, and an exact mention-count dock badge (`client.counts`)
- Huddles and calls: microphone/camera permissions, native screen-share picker
- "Open in new window" for channels and threads from Slack's own context
  menus, opening slim dedicated windows with a custom title-bar strip
  (traffic lights inside the UI, no native title bar)
- Near-instant pop-outs via a warm hidden window pool
- Downloads panel with progress, Open / Show in Finder, and a configurable
  downloads location (File menu)
- Official-style file handling: raw file links become tracked downloads,
  viewer pop-ups get real windows
- macOS split-screen tiling, hidden-inset title bar, standard window menu

## Build and run

```
./slack-autocomplete-electron-app.sh
open "$HOME/SlackAutocompleteElectron/dist/SlackAutocompleteElectron-darwin-arm64/SlackAutocompleteElectron.app"
```

The script installs dependencies, generates the app, and code-signs it with a
Developer identity from the local keychain when one exists (never committed;
CI builds stay ad-hoc signed). GitHub Actions builds an arm64 artifact on
every push and publishes a release with the zipped `.app` on `v*` tags.
Downloaded release builds need `xattr -cr SlackAutocompleteElectron.app` once
(ad-hoc signed, not notarized).

Tests: `node --test test/export-core.test.js`

## Caveats

- Unofficial and unaffiliated with Slack; personal-use tooling
- Some parity features hook Slack's web DOM (class names, data-qa attributes)
  and can degrade gracefully when Slack ships UI changes; the code favors
  layout-agnostic techniques where possible
- Huddle screen-share drawing and remote control are not available (they
  require Slack's private desktop bridge; see the mimicry notes)
