#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SlackAutocompleteElectron"
APP_DIR="$HOME/$APP_NAME"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ICON_SOURCE="$SCRIPT_DIR/wired-flat-2648-logo-circle-slack.svg"
ICONSET_DIR="$APP_DIR/AppIcon.iconset"
APP_ICON="$APP_DIR/AppIcon.icns"

UNAME_ARCH="$(uname -m)"
if [[ "$UNAME_ARCH" == "arm64" ]]; then
  EP_ARCH="arm64"
else
  EP_ARCH="x64"
fi

echo "Creating Electron wrapper for Slack in: $APP_DIR"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# ---------------------------------------------------------------------------
# package.json
# ---------------------------------------------------------------------------
if [[ ! -f package.json ]]; then
  cat > package.json <<'EOF'
{
  "name": "slack-autocomplete-electron",
  "version": "1.0.0",
  "description": "Electron wrapper for Slack with autocomplete behavior override.",
  "main": "main.js",
  "scripts": {
    "start": "electron ."
  }
}
EOF
  echo "Created package.json"
else
  echo "package.json already exists, leaving it as-is."
fi

# ---------------------------------------------------------------------------
# Install Electron (dev dependency)
# ---------------------------------------------------------------------------
echo "Installing Electron + helpers (downloads ~150MB the first time)..."
npm install --save-dev electron sharp

# ---------------------------------------------------------------------------
# Build macOS .icns from provided SVG (if present)
# ---------------------------------------------------------------------------
if [[ -f "$ICON_SOURCE" ]]; then
  NEED_ICON_BUILD=true
  if [[ -f "$APP_ICON" && "$ICON_SOURCE" -ot "$APP_ICON" ]]; then
    NEED_ICON_BUILD=false
  fi

  if [[ "$NEED_ICON_BUILD" == true ]]; then
    echo "Generating macOS icon from $ICON_SOURCE ..."
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    ICON_SIZES=(16 32 128 256 512)
    ICON_SIZES_CSV=$(IFS=, ; echo "${ICON_SIZES[*]}")

    SLACK_ICON_SOURCE="$ICON_SOURCE" \
    SLACK_ICONSET_DIR="$ICONSET_DIR" \
    SLACK_ICON_SIZES="$ICON_SIZES_CSV" \
      node <<'NODE'
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const src = process.env.SLACK_ICON_SOURCE;
const outDir = process.env.SLACK_ICONSET_DIR;
const sizes = (process.env.SLACK_ICON_SIZES || '')
  .split(',')
  .map((size) => parseInt(size, 10))
  .filter((num) => Number.isFinite(num) && num > 0);

async function renderSize(size) {
  const base = path.join(outDir, `icon_${size}x${size}.png`);
  const retina = path.join(outDir, `icon_${size}x${size}@2x.png`);

  const options = { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } };

  await Promise.all([
    sharp(src).resize(size, size, options).png().toFile(base),
    sharp(src).resize(size * 2, size * 2, options).png().toFile(retina)
  ]);
}

(async () => {
  for (const size of sizes) {
    await renderSize(size);
  }
})().catch((err) => {
  console.error('[IconBuilder]', err);
  process.exit(1);
});
NODE

    if command -v iconutil >/dev/null 2>&1; then
      iconutil -c icns "$ICONSET_DIR" -o "$APP_ICON"
      echo "Built custom icon: $APP_ICON"
    else
      echo "warning: iconutil not found; skipping .icns creation"
    fi

    rm -rf "$ICONSET_DIR"
  else
    echo "Custom icon is up-to-date."
  fi
else
  echo "Custom icon source not found at $ICON_SOURCE (skipping icon generation)."
fi

# ---------------------------------------------------------------------------
# main.js  (includes User-Agent override)
# ---------------------------------------------------------------------------
cat > main.js <<'EOF'
const { app, BrowserWindow, session, nativeImage } = require('electron');
const fs = require('fs');
const path = require('path');

// You can override this when launching by setting SLACK_URL env var.
// Example:
//   SLACK_URL="https://app.slack.com/client/T12345678/C12345678" npm start
const SLACK_URL = process.env.SLACK_URL || 'https://app.slack.com/client';

// Present ourselves as a current, supported Chrome on macOS.
const CHROME_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' +
  'AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/131.0.0.0 Safari/537.36';
const ICON_FILENAME = 'AppIcon.icns';
let cachedIconImage;
let windowStateFilePath;
let windowStateSaveTimer;
const WINDOW_STATE_SAVE_DEBOUNCE_MS = 800;
const GPU_SWITCHES = [
  ['enable-gpu-rasterization'],
  ['enable-zero-copy'],
  ['enable-native-gpu-memory-buffers'],
  ['ignore-gpu-blocklist'],
  ['enable-features', 'Metal,CanvasOopRasterization']
];

GPU_SWITCHES.forEach(([name, value]) => {
  if (value) {
    app.commandLine.appendSwitch(name, value);
  } else {
    app.commandLine.appendSwitch(name);
  }
});

function isSlackUrl(targetUrl) {
  try {
    const { hostname, protocol } = new URL(targetUrl);
    const isHttps = protocol === 'https:';
    const isSlackHost = hostname === 'slack.com' || hostname.endsWith('.slack.com');
    return isHttps && isSlackHost;
  } catch (err) {
    return false;
  }
}

