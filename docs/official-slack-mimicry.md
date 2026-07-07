# Reverse-engineering notes: mimicking the official Slack.app

Findings from building official-app parity into this wrapper. Everything here
was verified empirically, mostly by running both apps with
`--remote-debugging-port` and driving them over the Chrome DevTools Protocol
(CDP): inspecting live DOM, dispatching trusted input, and screenshot-diffing
against the official app.

## How the official app is put together

- The app bundle (`app-arm64.asar`, ~10MB) contains only the desktop shell:
  main-process code, preload bridges, fonts, notification sounds, and a few
  internal HTML pages (settings editor, net-log, auth fallback). The actual
  client is loaded from app.slack.com, same as in a browser.
- The shell appends `Slack_SSB/<version>` to the user agent and exposes a
  `window.desktop` bridge via contextBridge. The web client detects that
  environment and unlocks desktop-only behavior itself: "Open in new window"
  items in its own menus, thread-only window rendering, and so on.
- The bridge is a large private RPC surface (60+ redux "epics": window
  management, notifications, downloads, calls, auto-update, telemetry) with a
  minimum-version handshake (`desktopMinimumSupportedVersion` in their
  package.json). Impersonating it means implementing all of it; a partial
  implementation makes the client dispatch into the void and break. That is
  why this wrapper replicates the resulting UX rather than the mechanism.
- Speed is not local assets or special GPU flags. Both apps cache the client
  via its service worker plus Chromium's HTTP and compiled-JS code caches
  (hundreds of MB on disk in both). Their screen-capture feature flags are for
  huddles, not rendering.

## The pooled-window trick (and its limit)

The official app pre-creates hidden child windows; its CDP target list shows
pages titled "channel-name (Channel)" whose URL is still `about:blank`. Child
windows never boot a second copy of the client at all: the already-running
client in the main renderer renders content into them through the bridge
(the same-origin parent can script an `about:blank` child directly, i.e. a
React portal into the child document). Zero boot cost, near-zero memory per
window.

That specific trick needs the client's own React code to render into the
child window, which it only does when driven through the private bridge.
Moving the DOM subtree into a child window ourselves breaks React's delegated
event system (nodes render but stop responding), and Chromium has no API to
project part of one page into another window. So the wrapper does the
practical next-best thing:

- keep one hidden pool window that boots the full client in the background
  (`backgroundThrottling` disabled, otherwise Chromium slows the hidden boot)
- on "Open in new window", adopt the pool window: assign it the pop-out role
  and navigate it client-side, then reveal
- refill the pool off the hot path

Result: pop-outs appear in well under a second once the pool is warm, at the
cost of one extra client's memory (~300MB), which the official app avoids.

## Client-side navigation from outside the client

To route an already-booted client to another channel without a reload:

- `history.pushState` + synthetic `PopStateEvent` does NOT work: the URL
  changes but Slack's router never fires (verified live; the content stays
  put, which can fool naive "did we navigate" checks that look at
  `location.pathname`)
- `history.back()` after stacking states does not work either
- What works: inject an `<a href="https://app.slack.com/client/T.../C...">`
  and `.click()` it. Slack's global link handler intercepts same-client
  anchors and routes client-side with no reload (verified: `performance`
  uptime continuous, injected classes survive).

## Per-window state in Electron: never use process arguments

Electron shares renderer processes between same-origin windows. A flag passed
via `webPreferences.additionalArguments` is per-process, not per-window: the
main window can land in a flagged process (and turn into a "pop-out", losing
its sidebar) while an actual pop-out lands in an unflagged one. The reliable
pattern: keep the mode in the main process keyed by `webContents.id` and let
each preload fetch it over IPC (survives reloads too).

## Surviving Slack's DOM (hiding UI without breaking it)

- Slack's client router strips URL fragments within about a second of load,
  so a `#marker` is useless for flagging windows.
- React recycles DOM nodes. Hiding elements with inline styles during boot
  can permanently hide content when a node is reused for something visible.
  Fix: mark elements with a data attribute driven by one stylesheet rule, and
  clear + re-mark from scratch on every tick so mistakes self-heal.
- `querySelector('a, b')` returns the first match in document order, not
  selector priority order. With container fallbacks this can select a parent
  of the intended element. Iterate candidates explicitly.
- `:has()` on unknown wrapper containers is dangerous: one boot variant
  places the channel sidebar INSIDE the workspace tabpanel, so a rule hiding
  "the container that has the sidebar" hid the entire content. Restrict
  `:has()` to adjusting grid columns, never `display`.
