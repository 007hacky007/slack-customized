const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../cmdk-fallback-core.js');

// --- isCmdK -----------------------------------------------------------

function key(overrides) {
  return Object.assign({
    key: 'k',
    code: 'KeyK',
    metaKey: false,
    ctrlKey: false,
    altKey: false,
    shiftKey: false,
    repeat: false
  }, overrides);
}

test('isCmdK matches plain Cmd+K on mac', () => {
  assert.equal(core.isCmdK(key({ metaKey: true }), true), true);
});

test('isCmdK matches by code when layout remaps the character', () => {
  assert.equal(core.isCmdK(key({ metaKey: true, key: '˚' }), true), true);
});

test('isCmdK matches plain Ctrl+K on non-mac', () => {
  assert.equal(core.isCmdK(key({ ctrlKey: true }), false), true);
});

test('isCmdK rejects Ctrl+K on mac (that is a readline binding, not the switcher)', () => {
  assert.equal(core.isCmdK(key({ ctrlKey: true }), true), false);
});

test('isCmdK rejects Cmd+Shift+K (browse DMs / menu accelerator)', () => {
  assert.equal(core.isCmdK(key({ metaKey: true, shiftKey: true }), true), false);
});

test('isCmdK rejects Cmd+Alt+K', () => {
  assert.equal(core.isCmdK(key({ metaKey: true, altKey: true }), true), false);
});

test('isCmdK rejects auto-repeat', () => {
  assert.equal(core.isCmdK(key({ metaKey: true, repeat: true }), true), false);
});

test('isCmdK rejects other keys', () => {
  assert.equal(core.isCmdK(key({ metaKey: true, key: 'j', code: 'KeyJ' }), true), false);
});

test('isCmdK rejects null/undefined events', () => {
  assert.equal(core.isCmdK(null, true), false);
  assert.equal(core.isCmdK(undefined, true), false);
});

// --- shouldFallback ---------------------------------------------------

function situation(overrides) {
  return Object.assign({
    modalsAtKeydown: 0,
    modalsNow: 0,
    buttonExists: true,
    lastFallbackAt: null,
    now: 100000
  }, overrides);
}

test('falls back when Slack ignored the key and nothing is open', () => {
  assert.equal(core.shouldFallback(situation()), true);
});

test('does not fall back when a modal was already open at keydown', () => {
  // Slack handles Cmd+K itself when the switcher is open (toggle/close);
  // other modals suppress the shortcut, matching the official app.
  assert.equal(core.shouldFallback(situation({ modalsAtKeydown: 1, modalsNow: 1 })), false);
});

test('does not fall back when the native handler opened the switcher', () => {
  assert.equal(core.shouldFallback(situation({ modalsNow: 1 })), false);
});

test('does not fall back without the top-nav search button (pop-out windows)', () => {
  assert.equal(core.shouldFallback(situation({ buttonExists: false })), false);
});

test('suppresses a second fallback fired within the refire window', () => {
  assert.equal(
    core.shouldFallback(situation({ lastFallbackAt: 100000 - core.REFIRE_SUPPRESS_MS + 1 })),
    false
  );
});

test('allows a fallback once the refire window has passed', () => {
  assert.equal(
    core.shouldFallback(situation({ lastFallbackAt: 100000 - core.REFIRE_SUPPRESS_MS - 1 })),
    true
  );
});

test('exports sane timing constants', () => {
  assert.equal(typeof core.FALLBACK_DELAY_MS, 'number');
  assert.equal(typeof core.REFIRE_SUPPRESS_MS, 'number');
  assert.ok(core.FALLBACK_DELAY_MS >= 100 && core.FALLBACK_DELAY_MS <= 1000);
  assert.ok(core.REFIRE_SUPPRESS_MS > core.FALLBACK_DELAY_MS);
});
