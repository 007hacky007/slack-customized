// Pure decision logic for the Cmd+K startup fallback (unit-tested separately).
//
// Why this exists: the app presents a Chrome user agent, so Slack serves the
// web client and treats us as a browser. On the web client the mod+k hotkey
// is filtered through isUserAttentionOnChat() (plus the k_key_omnibox feature
// flag), and for a long stretch after boot that state says "no attention" -
// Slack receives Cmd+K and deliberately ignores it. The official desktop app
// short-circuits the gate via isDesktopApp(). Clicking the top-nav search
// button is not gated at all, so when Slack ignores the key we ask the main
// process for a trusted synthetic click on that button. Once Slack's own
// handler starts working, the fallback sees the opened modal and goes inert.

const FALLBACK_DELAY_MS = 250; // grace period for Slack's native handler
const REFIRE_SUPPRESS_MS = 400; // ignore rapid re-triggers of the fallback

// Is this keyboard event a plain Cmd+K (mac) / Ctrl+K (elsewhere)?
function isCmdK(ev, isMac) {
  if (!ev || ev.repeat) return false;
  const primary = isMac ? ev.metaKey && !ev.ctrlKey : ev.ctrlKey && !ev.metaKey;
  if (!primary || ev.altKey || ev.shiftKey) return false;
  return ev.code === 'KeyK' || ev.key === 'k' || ev.key === 'K';
}

// Decide (at timer fire, FALLBACK_DELAY_MS after keydown) whether Slack left
// the key unhandled and the fallback click should be requested.
function shouldFallback({ modalsAtKeydown, modalsNow, buttonExists, lastFallbackAt, now }) {
  if (modalsAtKeydown > 0) return false; // open modal: native path owns Cmd+K
  if (!buttonExists) return false; // pop-out windows have no top nav
  if (modalsNow > modalsAtKeydown) return false; // native handler worked
  if (typeof lastFallbackAt === 'number' && now - lastFallbackAt < REFIRE_SUPPRESS_MS) return false;
  return true;
}

module.exports = {
  FALLBACK_DELAY_MS,
  REFIRE_SUPPRESS_MS,
  isCmdK,
  shouldFallback
};