- The workspace is nested CSS grids with `display: contents` wrappers.
  Elements sit in fixed-width tracks; making a pane fill the window needs
  both hiding the ancestor siblings (they paint over it from sibling stacking
  contexts, z-index cannot beat them) and `position: fixed` to escape the
  grid track.
- Hiding a grid child leaves its track behind (empty gutter): also collapse
  `grid-template-columns`, and watch for hash-classed wrapper divs that own
  the track.
- A margin on a child collapses through to its parent: offsetting content
  below a custom title strip must use padding on the client element, not a
  margin on the workspace wrapper, or the theme background moves down too.
- Slack's theme gradient (`.p-theme_background`) positions statically inside
  the client; pin it `position: fixed; inset: 0` in pop-outs so it paints
  behind a transparent title strip like the official chrome.
- Thread pane detection: thread list items carry ids like
  `C0AB12CDE-1783109507.888099-thread-list-Thread`, a reliable source for
  channel id + thread ts (the address bar shows only the channel while a
  thread pane is open).
- A fresh window cannot cold-load a `/client/T/C/thread/...` deep link
  (Slack renders an error page); boot on the channel URL first.

## Slack's menus

- Menu containers: `[data-qa="menu_items"]` / `.c-menu__items`. Injected
  items reuse Slack's own classes (`c-menu_item__li`,
  `c-button-unstyled c-menu_item__button`, `c-menu_item__label`).
- Hover highlight is React state, not CSS `:hover`: toggle
  `c-menu_item__li--highlighted` / `c-menu_item__button--highlighted` on the
  injected item yourself (and clear Slack's own highlighted rows).
- Slack calls `preventDefault()` on `contextmenu` when it renders its own
  menu: a native fallback menu must check `event.defaultPrevented` or it
  stacks on top.
- Nested menu containers can each receive an injected copy: dedupe by
  checking for an existing visible instance (only one menu is open at a
  time).
- Capture click-time data (URLs) into the item's closure at injection time;
  shared "pending context" state can be cleared by later scans before the
  user clicks.

## Windows and chrome

- `titleBarStyle: 'hiddenInset'` puts traffic lights inside the page; the
  official app uses `titleBarStyle=hidden` with a 31px overlay strip (its
  window config is readable in the child window's `window.name`). Pop-outs
  here draw an equivalent strip: transparent, holds the lights, back/forward
  buttons and a live title, and acts as the drag region
  (`-webkit-app-region: drag`, interactive children `no-drag`).
- macOS only appends its split-screen tiling items to the standard window
  menu (`role: 'windowMenu'`); a custom Window menu silently loses them.
- Hidden pool windows must be excluded from window enumeration (deep-link
  routing, hide-on-close accounting, downloads broadcast) and from
  window-state persistence, or they leak into UX and reappear at launch.

## Notifications, badge, misc

- Electron `Notification` with `hasReply` gives macOS inline reply; the reply
  is posted with the user's `xoxc` token via `chat.postMessage`. Conversation
  id + ts are recoverable from the options Slack passes to `new
  Notification()`.
- Exact dock badge (decompiled from Slack.app main bundle, verified via CDP
  + lsappinfo): number = unreadHighlights (mentions/DMs), else dot when any
  unread exists and the `mac_ssb_bullet` pref is on, else empty. "Unread"
  excludes muted AND archived conversations; `client.counts has_unreads`
  flags both, so filter them (muted now lives in the
  `all_notifications_prefs` JSON pref - `prefs.muted_channels` is gone from
  live `users.prefs.get`; archived needs a `conversations.info` check).
  `client.counts channel_badges` is NOT the badge source (stays 0 for plain
  unreads). Window titles DO carry unread markers ("* ... - N new items -
  Slack", muted-aware) - an earlier note here claiming otherwise was
  mis-verified while every unread happened to be muted.
- The permission gate gained microphone/camera/display-capture for huddles;
  match hostnames strictly (`https:` + exact/suffix match), never
  `url.includes('slack.com')`. Screen sharing uses the native macOS picker
  (`setDisplayMediaRequestHandler` with `useSystemPicker`), never silently
  granting a source.
- macOS kills the app on first microphone access without
  `NSMicrophoneUsageDescription` / `NSCameraUsageDescription` in Info.plist
  (`electron-packager --extend-info`).

## Testing gotchas (CDP)

- `requestAnimationFrame` is throttled in occluded windows: UI injected via
  RAF appears "missing" when the window is behind the terminal. Bring the app
  frontmost before judging.
- Synthetic JS events (`dispatchEvent`) are untrusted and unreliably trigger
  Slack's handlers; use CDP `Input.dispatchMouseEvent` for real interaction
  flows.
- CDP screenshots do not include native chrome (traffic lights), only page
  content.