function getIconPath() {
  if (process.platform !== 'darwin') {
    return undefined;
  }

  const iconPath = path.join(__dirname, ICON_FILENAME);
  if (fs.existsSync(iconPath)) {
    return iconPath;
  }

  const packagedIcon = path.join(process.resourcesPath || '', 'AppIcon.icns');
  if (fs.existsSync(packagedIcon)) {
    return packagedIcon;
  }

  return undefined;
}

function getIconImage() {
  if (cachedIconImage !== undefined) {
    return cachedIconImage;
  }

  const iconPath = getIconPath();
  if (!iconPath) {
    cachedIconImage = undefined;
    return cachedIconImage;
  }

  try {
    const image = nativeImage.createFromPath(iconPath);
    cachedIconImage = image && !image.isEmpty() ? image : undefined;
  } catch (err) {
    console.warn('Failed to load icon, continuing without it:', err);
    cachedIconImage = undefined;
  }

  return cachedIconImage;
}

function getWindowStateFilePath() {
  if (!windowStateFilePath) {
    windowStateFilePath = path.join(app.getPath('userData'), 'window-state.json');
  }
  return windowStateFilePath;
}

function loadWindowState() {
  try {
    const filePath = getWindowStateFilePath();
    if (!fs.existsSync(filePath)) {
      return [SLACK_URL];
    }

    const raw = fs.readFileSync(filePath, 'utf8');
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      const validUrls = [];
      const seen = new Set();
      parsed.forEach((url) => {
        if (typeof url === 'string' && isSlackUrl(url) && !seen.has(url)) {
          seen.add(url);
          validUrls.push(url);
        }
      });
      return validUrls.length ? validUrls : [SLACK_URL];
    }
  } catch (err) {
    console.warn('Failed to load saved window state:', err);
  }

  return [SLACK_URL];
}

function collectWindowUrls() {
  const urls = [];
  const seen = new Set();

  BrowserWindow.getAllWindows().forEach((win) => {
    const url = typeof win.__slackLastUrl === 'string' ? win.__slackLastUrl : SLACK_URL;
    const normalized = isSlackUrl(url) ? url : SLACK_URL;
    if (!seen.has(normalized)) {
      seen.add(normalized);
      urls.push(normalized);
    }
  });

  if (!urls.length) {
    urls.push(SLACK_URL);
  }

  return urls;
}

function saveWindowStateNow() {
  try {
    const filePath = getWindowStateFilePath();
    const urls = collectWindowUrls();
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, JSON.stringify(urls, null, 2), 'utf8');
  } catch (err) {
    console.warn('Failed to persist window state:', err);
  }
}

function scheduleWindowStateSave() {
  if (windowStateSaveTimer) {
    clearTimeout(windowStateSaveTimer);
  }

  windowStateSaveTimer = setTimeout(() => {
    windowStateSaveTimer = null;
    saveWindowStateNow();
  }, WINDOW_STATE_SAVE_DEBOUNCE_MS);
}

function attachWindowStateTracking(win, initialUrl = SLACK_URL) {
  if (win.__slackTrackingAttached) {
    return;
  }

  win.__slackTrackingAttached = true;
  win.__slackLastUrl = isSlackUrl(initialUrl) ? initialUrl : SLACK_URL;

  const updateLastUrl = () => {
    const currentUrl = win.webContents.getURL();
    if (isSlackUrl(currentUrl)) {
      win.__slackLastUrl = currentUrl;
      scheduleWindowStateSave();
    }
  };

  win.webContents.on('did-navigate', updateLastUrl);
  win.webContents.on('did-navigate-in-page', updateLastUrl);
  win.webContents.on('did-finish-load', updateLastUrl);
  win.on('close', scheduleWindowStateSave);
  win.on('closed', scheduleWindowStateSave);

  scheduleWindowStateSave();
}

function buildWindowOptions() {
  const iconImage = getIconImage();
  return {
    width: 1200,
    height: 800,
    icon: iconImage,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      nativeWindowOpen: true
    }
  };
}

function applyWindowPolicies(win) {
  win.webContents.session.setUserAgent(CHROME_UA);
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (!isSlackUrl(url)) {
      return { action: 'deny' };
    }

    return {
      action: 'allow',
      overrideBrowserWindowOptions: buildWindowOptions()
    };
  });
}

function createWindow(initialUrl = SLACK_URL) {
  const win = new BrowserWindow(buildWindowOptions());
  applyWindowPolicies(win);
  win.loadURL(initialUrl);
  attachWindowStateTracking(win, initialUrl);
  return win;
}

app.whenReady().then(() => {
  // Global default UA (covers auth popups etc.).
  session.defaultSession.setUserAgent(CHROME_UA);

  const dockIcon = getIconImage();
  if (dockIcon && app.dock) {
    app.dock.setIcon(dockIcon);
  }

  const initialWindows = loadWindowState();
  const urlsToOpen = initialWindows.length ? initialWindows : [SLACK_URL];
  urlsToOpen.forEach((url) => createWindow(url));

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

app.on('browser-window-created', (_event, window) => {
  applyWindowPolicies(window);
  attachWindowStateTracking(window);
});

app.on('before-quit', () => {
  saveWindowStateNow();
});

app.on('window-all-closed', () => {
  saveWindowStateNow();
  // Standard macOS behavior
  if (process.platform !== 'darwin') {
    app.quit();
  }
});
EOF

echo "Created main.js"

# ---------------------------------------------------------------------------
# preload.js  (your autocomplete override logic)
# ---------------------------------------------------------------------------
cat > preload.js <<'EOF'
(() => {
  'use strict';

  if (!location.hostname.endsWith('slack.com')) {
    return;
  }

  const DEBUG = false;
  const CHANNEL_CONTEXT_TTL = 4000;
  const THREAD_CONTEXT_REFRESH_INTERVAL = 1500;
  const THREAD_GLOBAL_SCAN_MAX_NODES = 2000;
  const THREAD_GLOBAL_SCAN_MAX_DEPTH = 6;
  const THREAD_BUTTON_ID = 'slack-autocomplete-thread-popout';
  const THREAD_BUTTON_WRAPPER_ID = 'slack-autocomplete-thread-popout-wrapper';
  const CHANNEL_MENU_ITEM_QA = 'slack_autocomplete_open_window';
  const CHANNEL_MENU_SEPARATOR_QA = 'slack_autocomplete_open_window_separator';

  let allowAutoSelect = true;
  let pendingChannelContext = null;
  let menuObserver = null;
  let menuScanHandle = null;
  let listboxObserver = null;
  let listboxScanHandle = null;
  let cachedThreadContext = null;
  let cachedThreadContextTimestamp = 0;

  function log(...args) {
    if (!DEBUG) return;
    console.log('[SlackAutocompletePreload]', ...args);
  }

  function isVisible(el) {
    if (!el || !(el instanceof HTMLElement)) return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 || rect.height > 0;
  }

  function isTypingKey(ev) {
    if (ev.ctrlKey || ev.metaKey || ev.altKey) return false;
    if (ev.key && ev.key.length === 1) return true;
    return ev.key === 'Backspace' || ev.key === 'Delete' || ev.key === 'Space';
  }

  function hoverOption(optionEl) {
    const eventTypes = ['mousemove', 'mouseover', 'mouseenter'];
    eventTypes.forEach((type) => {
      try {
        const ev = new MouseEvent(type, {
          bubbles: true,
          cancelable: true,
          view: window
        });
        optionEl.dispatchEvent(ev);
      } catch (e) {
        log('Error dispatching mouse event', type, e);
      }
    });
  }

  function ensureFirstOptionSelected(listbox) {
    if (!allowAutoSelect) return;
    if (!isVisible(listbox)) return;

    const firstOption =
      listbox.querySelector('[role="option"][data-qa="tab_complete_ui_item"]') ||
      listbox.querySelector('[role="option"].tab_complete_ui_item') ||
      listbox.querySelector('[role="option"].c-texty_autocomplete__result') ||
      listbox.querySelector('[role="option"].c-search_autocomplete__result') ||
      listbox.querySelector('[role="option"]');

    if (!firstOption) return;

    const selectedOption =
      listbox.querySelector('[role="option"][aria-selected="true"]') ||
      listbox.querySelector('.c-texty_autocomplete__result--selected') ||
      listbox.querySelector('.c-search_autocomplete__result--selected');

    if (selectedOption === firstOption) return;

    log('Selecting first option in listbox:', listbox, 'First option:', firstOption);
    hoverOption(firstOption);
  }

  function scanForListboxes() {
    const listboxes = document.querySelectorAll('[role="listbox"]');
    listboxes.forEach((lb) => {
      ensureFirstOptionSelected(lb);
    });
  }

  function scheduleAutocompleteScan() {
    if (listboxScanHandle) return;
    listboxScanHandle = requestAnimationFrame(() => {
      listboxScanHandle = null;
      scanForListboxes();
    });
  }

  function handleListboxMutations(mutations) {
    for (const mutation of mutations) {
      mutation.addedNodes.forEach((node) => {
        if (!(node instanceof HTMLElement)) return;
        if (node.getAttribute('role') === 'listbox') {
          scheduleAutocompleteScan();
          return;
        }

        if (node.querySelector?.('[role="listbox"]')) {
          scheduleAutocompleteScan();
          return;
        }
      });

      if (mutation.type === 'attributes' && mutation.target instanceof HTMLElement) {
        if (mutation.target.getAttribute('role') === 'listbox') {
          scheduleAutocompleteScan();
          return;
        }
      }
    }
  }

  function setupAutocompleteObservers() {
    scanForListboxes();

    if (listboxObserver) {
      listboxObserver.disconnect();
    }

    listboxObserver = new MutationObserver(handleListboxMutations);
    listboxObserver.observe(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['class', 'style', 'aria-hidden']
    });

    ['focusin', 'keydown', 'input'].forEach((eventName) => {
      document.addEventListener(eventName, scheduleAutocompleteScan, true);
    });
  }

  function attachKeyListener() {
    document.addEventListener(
      'keydown',
      (ev) => {
        const k = ev.key;

        if (
          k === 'ArrowUp' ||
          k === 'ArrowDown' ||
          k === 'PageUp' ||
          k === 'PageDown' ||
          k === 'Home' ||
          k === 'End'
        ) {
          allowAutoSelect = false;
          log('User navigating with arrows; disabling auto-select until next typing.');
          return;
        }

        if (isTypingKey(ev)) {
          allowAutoSelect = true;
          log('User is typing; enabling auto-select.');
        }
      },
      true
    );
  }

  function openSlackWindow(url) {
    if (!url) return;
    try {
      window.open(url, '_blank', 'noopener');
    } catch (err) {
      log('Failed to open new window', err);
    }
  }

  function closeContextMenus() {
    const eventInit = {
      key: 'Escape',
      code: 'Escape',
      keyCode: 27,
      which: 27,
      bubbles: true,
      cancelable: true
    };

    const targets = new Set();
    targets.add(document);
    targets.add(window);

    if (document.activeElement) {
      targets.add(document.activeElement);
    }

    document.querySelectorAll('.c-menu, [role="menu"], [data-qa="menu_items"]').forEach((menu) => {
      targets.add(menu);
    });

    targets.forEach((target) => {
      try {
        target.dispatchEvent(new KeyboardEvent('keydown', eventInit));
        target.dispatchEvent(new KeyboardEvent('keyup', eventInit));
      } catch (err) {
        log('Error closing context menu', err);
      }
    });
  }

  function cleanupChannelContext() {
    if (pendingChannelContext && Date.now() - pendingChannelContext.ts > CHANNEL_CONTEXT_TTL) {
      pendingChannelContext = null;
    }
  }

  function getCurrentTeamId() {
    const pathMatch = window.location.pathname.match(/\/client\/([^/]+)/);
    if (pathMatch && pathMatch[1]) {
      return pathMatch[1];
    }

    const hashMatch = window.location.hash.match(/\/client\/([^/]+)/);
    if (hashMatch && hashMatch[1]) {
      return hashMatch[1];
    }

    return null;
  }

  function extractChannelContext(originEl) {
    if (!(originEl instanceof Element)) return null;

    const channelNode =
      originEl.closest('[data-sidebar-link-id]') ||
      originEl.closest('[data-qa-channel-sidebar-channel-type]') ||
      originEl.closest('[data-qa="channel_sidebar_name"]') ||
      originEl.closest('a.p-channel_sidebar__channel');

    if (!channelNode) return null;

    const directHref =
      channelNode instanceof HTMLAnchorElement && channelNode.href
        ? channelNode.href
        : channelNode.querySelector?.('a[href*="/client/"]')?.href;

    let url = null;
    if (directHref && directHref.includes('/client/')) {
      url = new URL(directHref, window.location.origin).toString();
    } else {
      const teamId = getCurrentTeamId();
      const channelId =
        channelNode.getAttribute('data-sidebar-link-id') ||
        channelNode.dataset?.sidebarLinkId ||
        channelNode.getAttribute('data-qa-channel-id') ||
        channelNode.dataset?.qaChannelId ||
        channelNode.getAttribute('data-qa-channel-sidebar-channel-id');

      if (teamId && channelId) {
        url = `${window.location.origin}/client/${teamId}/${channelId}`;
      }
    }

    if (!url) return null;

    const label =
      channelNode.getAttribute('aria-label') ||
      channelNode.getAttribute('data-qa-channel-sidebar-channel-name') ||
      (channelNode.textContent || '').trim() ||
      'channel';

    return { url, label };
  }

  function resolveMenuContainer(node) {
    if (!node) return null;

    if (node.classList?.contains('c-menu__items') || node.getAttribute?.('data-qa') === 'menu_items') {
      return node;
    }

    const closestItems = node.closest?.('.c-menu__items, [data-qa="menu_items"]');
    if (closestItems) {
      return closestItems;
    }

    if (node.classList?.contains('c-menu')) {
      return normalizeMenuElement(node);
    }

    const closestMenu = node.closest?.('.c-menu');
    if (closestMenu) {
      return normalizeMenuElement(closestMenu);
    }

    if (node.getAttribute?.('role') === 'menu') {
      return node;
    }

    return node.closest?.('[role="menu"]') || null;
  }

  function normalizeMenuElement(menuEl) {
    if (!menuEl) return null;
    if (menuEl.classList?.contains('c-menu__items') || menuEl.getAttribute?.('data-qa') === 'menu_items') {
      return menuEl;
    }

    const childItems = menuEl.querySelector?.('.c-menu__items, [data-qa="menu_items"]');
    if (childItems) {
      return childItems;
    }

    const closestItems = menuEl.closest?.('.c-menu__items, [data-qa="menu_items"]');
    if (closestItems) {
      return closestItems;
    }

    return menuEl;
  }

  function looksLikeChannelMenu(menuEl) {
    const normalized = normalizeMenuElement(menuEl);
    if (!normalized) return false;

    const hasChannelItems = normalized.querySelector('[data-qa^="channel_ctx_menu_"]');
    if (hasChannelItems) return true;

    const dataQa = normalized.getAttribute('data-qa');
    if (dataQa === 'menu_items') {
      const hasChannelDetails = normalized.querySelector('[data-qa="channel_details_modal"]');
      if (hasChannelDetails) {
        return true;
      }
    }

    const ariaLabel = normalized.getAttribute('aria-label');
    if (ariaLabel && ariaLabel.toLowerCase().includes('channel options')) {
      return true;
    }

    return Boolean(normalized.classList?.contains('c-menu__items'));
  }

  function requestMenuScan() {
    if (menuScanHandle) return;
    menuScanHandle = setTimeout(() => {
      menuScanHandle = null;
      if (!pendingChannelContext) return;
      document
        .querySelectorAll('[data-qa="menu_items"], .c-menu__items, [role="menu"]')
        .forEach((menu) => {
        injectChannelMenuItem(menu);
        });
    }, 40);
  }

  function captureChannelContext(event) {
    cleanupChannelContext();
    const contextInfo = extractChannelContext(event.target);
    if (!contextInfo) {
      return;
    }

    pendingChannelContext = {
      url: contextInfo.url,
      label: contextInfo.label,
      ts: Date.now()
    };

    requestMenuScan();
  }

  function injectChannelMenuItem(menuEl) {
    if (!pendingChannelContext) return;
    const normalizedMenu = normalizeMenuElement(menuEl);
    if (!normalizedMenu) return;
    if (!looksLikeChannelMenu(normalizedMenu)) return;
    if (normalizedMenu.dataset.slackAutocompleteMenuPatched === '1') return;
    if (Date.now() - pendingChannelContext.ts > CHANNEL_CONTEXT_TTL) {
      pendingChannelContext = null;
      return;
    }

    normalizedMenu.dataset.slackAutocompleteMenuPatched = '1';

    const existingItem = normalizedMenu.querySelector(`[data-qa="${CHANNEL_MENU_ITEM_QA}"]`);
    if (existingItem) {
      existingItem.remove();
    }

    const existingSeparator = normalizedMenu.querySelector(
      `[data-qa="${CHANNEL_MENU_SEPARATOR_QA}"]`
    );
    if (existingSeparator) {
      existingSeparator.remove();
    }

    const wrapper = document.createElement('div');
    wrapper.className = 'c-menu_item__li';
    wrapper.dataset.qa = CHANNEL_MENU_ITEM_QA;

    const button = document.createElement('button');
    button.className = 'c-button-unstyled c-menu_item__button';
    button.type = 'button';
    button.setAttribute('role', 'menuitem');
    button.tabIndex = -1;

    const label = document.createElement('div');
    label.className = 'c-menu_item__label';
    label.textContent = 'Open in new window';

    button.appendChild(label);
    wrapper.appendChild(button);

    const separator = document.createElement('div');
    separator.className = 'c-menu_separator__li';
    separator.dataset.qa = CHANNEL_MENU_SEPARATOR_QA;

    const hr = document.createElement('hr');
    hr.className = 'c-menu_separator__separator';
    hr.setAttribute('data-qa', 'menu_separator__separator');
    separator.appendChild(hr);

    button.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      openSlackWindow(pendingChannelContext.url);
      pendingChannelContext = null;
      requestAnimationFrame(closeContextMenus);
    });

    normalizedMenu.appendChild(wrapper);
    normalizedMenu.appendChild(separator);
    log('Inserted custom "Open in new window" channel action.');
  }

  function handleMenuMutations(mutations) {
    if (!pendingChannelContext) return;

    for (const mutation of mutations) {
      mutation.addedNodes.forEach((node) => {
        if (!(node instanceof HTMLElement)) return;

        const menuEl = resolveMenuContainer(node);
        if (menuEl) {
          injectChannelMenuItem(menuEl);
        }

        node
          .querySelectorAll?.('[data-qa="menu_items"], .c-menu__items, [role="menu"]')
          .forEach((menu) => {
            injectChannelMenuItem(menu);
          });
      });
    }

    requestMenuScan();
  }

  function setupChannelContextMenuSupport() {
    document.addEventListener('contextmenu', captureChannelContext, true);

    if (menuObserver) {
      menuObserver.disconnect();
    }

    menuObserver = new MutationObserver(handleMenuMutations);
    menuObserver.observe(document.body, {
      childList: true,
      subtree: true
    });
  }

  const THREAD_CONTAINER_SELECTORS = [
    '[data-qa="thread-pane"]',
    '[data-qa="right_pane"]',
    '[data-qa="right_sidebar"]',
    'section[aria-label="Thread"]',
    '.p-threads_view'
  ];
  const THREAD_HEADER_SELECTORS = [
    '.p-flexpane_header',
    '.p-threads_view_header',
    '[data-qa="flexpane-title-container"]',
    '.p-flexpane_header__primary'
  ];

  let threadObserver = null;
  let threadScanHandle = null;

  function findThreadHeaderContext() {
    const containers = THREAD_CONTAINER_SELECTORS.map((selector) =>
      document.querySelector(selector)
    ).filter(Boolean);

    const candidateRoots = containers.length
      ? containers
      : [document.body];

    for (const root of candidateRoots) {
      for (const headerSelector of THREAD_HEADER_SELECTORS) {
        const header = root.querySelector(headerSelector);
        if (!header || !isVisible(header)) continue;

        const actionHost =
          header.querySelector('.p-flexpane_header__trailing') ||
          header.querySelector('.p-flexpane_header__primary_actions') ||
          header.querySelector('.p-flexpane_header__primary') ||
          header.closest('.p-flexpane_header') ||
          header;

        if (actionHost) {
          return { header, actionHost };
        }
      }
    }

    return null;
  }

  function buildThreadUrl(channelId, threadTs) {
    if (!channelId || !threadTs) return null;
    const teamId = getCurrentTeamId();
    if (!teamId) return null;

    const sanitizedTs = String(threadTs).trim();
    return `${window.location.origin}/client/${teamId}/${channelId}/thread/${channelId}-${sanitizedTs}`;
  }

  function datasetKeyFromAttr(attr) {
    return attr.replace(/^data-/, '').replace(/-([a-z])/g, (_match, char) => char.toUpperCase());
  }

  function coerceChannelId(value) {
    if (typeof value !== 'string') return null;
    const trimmed = value.trim();
    if (!trimmed) return null;
    if (/^[CDGSPW][A-Z0-9]{7,}$/i.test(trimmed)) {
      return trimmed;
    }
    return null;
  }

  function coerceThreadTs(value) {
    if (value === undefined || value === null) return null;
    const str = String(value).trim();
    if (!str) return null;
    if (/^\d{10,}(\.\d{1,9})?$/.test(str)) {
      return str;
    }
    return null;
  }

  function extractThreadDataFromElement(el) {
    if (!el) return null;

    const threadAttrs = [
      'data-thread-root-ts',
      'data-thread-ts',
      'data-qa-thread-root-ts',
      'data-qa-thread-ts',
      'data-message-ts',
      'data-qa-thread-root-message-ts'
    ];
    const channelAttrs = [
      'data-channel-id',
      'data-qa-channel-id',
      'data-qa-channel',
      'data-message-channel-id',
      'data-conversation-id',
      'data-qa-conversation-id',
      'data-qa-thread-channel-id'
    ];

    let channelId = null;
    let threadTs = null;

    for (const attr of channelAttrs) {
      const attrKey = datasetKeyFromAttr(attr);
      const value = el.getAttribute(attr) || el.dataset?.[attrKey];
      const coerced = coerceChannelId(value);
      if (coerced) {
        channelId = coerced;
        break;
      }
    }

    if (!channelId) {
      const channelCarrier = el.closest?.(
        '[data-channel-id], [data-qa-channel-id], [data-qa-channel], [data-conversation-id], [data-qa-conversation-id]'
      );
      if (channelCarrier) {
        const attrsToTry = [
          'data-channel-id',
          'data-qa-channel-id',
          'data-qa-channel',
          'data-conversation-id',
          'data-qa-conversation-id'
        ];
        for (const attr of attrsToTry) {
          const value = channelCarrier.getAttribute(attr) || channelCarrier.dataset?.[datasetKeyFromAttr(attr)];
          const coerced = coerceChannelId(value);
          if (coerced) {
            channelId = coerced;
            break;
          }
        }
      }
    }

    if (!channelId) {
      const messageContainer = el.closest?.('[data-qa="message_container"]');
      if (messageContainer) {
        const value =
          messageContainer.getAttribute('data-qa-channel-id') ||
          messageContainer.getAttribute('data-channel-id') ||
          messageContainer.dataset?.qaChannelId ||
          messageContainer.dataset?.channelId;
        channelId = coerceChannelId(value);
      }
    }

    for (const attr of threadAttrs) {
      const attrKey = datasetKeyFromAttr(attr);
      const value = el.getAttribute(attr) || el.dataset?.[attrKey];
      const coerced = coerceThreadTs(value);
      if (coerced) {
        threadTs = coerced;
        break;
      }
    }

    if (!threadTs) {
      const tsCarrier = el.closest?.('[data-thread-root-ts], [data-thread-ts], [data-message-ts]');
      if (tsCarrier) {
        const value =
          tsCarrier.getAttribute('data-thread-root-ts') ||
          tsCarrier.getAttribute('data-thread-ts') ||
          tsCarrier.getAttribute('data-message-ts');
        threadTs = coerceThreadTs(value);
      }
    }

    if (channelId && threadTs) {
      return { channelId, threadTs };
    }

    return null;
  }

  function collectThreadDomCandidates() {
    return [
      document.querySelector('[data-qa="thread_permalink_button"]'),
      document.querySelector('[data-qa="thread_permalink_button"] a[href*="/thread/"]'),
      document.querySelector('.p-threads_flexpane__header_permalink'),
      document.querySelector('[data-qa="thread-pane"] [data-thread-root-ts]'),
      document.querySelector('[data-qa="thread-pane"] [data-thread-ts]'),
      document.querySelector('.p-threads_view__root_message'),
      document.querySelector('[data-qa="thread-pane"] [data-qa="message_container"]'),
      document.querySelector('[data-qa="thread-pane"] [data-message-ts]'),
      document.querySelector('[data-qa="ai_summary_summarize_thread_button"]')
    ].filter(Boolean);
  }

  function deriveThreadContextFromDom() {
    const permalinkAnchor = document.querySelector('[data-qa="thread_permalink_button"] a[href*="/thread/"]');
    if (permalinkAnchor?.href) {
      try {
        const url = new URL(permalinkAnchor.href);
        const parts = url.pathname.split('/');
        const threadToken = parts[parts.length - 1];
        if (threadToken && threadToken.includes('-')) {
          const [channelId, threadTs] = threadToken.split('-');
          if (coerceChannelId(channelId) && coerceThreadTs(threadTs)) {
            return { channelId, threadTs };
          }
        }
      } catch (err) {
        log('Failed to parse permalink anchor url', err);
      }
    }

    const candidates = collectThreadDomCandidates();
    for (const el of candidates) {
      const info = extractThreadDataFromElement(el);
      if (info) {
        return info;
      }
    }

    return null;
  }

  function safeGetState(store) {
    if (!store) return null;
    try {
      if (typeof store.getState === 'function') {
        return store.getState();
      }
    } catch (err) {
      log('Unable to read store state', err);
    }
    return null;
  }

  function gatherGlobalStateCandidates() {
    const candidates = [];
    const w = window;

    if (w.__remixContext?.state) {
      candidates.push(w.__remixContext.state);
    }

    if (w.slackDebug?.store) {
      const debugState = safeGetState(w.slackDebug.store);
      if (debugState) {
        candidates.push(debugState);
      }
    }

    if (w.__SLACK_GLOBAL_STATE__) {
      candidates.push(w.__SLACK_GLOBAL_STATE__);
    }

    const ts = w.TS;
    if (ts) {
      candidates.push(ts);
      if (ts.model) {
        candidates.push(ts.model);
      }
      if (ts.interop) {
        candidates.push(ts.interop);
        if (ts.interop.right_pane_store) {
          candidates.push(ts.interop.right_pane_store);
          const rightPaneState = safeGetState(ts.interop.right_pane_store);
          if (rightPaneState) {
            candidates.push(rightPaneState);
          }
        }
      }

      const tsStore = ts.reduxStore || ts.store || ts?.interop?.store;
      const tsState = safeGetState(tsStore);
      if (tsState) {
        candidates.push(tsState);
      }
    }

    return candidates;
  }

  function attemptExtractThreadContext(obj) {
    if (!obj || typeof obj !== 'object') return null;

    const channelKeys = [
      'channel_id',
      'channelId',
      'channelID',
      'cid',
      'conversation_id',
      'conversationId',
      'conversationID',
      'root_channel_id',
      'destination_channel_id',
      'selected_channel_id'
    ];

    const threadKeys = [
      'thread_ts',
      'threadTs',
      'thread_id',
      'threadId',
      'root_ts',
      'rootTs',
      'thread_root_ts',
      'threadRootTs',
      'selected_thread_ts',
      'selectedThreadTs'
    ];

    const channelId =
      channelKeys
        .map((key) => {
          if (!(key in obj)) return null;
          const value = obj[key];
          if (typeof value === 'object' && value) {
            return coerceChannelId(value.id || value.channel_id || value.channelId);
          }
          return coerceChannelId(value);
        })
        .find(Boolean) ||
      coerceChannelId(obj?.channel?.id || obj?.channel) ||
      coerceChannelId(obj?.conversation?.id || obj?.conversation);

    const threadTs =
      threadKeys
        .map((key) => coerceThreadTs(obj[key]))
        .find(Boolean) ||
      coerceThreadTs(obj?.thread?.thread_ts || obj?.thread?.root_ts);

    if (channelId && threadTs) {
      return { channelId, threadTs };
    }

    if (threadTs) {
      const nestedChannel =
        coerceChannelId(obj?.channel?.id) ||
        coerceChannelId(obj?.conversation?.id) ||
        coerceChannelId(obj?.thread?.channel_id);
      if (nestedChannel) {
        return { channelId: nestedChannel, threadTs };
      }
    }

    return null;
  }

  function deriveThreadContextFromGlobals() {
    const queue = [];
    const seen = new WeakSet();
    const candidates = gatherGlobalStateCandidates();

    candidates.forEach((value) => {
      if (value && typeof value === 'object' && !seen.has(value)) {
        queue.push({ value, depth: 0 });
      }
    });

    let processed = 0;
    while (queue.length && processed < THREAD_GLOBAL_SCAN_MAX_NODES) {
      const { value, depth } = queue.shift();
      if (!value || typeof value !== 'object') continue;
      if (seen.has(value)) continue;
      seen.add(value);
      processed++;

      const context = attemptExtractThreadContext(value);
      if (context) {
        return context;
      }

      if (depth >= THREAD_GLOBAL_SCAN_MAX_DEPTH) {
        continue;
      }

      const childValues = Array.isArray(value) ? value : Object.values(value);
      for (const child of childValues) {
        if (child && typeof child === 'object' && !seen.has(child)) {
          queue.push({ value: child, depth: depth + 1 });
        }
      }
    }

    return null;
  }

  function refreshThreadContext(force = false) {
    if (!force && cachedThreadContext) {
      const age = Date.now() - cachedThreadContextTimestamp;
      if (age < THREAD_CONTEXT_REFRESH_INTERVAL) {
        return cachedThreadContext;
      }
    }

    let context = deriveThreadContextFromDom();
    if (!context) {
      context = deriveThreadContextFromGlobals();
    }

    if (context) {
      cachedThreadContext = context;
      cachedThreadContextTimestamp = Date.now();
      window.__slackAutocompleteThreadContext = context;
      return context;
    }

    if (force) {
      cachedThreadContext = null;
      cachedThreadContextTimestamp = 0;
    }

    return null;
  }

  function clearThreadContextCache() {
    cachedThreadContext = null;
    cachedThreadContextTimestamp = 0;
  }

  function getThreadUrlFromContext(forceRefresh = false) {
    if (window.location.pathname.includes('/thread/')) {
      return window.location.href;
    }

    const context = refreshThreadContext(forceRefresh);
    if (!context) {
      return null;
    }

    return buildThreadUrl(context.channelId, context.threadTs);
  }

  function getCurrentThreadUrl(forceRefresh = false) {
    return getThreadUrlFromContext(forceRefresh);
  }

  function updateThreadButtonState(button) {
    if (!button) return;
    const hasUrl = Boolean(getThreadUrlFromContext(false));
    button.disabled = !hasUrl;
    button.setAttribute('aria-disabled', String(!hasUrl));
    if (hasUrl) {
      button.classList.remove('c-button--disabled', 'is-disabled');
    } else {
      button.classList.add('c-button--disabled', 'is-disabled');
    }
  }

  function ensureThreadPopoutButton() {
    const threadUi = findThreadHeaderContext();
    if (!threadUi) {
      document.querySelectorAll(`#${THREAD_BUTTON_WRAPPER_ID}`).forEach((node) => node.remove());
      clearThreadContextCache();
      return;
    }

    const { actionHost } = threadUi;
    if (!actionHost) return;

    const existingButton = actionHost.querySelector(`#${THREAD_BUTTON_ID}`);
    if (existingButton) {
      updateThreadButtonState(existingButton);
      return;
    }

    const anchor = document.createElement('div');
    anchor.id = THREAD_BUTTON_WRAPPER_ID;
    anchor.className = 'c-coachmark-anchor';
    anchor.setAttribute('role', 'none');

    const button = document.createElement('button');
    button.id = THREAD_BUTTON_ID;
    button.type = 'button';
    button.className =
      'c-button-unstyled c-icon_button c-icon_button--size_medium viewHeaderActionButton__d6GTR c-icon_button--default';
    button.setAttribute('aria-label', 'Open thread in new window');
    button.setAttribute('title', 'Open thread in new window');
    button.setAttribute('data-qa', 'slack_autocomplete_thread_popout');
    button.tabIndex = 0;

    button.innerHTML = `
      <svg aria-hidden="true" viewBox="0 0 20 20" width="20" height="20">
        <path
          fill="currentColor"
          fill-rule="evenodd"
          d="M6.25 5.5A.75.75 0 0 1 7 4.75h8.25A.75.75 0 0 1 16 5.5v8.25a.75.75 0 0 1-1.5 0V7.56l-6.97 6.97a.75.75 0 0 1-1.06-1.06L13.44 6.5H7A.75.75 0 0 1 6.25 5.5"
          clip-rule="evenodd"
        />
      </svg>
    `;

    button.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();

      const threadUrl = getCurrentThreadUrl(true);
      if (!threadUrl) {
        log('No thread URL detected; cannot open thread window.');
        updateThreadButtonState(button);
        return;
      }

      openSlackWindow(threadUrl);
    });

    anchor.appendChild(button);

    const summaryButton = document.querySelector('button[data-qa="ai_summary_summarize_thread_button"]');
    const summaryAnchor = summaryButton?.closest('.c-coachmark-anchor');

    if (summaryAnchor && summaryAnchor.parentElement === actionHost) {
      summaryAnchor.parentElement.insertBefore(anchor, summaryAnchor);
    } else if (summaryAnchor && summaryAnchor.parentElement) {
      summaryAnchor.parentElement.insertBefore(anchor, summaryAnchor);
    } else {
      actionHost.appendChild(anchor);
    }

    updateThreadButtonState(button);
    log('Inserted thread pop-out button.');
  }

  function scheduleThreadScan() {
    if (threadScanHandle) {
      cancelAnimationFrame(threadScanHandle);
    }
    threadScanHandle = requestAnimationFrame(() => {
      threadScanHandle = null;
      ensureThreadPopoutButton();
      refreshThreadContext(true);
      updateThreadButtonState(document.getElementById(THREAD_BUTTON_ID));
    });
  }

  function setupThreadWatcher() {
    ensureThreadPopoutButton();
    refreshThreadContext(true);
    updateThreadButtonState(document.getElementById(THREAD_BUTTON_ID));

    if (threadObserver) {
      threadObserver.disconnect();
    }

    threadObserver = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        if (!mutation.addedNodes) continue;
        for (const node of mutation.addedNodes) {
          if (!(node instanceof HTMLElement)) continue;
          if (
            node.matches?.(THREAD_CONTAINER_SELECTORS.join(', ')) ||
            node.querySelector?.(THREAD_CONTAINER_SELECTORS.join(', ')) ||
            node.matches?.(THREAD_HEADER_SELECTORS.join(', ')) ||
            node.querySelector?.(THREAD_HEADER_SELECTORS.join(', '))
          ) {
            scheduleThreadScan();
            return;
          }
        }
      }
    });

    threadObserver.observe(document.body, {
      childList: true,
      subtree: true
    });

    document.addEventListener('click', scheduleThreadScan, true);
    document.addEventListener('keyup', scheduleThreadScan, true);
  }

  function init() {
    attachKeyListener();
    setupAutocompleteObservers();
    setupChannelContextMenuSupport();
    setupThreadWatcher();
    log('Slack autocomplete preload initialized.');
  }

  if (document.readyState === 'loading') {
    window.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
EOF

echo "Created preload.js"

ICON_ARGS=()
if [[ -f "$APP_ICON" ]]; then
  ICON_ARGS+=("--icon=$APP_ICON")
fi

echo "Packaging macOS app with electron-packager..."
npx electron-packager . "$APP_NAME" --platform=darwin --arch="$EP_ARCH" --out=dist --overwrite "${ICON_ARGS[@]}" > /dev/null

APP_PATH="$APP_DIR/dist/${APP_NAME}-darwin-${EP_ARCH}/${APP_NAME}.app"

echo
echo "Done."
echo
echo "To run your custom Slack app:"
echo "  open \"$APP_PATH\""
echo
echo "For dev mode instead of the packaged .app:"
echo "  cd \"$APP_DIR\""
echo "  npm start"

