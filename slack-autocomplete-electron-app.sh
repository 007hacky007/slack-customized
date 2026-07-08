#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SlackAutocompleteElectron"
APP_DIR="$HOME/$APP_NAME"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID="com.example.slack-autocomplete-electron"

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
  "version": "1.0.2",
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
const {
  app,
  BrowserWindow,
  session,
  nativeImage,
  ipcMain,
  shell,
  Notification,
  webContents,
  Menu,
  dialog,
  net,
  powerMonitor
} = require('electron');
const fs = require('fs');
const path = require('path');
const exportCore = require('./export-core.js');

// You can override this when launching by setting SLACK_URL env var.
// Example:
//   SLACK_URL="https://app.slack.com/client/T12345678/C12345678" npm start
const SLACK_URL = process.env.SLACK_URL || 'https://app.slack.com/client';

// Present ourselves as a current, supported Chrome on macOS.
const CHROME_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' +
  'AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/142.0.7444.235 Safari/537.36';
const REGISTERED_PROTOCOL = 'slack';
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
const ACTIVE_NOTIFICATIONS = new Map();
const NOTIFICATION_TAGS = new Map();
const IS_MAC = process.platform === 'darwin';
let isQuitting = false;
const pendingDeepLinks = [];

GPU_SWITCHES.forEach(([name, value]) => {
  if (value) {
    app.commandLine.appendSwitch(name, value);
  } else {
    app.commandLine.appendSwitch(name);
  }
});

const hasSingleInstanceLock = app.requestSingleInstanceLock();
if (!hasSingleInstanceLock) {
  app.quit();
  process.exit(0);
}

collectDeepLinksFromArgv(process.argv).forEach(enqueueDeepLink);

app.on('second-instance', (_event, argv) => {
  const links = collectDeepLinksFromArgv(argv);
  if (links.length) {
    links.forEach(enqueueDeepLink);
  } else {
    showAllWindows();
  }
});

if (IS_MAC) {
  app.on('open-url', (event, url) => {
    event.preventDefault();
    enqueueDeepLink(url);
  });
}

function sendNotificationEvent(targetContentsId, payload) {
  if (!targetContentsId) return;
  const contents = webContents.fromId(targetContentsId);
  if (!contents || contents.isDestroyed()) {
    return;
  }
  try {
    contents.send('slack-autocomplete:notification-event', payload);
  } catch (err) {
    console.warn('Failed to relay notification event to renderer', err);
  }
}

function openExternalUrl(targetUrl) {
  if (!targetUrl) return;
  try {
    shell.openExternal(targetUrl);
  } catch (err) {
    console.warn('Failed to open external URL:', targetUrl, err);
  }
}

function collectDeepLinksFromArgv(argv = []) {
  return argv.filter((arg) => typeof arg === 'string' && arg.startsWith(`${REGISTERED_PROTOCOL}://`));
}

function normalizeSlackDeepLink(targetUrl) {
  try {
    const url = new URL(targetUrl);
    if (url.protocol !== `${REGISTERED_PROTOCOL}:`) {
      return null;
    }

    const host = (url.hostname || url.host || '').toLowerCase();
    const params = url.searchParams;
    const team = params.get('team') || params.get('team_id');
    const channel =
      params.get('id') ||
      params.get('channel') ||
      params.get('channel_id') ||
      params.get('conversation');
    const threadTs =
      params.get('thread_ts') ||
      params.get('message') ||
      params.get('msg') ||
      params.get('ts');

    // Handle common Slack deep link shapes: slack://channel?... or slack://open?... .
    if (!team && !channel) {
      return SLACK_URL;
    }

    let target = `${SLACK_URL}`;
    if (team) {
      target += `/${team}`;
    }

    if (channel) {
      target += `/${channel}`;
    }

    if (threadTs && channel) {
      target += `/thread/${channel}-${threadTs}`;
    }

    // Preserve unknown hosts but still route into the web client.
    if (host === 'app' && params.get('id')) {
      target += `/app/${params.get('id')}`;
    }

    return target;
  } catch (err) {
    console.warn('Failed to parse slack deep link', targetUrl, err);
    return null;
  }
}

function teamOfUrl(targetUrl) {
  const m = /\/client\/(T[A-Z0-9]+)/i.exec(String(targetUrl || ''));
  return m ? m[1] : null;
}

function windowTeam(win) {
  return teamOfUrl(win && win.__slackLastUrl);
}

function focusOrCreateWindow(targetUrl = SLACK_URL) {
  const normalized = isSlackUrl(targetUrl) ? targetUrl : SLACK_URL;
  const windows = BrowserWindow.getAllWindows().filter((win) => win && !win.isDestroyed() && !win.__sawPool);

  // Multi-workspace routing like the official app: a link for workspace X goes
  // to the window already showing X; otherwise the focused/first window
  // switches workspace in place (the same thing the official rail does).
  const targetTeam = teamOfUrl(normalized);
  let target = null;
  if (targetTeam) target = windows.find((w) => windowTeam(w) === targetTeam) || null;
  if (!target) target = BrowserWindow.getFocusedWindow() || windows[0] || null;

  if (target) {
    try {
      // Prefer sending a soft navigation to the existing renderer to avoid full reloads.
      const sameTeam = targetTeam && windowTeam(target) === targetTeam;
      const alreadyThere = sameTeam && normalized === target.__slackLastUrl;
      if (!alreadyThere) {
        const routed = routeUrlInWindow(target, normalized);
        if (!routed) {
          target.loadURL(normalized);
        }
      }
      if (target.isMinimized()) {
        target.restore();
      }
      target.show();
      target.focus();
      return target;
    } catch (err) {
      console.warn('Failed to route deep link to existing window', err);
    }
  }

  return createWindow(normalized);
}

function showAllWindows() {
  const windows = BrowserWindow.getAllWindows().filter((win) => win && !win.isDestroyed() && !win.__sawPool);
  if (windows.length === 0) {
    createWindow();
    return;
  }

  windows.forEach((win) => {
    try {
      if (win.isMinimized && win.isMinimized()) {
        win.restore();
      }

      if (win.showInactive) {
        win.showInactive();
      } else if (typeof win.isVisible === 'function' ? !win.isVisible() : true) {
        win.show();
      }

      win.focus();
    } catch (err) {
      console.warn('Failed to re-show window', err);
    }
  });
}

function bringWindowToFront(win) {
  if (!win || win.isDestroyed()) return;

  try {
    if (typeof app.focus === 'function') {
      app.focus({ steal: true });
    }
  } catch (err) {
    console.warn('Failed to focus app', err);
  }

  try {
    if (win.isMinimized()) {
      win.restore();
    }

    win.show();
    win.moveTop?.();
    win.focus();
  } catch (err) {
    console.warn('Failed to bring window to front', err);
  }
}

function handleDeepLink(targetUrl) {
  const webUrl = normalizeSlackDeepLink(targetUrl) || SLACK_URL;
  focusOrCreateWindow(webUrl);
}

function enqueueDeepLink(url) {
  if (!url || typeof url !== 'string') return;
  pendingDeepLinks.push(url);
  if (app.isReady()) {
    processPendingDeepLinks();
  }
}

function processPendingDeepLinks() {
  while (pendingDeepLinks.length) {
    const link = pendingDeepLinks.shift();
    handleDeepLink(link);
  }
}

function buildClearCacheMenuItems() {
  const configs = [
    {
      label: 'Clear Cache (Keep Login)',
      accelerator: 'CmdOrCtrl+Shift+K',
      preserveSession: true
    },
    {
      label: 'Clear Cache (Full Reset)',
      accelerator: 'CmdOrCtrl+Shift+Delete',
      preserveSession: false
    }
  ];

  return configs.map(({ label, accelerator, preserveSession }) => ({
    label,
    accelerator,
    click: (_menuItem, browserWindow) => {
      clearAppCache(browserWindow, { preserveSession, label });
    }
  }));
}

async function clearAppCache(targetWindow, options = {}) {
  const { preserveSession = false, label = 'Cache' } = options;
  const browserWindow =
    targetWindow && !targetWindow.isDestroyed() ? targetWindow : BrowserWindow.getFocusedWindow();

  try {
    const defaultSession = session.defaultSession;
    if (defaultSession) {
      await defaultSession.clearCache();
      if (!preserveSession) {
        await defaultSession.clearStorageData();
      }
    }

    BrowserWindow.getAllWindows().forEach((win) => {
      if (!win || win.isDestroyed()) {
        return;
      }
      try {
        win.webContents.reloadIgnoringCache();
      } catch (err) {
        console.warn('Failed to reload window after cache clear', err);
      }
    });

    if (dialog && typeof dialog.showMessageBox === 'function') {
      dialog.showMessageBox(browserWindow || null, {
        type: 'info',
        message: `${label} Cleared`,
        detail: preserveSession
          ? 'Cached assets were purged while keeping your Slack login session.'
          : 'Cached assets and local storage were purged; you may need to log back in.',
        buttons: ['OK']
      });
    }
  } catch (err) {
    console.warn('Failed to clear cache:', err);
    if (dialog && typeof dialog.showMessageBox === 'function') {
      dialog.showMessageBox(browserWindow || null, {
        type: 'error',
        message: 'Unable to Clear Cache',
        detail: err?.message || 'Check the logs for details.',
        buttons: ['OK']
      });
    }
  }
}

// --- Persisted app settings (currently just the downloads location) ---
let appSettings = { downloadsDir: null };

function appSettingsPath() {
  return path.join(app.getPath('userData'), 'app-settings.json');
}

function loadAppSettings() {
  try {
    const parsed = JSON.parse(fs.readFileSync(appSettingsPath(), 'utf8'));
    if (parsed && typeof parsed === 'object') appSettings = Object.assign(appSettings, parsed);
  } catch (err) { /* first run */ }
}

function saveAppSettings() {
  try {
    fs.writeFileSync(appSettingsPath(), JSON.stringify(appSettings, null, 2));
  } catch (err) {
    console.warn('Failed to save app settings', err);
  }
}

function effectiveDownloadsDir() {
  return appSettings.downloadsDir || app.getPath('downloads');
}

function uniqueSavePath(dir, filename) {
  const ext = path.extname(filename);
  const base = path.basename(filename, ext);
  let candidate = path.join(dir, filename);
  for (let i = 1; fs.existsSync(candidate) && i < 1000; i++) {
    candidate = path.join(dir, base + ' (' + i + ')' + ext);
  }
  return candidate;
}

async function chooseDownloadsLocation() {
  const res = await dialog.showOpenDialog({
    properties: ['openDirectory', 'createDirectory'],
    defaultPath: effectiveDownloadsDir()
  });
  if (!res.canceled && res.filePaths && res.filePaths[0]) {
    appSettings.downloadsDir = res.filePaths[0];
    saveAppSettings();
    installApplicationMenu();
  }
}

// Signed-in workspaces, reported by the renderer from Slack's own local
// config. Drives the Workspace menu (Cmd+1..9 switching, like the official app).
let knownTeams = [];

function cycleWorkspace(direction) {
  if (knownTeams.length < 2) return;
  const focused = BrowserWindow.getFocusedWindow();
  const currentTeam = focused ? windowTeam(focused) : null;
  const idx = Math.max(0, knownTeams.findIndex((t) => t.id === currentTeam));
  const next = knownTeams[(idx + direction + knownTeams.length) % knownTeams.length];
  if (next) focusOrCreateWindow(`https://app.slack.com/client/${next.id}`);
}

ipcMain.handle('slack-autocomplete:teams', (event, teams) => {
  if (!isSlackSender(event)) throw new Error('teams rejected: untrusted sender');
  const sanitized = (Array.isArray(teams) ? teams : [])
    .filter((t) => t && /^T[A-Z0-9]+$/i.test(String(t.id || '')))
    .slice(0, 20)
    .map((t) => ({ id: String(t.id), name: typeof t.name === 'string' ? t.name.slice(0, 80) : String(t.id) }));
  if (JSON.stringify(sanitized) !== JSON.stringify(knownTeams)) {
    knownTeams = sanitized;
    installApplicationMenu();
  }
  return { ok: true };
});

function installApplicationMenu() {
  if (!Menu || typeof Menu.buildFromTemplate !== 'function') {
    return;
  }

  const template = [
    ...(IS_MAC
      ? [
          {
            label: app.name,
            submenu: [
              { role: 'about' },
              { type: 'separator' },
              ...buildClearCacheMenuItems(),
              {
                label: 'Reset Window State',
                accelerator: 'CmdOrCtrl+Shift+R',
                click: () => resetWindowState()
              },
              { type: 'separator' },
              { role: 'services' },
              { type: 'separator' },
              { role: 'hide' },
              { role: 'hideOthers' },
              { role: 'unhide' },
              { type: 'separator' },
              { role: 'quit' }
            ]
          }
        ]
      : []),
    {
      label: 'File',
      submenu: [
        ...buildClearCacheMenuItems(),
        {
          label: 'Reset Window State',
          accelerator: 'CmdOrCtrl+Shift+R',
          click: () => resetWindowState()
        },
        { type: 'separator' },
        {
          label: 'Export Channel as JSON...',
          accelerator: 'CmdOrCtrl+Shift+E',
          click: (_item, focusedWindow) => {
            const w = focusedWindow || BrowserWindow.getFocusedWindow();
            if (w) w.webContents.send('slack-autocomplete:export-channel');
          }
        },
        {
          label: 'Downloads',
          accelerator: 'CmdOrCtrl+Shift+J',
          click: (_item, focusedWindow) => {
            const w = focusedWindow || BrowserWindow.getFocusedWindow();
            if (w) w.webContents.send('slack-autocomplete:toggle-downloads');
          }
        },
        {
          label: 'Downloads Location',
          submenu: [
            { label: appSettings.downloadsDir || 'System Downloads Folder', enabled: false },
            { type: 'separator' },
            { label: 'Choose...', click: () => { chooseDownloadsLocation(); } },
            {
              label: 'Use System Downloads Folder',
              enabled: Boolean(appSettings.downloadsDir),
              click: () => {
                appSettings.downloadsDir = null;
                saveAppSettings();
                installApplicationMenu();
              }
            }
          ]
        },
        { type: 'separator' },
        {
          label: 'Export Channel List',
          submenu: [
            {
              label: 'Public Channels...',
              click: (_item, focusedWindow) => {
                const w = focusedWindow || BrowserWindow.getFocusedWindow();
                if (w) w.webContents.send('slack-autocomplete:export-channel-list', { types: 'public_channel' });
              }
            },
            {
              label: 'Private Channels...',
              click: (_item, focusedWindow) => {
                const w = focusedWindow || BrowserWindow.getFocusedWindow();
                if (w) w.webContents.send('slack-autocomplete:export-channel-list', { types: 'private_channel' });
              }
            },
            {
              label: 'All Channels...',
              click: (_item, focusedWindow) => {
                const w = focusedWindow || BrowserWindow.getFocusedWindow();
                if (w) w.webContents.send('slack-autocomplete:export-channel-list', { types: 'public_channel,private_channel' });
              }
            }
          ]
        },
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
        { type: 'separator' },
        IS_MAC ? { role: 'close' } : { role: 'quit' }
      ]
    },
    {
      label: 'Edit',
      submenu: [
        { role: 'undo' },
        { role: 'redo' },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        ...(IS_MAC
          ? [
              { role: 'pasteAndMatchStyle' },
              { role: 'delete' },
              { role: 'selectAll' },
              { type: 'separator' },
              {
                label: 'Speech',
                submenu: [{ role: 'startspeaking' }, { role: 'stopspeaking' }]
              }
            ]
          : [{ role: 'delete' }, { type: 'separator' }, { role: 'selectAll' }])
      ]
    },
    {
      label: 'View',
      submenu: [
        { role: 'reload' },
        { role: 'forcereload' },
        { role: 'toggledevtools' },
        { type: 'separator' },
        { role: 'resetzoom' },
        { role: 'zoomin' },
        { role: 'zoomout' },
        { type: 'separator' },
        { role: 'togglefullscreen' }
      ]
    },
    {
      label: 'Workspace',
      submenu: [
        ...knownTeams.map((team, idx) => ({
          label: team.name || team.id,
          accelerator: idx < 9 ? `CmdOrCtrl+${idx + 1}` : undefined,
          click: () => focusOrCreateWindow(`https://app.slack.com/client/${team.id}`)
        })),
        ...(knownTeams.length ? [{ type: 'separator' }] : []),
        {
          label: 'Select Next Workspace',
          accelerator: 'Ctrl+Tab',
          enabled: knownTeams.length > 1,
          click: () => cycleWorkspace(1)
        },
        {
          label: 'Select Previous Workspace',
          accelerator: 'Ctrl+Shift+Tab',
          enabled: knownTeams.length > 1,
          click: () => cycleWorkspace(-1)
        },
        { type: 'separator' },
        {
          label: 'Sign in to Another Workspace...',
          click: () => focusOrCreateWindow('https://slack.com/signin')
        }
      ]
    },
    // The standard window menu role is required for macOS to append its
    // system items (Move & Resize / split-screen tiling on Sequoia).
    ...(IS_MAC
      ? [{ role: 'windowMenu' }]
      : [{
          label: 'Window',
          submenu: [{ role: 'minimize' }, { role: 'zoom' }, { role: 'close' }]
        }]),
    {
      role: 'help',
      submenu: [
        {
          label: 'Learn More',
          click: () => openExternalUrl('https://slack.com/help/categories/360000049423')
        }
      ]
    }
  ];

  const menu = Menu.buildFromTemplate(template);
  Menu.setApplicationMenu(menu);
}

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

function isSlackAppNavigationUrl(targetUrl) {
  try {
    const { pathname } = new URL(targetUrl);
    if (!isSlackUrl(targetUrl)) {
      return false;
    }

    return pathname === '/client' || pathname.startsWith('/client/');
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
        if (typeof url === 'string' && isSlackAppNavigationUrl(url) && !seen.has(url)) {
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
    if (!win || win.isDestroyed() || win.__sawPool) {
      return;
    }
    const url = typeof win.__slackLastUrl === 'string' ? win.__slackLastUrl : SLACK_URL;
    const normalized = isSlackAppNavigationUrl(url) ? url : SLACK_URL;
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

function resetWindowState() {
  const filePath = getWindowStateFilePath();
  let deleted = false;

  try {
    if (windowStateSaveTimer) {
      clearTimeout(windowStateSaveTimer);
      windowStateSaveTimer = null;
    }

    if (fs.existsSync(filePath)) {
      fs.unlinkSync(filePath);
      deleted = true;
    }
  } catch (err) {
    console.warn('Failed to delete window state file:', err);
  }

  const windows = BrowserWindow.getAllWindows().filter((win) => win && !win.isDestroyed() && !win.__sawPool);
  const primary = windows[0];

  windows.slice(1).forEach((win) => {
    try {
      win.destroy();
    } catch (err) {
      console.warn('Failed to close extra window during reset', err);
    }
  });

  try {
    if (primary && !primary.isDestroyed()) {
      primary.__slackLastUrl = SLACK_URL;
      primary.loadURL(SLACK_URL);
      primary.show();
      primary.focus();
    } else {
      createWindow(SLACK_URL);
    }
  } catch (err) {
    console.warn('Failed to reload primary window during reset', err);
  }

  if (dialog && typeof dialog.showMessageBox === 'function') {
    const detail = deleted
      ? `Removed window state file at: ${filePath}`
      : `No window state file was found at: ${filePath}`;

    dialog.showMessageBox(primary || null, {
      type: 'info',
      message: 'Window state has been reset',
      detail,
      buttons: ['OK']
    });
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
  win.__slackLastUrl = isSlackAppNavigationUrl(initialUrl) ? initialUrl : SLACK_URL;

  const updateLastUrl = () => {
    const currentUrl = win.webContents.getURL();
    if (isSlackAppNavigationUrl(currentUrl)) {
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

function buildWindowOptions(overrides) {
  const iconImage = getIconImage();
  const base = {
    width: 1200,
    height: 800,
    icon: iconImage,
    // Official-app look: no native title bar; the traffic lights sit inside
    // the Slack UI (the preload pads Slack's top nav to make room for them).
    ...(process.platform === 'darwin' ? { titleBarStyle: 'hiddenInset' } : {}),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      nativeWindowOpen: true
    }
  };
  return Object.assign(base, overrides || {});
}

// Per-WINDOW pop-out mode, keyed by webContents id and fetched by the preload
// over IPC. Never use process arguments for this: Electron shares renderer
// PROCESSES between same-origin windows, so a process-level flag leaks the
// pop-out mode into the main window (its sidebar vanished) and pop-outs that
// land in an unflagged process render the full client.
const WINDOW_MODES = new Map(); // webContents.id -> { mode: 'thread'|'channel', threadUrl? }

ipcMain.handle('slack-autocomplete:window-mode', (event) => {
  if (!isSlackSender(event)) throw new Error('window-mode rejected: untrusted sender');
  return WINDOW_MODES.get(event.sender.id) || { mode: 'normal' };
});

// --- Pop-out window pool -----------------------------------------------
// The official app pre-creates hidden windows so "Open in new window" is
// instant (visible in its CDP target list as pooled about:blank pages). We do
// the same: one hidden window boots the client in the background; adopting it
// only needs a client-side route change instead of a cold boot.
let popoutPool = [];
const POPOUT_READY_WAITERS = new Map(); // webContents.id -> show()
// 'browser-window-created' fires synchronously inside the BrowserWindow
// constructor - before createPoolWindow() can stamp __sawPool on the new
// window - so the global handler needs this module-level flag to know it is
// looking at a pool window and must skip state tracking / hide-on-close.
let constructingPoolWindow = false;

function createPoolWindow() {
  if (isQuitting) return null;
  const win = createWindow(SLACK_URL, { show: false }, { mode: 'normal', pool: true });
  // Chromium throttles timers in hidden windows, which would slow the pool
  // window's background boot - the whole point of having it.
  try { win.webContents.setBackgroundThrottling(false); } catch (err) { /* ignore */ }
  win.__sawPool = true;
  popoutPool.push(win);
  win.on('closed', () => { popoutPool = popoutPool.filter((w) => w !== win); });
  return win;
}

function adoptPopoutWindow(kind, targetUrl, threadUrl, size) {
  const win = popoutPool.shift();
  setTimeout(() => { try { createPoolWindow(); } catch (err) { /* ignore */ } }, 4000); // refill off the hot path
  if (!win || win.isDestroyed()) return null;
  win.__sawPool = false;
  installHideOnClose(win);
  // Once adopted it is a real pop-out; track it like cold-booted pop-outs
  // (createWindow attaches tracking for every non-pool window).
  attachWindowStateTracking(win, targetUrl);
  WINDOW_MODES.set(win.webContents.id, kind === 'thread' ? { mode: 'thread', threadUrl } : { mode: 'channel' });
  if (size) { try { win.setSize(size.width, size.height); win.center(); } catch (err) { /* ignore */ } }
  try {
    win.webContents.send('slack-autocomplete:adopt-popout', { mode: kind, url: targetUrl, threadUrl });
  } catch (err) {
    return null;
  }
  const show = () => { if (!win.isDestroyed() && !win.isVisible()) { win.show(); win.focus(); } };
  POPOUT_READY_WAITERS.set(win.webContents.id, show);
  setTimeout(show, 900); // fallback if the ready signal never arrives
  return win;
}

ipcMain.handle('slack-autocomplete:popout-ready', (event) => {
  const show = POPOUT_READY_WAITERS.get(event.sender.id);
  if (show) { POPOUT_READY_WAITERS.delete(event.sender.id); show(); }
  return { ok: true };
});

function isThreadUrl(targetUrl) {
  try {
    return isSlackUrl(targetUrl) && new URL(targetUrl).pathname.includes('/thread/');
  } catch (err) {
    return false;
  }
}

// A fresh window cannot cold-load a /thread/ deep link (Slack shows an error
// page - the client must boot on a workspace/channel route first). So the
// pop-out boots at the channel URL and the preload opens the thread client-
// side once booted; the thread URL is passed as a renderer process argument.
function threadUrlToChannelUrl(threadUrl) {
  try {
    const u = new URL(threadUrl);
    u.pathname = u.pathname.replace(/\/thread\/.*$/, '');
    u.hash = '';
    u.search = '';
    return u.toString();
  } catch (err) {
    return threadUrl;
  }
}

function openThreadPopout(targetUrl) {
  const adopted = adoptPopoutWindow('thread', String(targetUrl), String(targetUrl), { width: 520, height: 780 });
  if (adopted) return adopted;
  // No warm pool window: cold-boot fallback (channel URL first; a fresh
  // window cannot cold-load a /thread/ deep link).
  const channelUrl = threadUrlToChannelUrl(targetUrl);
  return createWindow(channelUrl, { width: 520, height: 780 }, { mode: 'thread', threadUrl: String(targetUrl) });
}

function triggerDownload(url) {
  if (!url) return;
  const windows = BrowserWindow.getAllWindows().filter((w) => w && !w.isDestroyed() && !w.__sawPool);
  const target = windows[0] || createWindow(SLACK_URL);
  try {
    target.webContents.downloadURL(url);
  } catch (err) {
    console.warn('Failed to start download for', url, err);
  }
}

// --- Downloads tracking (backs the in-app downloads panel, like the official
// app's downloads pane): every session download is tracked and progress is
// broadcast to all Slack windows. ---
const DOWNLOADS_HISTORY_LIMIT = 50;
const downloadsHistory = [];   // newest first
const activeDownloadItems = new Map(); // id -> DownloadItem

function downloadSnapshot(entry) {
  return {
    id: entry.id,
    filename: entry.filename,
    path: entry.path,
    state: entry.state,           // progressing | completed | cancelled | interrupted
    receivedBytes: entry.receivedBytes,
    totalBytes: entry.totalBytes,
    startedAt: entry.startedAt
  };
}

function broadcastDownloadEvent(entry) {
  const payload = downloadSnapshot(entry);
  for (const win of BrowserWindow.getAllWindows()) {
    if (win && !win.isDestroyed()) {
      try { win.webContents.send('slack-autocomplete:download-event', payload); } catch (err) { /* ignore */ }
    }
  }
}

let downloadCounter = 0;
function installDownloadTracking(ses) {
  ses.on('will-download', (_event, item) => {
    // Honor the configured downloads location (File > Downloads Location)
    // and avoid clobbering existing files, like the official app.
    try {
      const dir = effectiveDownloadsDir();
      fs.mkdirSync(dir, { recursive: true });
      item.setSavePath(uniqueSavePath(dir, item.getFilename()));
    } catch (err) {
      console.warn('Failed to set download save path', err);
    }
    const id = 'dl' + (++downloadCounter);
    const entry = {
      id,
      filename: item.getFilename(),
      path: '',
      state: 'progressing',
      receivedBytes: 0,
      totalBytes: item.getTotalBytes(),
      startedAt: Date.now()
    };
    downloadsHistory.unshift(entry);
    if (downloadsHistory.length > DOWNLOADS_HISTORY_LIMIT) downloadsHistory.pop();
    activeDownloadItems.set(id, item);
    broadcastDownloadEvent(entry);

    item.on('updated', () => {
      entry.filename = item.getFilename();
      entry.path = item.getSavePath();
      entry.receivedBytes = item.getReceivedBytes();
      entry.totalBytes = item.getTotalBytes();
      entry.state = item.isPaused() ? 'progressing' : item.getState();
      broadcastDownloadEvent(entry);
    });
    item.once('done', (_e, state) => {
      entry.state = state; // completed | cancelled | interrupted
      entry.path = item.getSavePath();
      entry.receivedBytes = item.getReceivedBytes();
      entry.totalBytes = item.getTotalBytes();
      activeDownloadItems.delete(id);
      broadcastDownloadEvent(entry);
    });
  });
}

function findDownloadEntry(id) {
  return downloadsHistory.find((d) => d.id === id) || null;
}

ipcMain.handle('slack-autocomplete:downloads:list', (event) => {
  if (!isSlackSender(event)) throw new Error('downloads rejected: untrusted sender');
  return downloadsHistory.map(downloadSnapshot);
});

ipcMain.handle('slack-autocomplete:downloads:show-in-folder', (event, id) => {
  if (!isSlackSender(event)) throw new Error('downloads rejected: untrusted sender');
  const entry = findDownloadEntry(id);
  if (entry && entry.path && entry.state === 'completed') shell.showItemInFolder(entry.path);
  return { ok: true };
});

ipcMain.handle('slack-autocomplete:downloads:open', async (event, id) => {
  if (!isSlackSender(event)) throw new Error('downloads rejected: untrusted sender');
  const entry = findDownloadEntry(id);
  if (entry && entry.path && entry.state === 'completed') {
    const err = await shell.openPath(entry.path);
    return { ok: !err, error: err || undefined };
  }
  return { ok: false };
});

ipcMain.handle('slack-autocomplete:downloads:cancel', (event, id) => {
  if (!isSlackSender(event)) throw new Error('downloads rejected: untrusted sender');
  const item = activeDownloadItems.get(id);
  if (item) { try { item.cancel(); } catch (err) { /* ignore */ } }
  return { ok: true };
});

ipcMain.handle('slack-autocomplete:downloads:clear', (event) => {
  if (!isSlackSender(event)) throw new Error('downloads rejected: untrusted sender');
  for (let i = downloadsHistory.length - 1; i >= 0; i--) {
    if (downloadsHistory[i].state !== 'progressing') downloadsHistory.splice(i, 1);
  }
  return downloadsHistory.map(downloadSnapshot);
});

// Raw file URLs (files.slack.com / files-pri): the official app never renders
// these in a window - they are downloads.
function isSlackFileUrl(targetUrl) {
  try {
    const u = new URL(targetUrl);
    if (!isSlackUrl(targetUrl)) return false;
    return u.hostname === 'files.slack.com'
      || u.hostname.startsWith('files.')
      || u.pathname.startsWith('/files-pri/')
      || u.pathname.startsWith('/files-tmb/');
  } catch (err) {
    return false;
  }
}

function applyWindowPolicies(win) {
  win.webContents.session.setUserAgent(CHROME_UA);
  win.webContents.setWindowOpenHandler(({ url, disposition }) => {
    // Downloads that try to open a new window get routed to download manager instead of spawning a window.
    if (disposition === 'save-to-disk' || isSlackFileUrl(url)) {
      triggerDownload(url);
      return { action: 'deny' };
    }

    if (isSlackUrl(url)) {
      // Official-app behavior: when the Slack client asks for a new window
      // (conversation pop-outs, huddle windows, file viewers, auth popups),
      // it gets a real one. Deep links and workspace switching still reuse
      // windows via focusOrCreateWindow elsewhere.
      return {
        action: 'allow',
        overrideBrowserWindowOptions: buildWindowOptions()
      };
    }

    // Non-Slack URLs: open in system browser, never inside the app.
    openExternalUrl(url);
    return { action: 'deny' };
  });

  // Child windows opened with action:'allow' need the same policies, plus
  // URL tracking so team-aware routing can find them.
  win.webContents.on('did-create-window', (child, details) => {
    try {
      applyWindowPolicies(child);
      child.__slackLastUrl = (details && details.url) || '';
      const trackChildUrl = (_e, u) => { if (typeof u === 'string') child.__slackLastUrl = u; };
      child.webContents.on('did-navigate', trackChildUrl);
      child.webContents.on('did-navigate-in-page', trackChildUrl);
    } catch (err) {
      console.warn('Failed to apply policies to child window', err);
    }
  });

  win.webContents.on('will-navigate', (event, url) => {
    if (isSlackFileUrl(url)) {
      // In-window clicks on raw file links become tracked downloads instead
      // of replacing the Slack client with the file contents.
      event.preventDefault();
      triggerDownload(url);
      return;
    }
    if (!isSlackUrl(url)) {
      event.preventDefault();
      openExternalUrl(url);
    }
  });
}

function routeUrlInWindow(win, targetUrl) {
  if (!win || win.isDestroyed()) {
    return false;
  }

  try {
    win.webContents.send('slack-autocomplete:open-url', targetUrl);
    return true;
  } catch (err) {
    console.warn('Failed to send soft navigation; will fall back to loadURL', err);
    return false;
  }
}

function registerProtocolHandler() {
  try {
    if (process.defaultApp) {
      const target = process.argv[1] ? path.resolve(process.argv[1]) : undefined;
      app.setAsDefaultProtocolClient(REGISTERED_PROTOCOL, process.execPath, target ? [target] : undefined);
    } else {
      app.setAsDefaultProtocolClient(REGISTERED_PROTOCOL);
    }
  } catch (err) {
    console.warn('Failed to register protocol handler', err);
  }
}

function installHideOnClose(win) {
  if (!win || win.__slackHidePatch) {
    return;
  }

  win.__slackHidePatch = true;

  win.on('close', (event) => {
    if (isQuitting || win.isDestroyed()) {
      return;
    }

    // Let secondary windows actually close so window-state.json stays accurate.
    const openWindows = BrowserWindow.getAllWindows().filter((w) => w && !w.isDestroyed() && !w.__sawPool);
    const hasOtherWindows = openWindows.some((w) => w !== win && w.isVisible());
    if (hasOtherWindows) {
      return;
    }

    event.preventDefault();

    try {
      if (win.isFullScreen && win.isFullScreen()) {
        win.setFullScreen(false);
      }

      if (win.isMinimized && win.isMinimized()) {
        win.restore();
      }

      win.hide();
      scheduleWindowStateSave();
    } catch (err) {
      console.warn('Failed to hide window on close', err);
    }
  });
}

function createWindow(initialUrl = SLACK_URL, windowOverrides, windowMode) {
  const isPool = Boolean(windowMode && windowMode.pool);
  constructingPoolWindow = isPool;
  const win = new BrowserWindow(buildWindowOptions(windowOverrides));
  constructingPoolWindow = false;
  if (windowMode && windowMode.mode && windowMode.mode !== 'normal') {
    const wcId = win.webContents.id;
    WINDOW_MODES.set(wcId, windowMode);
    win.webContents.once('destroyed', () => WINDOW_MODES.delete(wcId));
  }
  applyWindowPolicies(win);
  if (!isPool) {
    // Pool windows stay hidden and untracked: no hide-on-close, and they must
    // not be persisted into window-state (they would reappear at next launch).
    installHideOnClose(win);
    attachWindowStateTracking(win, initialUrl);
  }
  win.loadURL(initialUrl);
  return win;
}

ipcMain.handle('slack-autocomplete:open-window', async (_event, targetUrl) => {
  if (typeof targetUrl !== 'string') {
    return { status: 'error', reason: 'invalid-url' };
  }

  if (!isSlackUrl(targetUrl)) {
    openExternalUrl(targetUrl);
    return { status: 'external-opened' };
  }

  if (isThreadUrl(targetUrl)) {
    openThreadPopout(targetUrl);
  } else if (isSlackAppNavigationUrl(targetUrl)) {
    // Channel "Open in new window": official shows just the channel view
    // (no rail/sidebar/top nav) - the preload learns the mode over IPC.
    if (!adoptPopoutWindow('channel', targetUrl, null, null)) {
      createWindow(targetUrl, undefined, { mode: 'channel' });
    }
  } else {
    createWindow(targetUrl);
  }
  return { status: 'created' };
});

ipcMain.handle('slack-autocomplete:notify', async (event, payload = {}) => {
  if (!Notification || !Notification.isSupported?.()) {
    return { status: 'unsupported' };
  }

  const { title, options = {}, id } = payload;
  if (typeof title !== 'string' || !title.trim()) {
    return { status: 'error', reason: 'missing-title' };
  }

  const notificationOptions = {
    title: title.trim(),
    body: typeof options.body === 'string' ? options.body : '',
    subtitle: typeof options.subtitle === 'string' ? options.subtitle : undefined,
    silent: Boolean(options.silent),
    urgency: options.urgency || 'normal',
    timeoutType: options.requireInteraction ? 'never' : 'default',
    icon: getIconImage()
  };
  if (process.platform === 'darwin' && options.hasReply) {
    notificationOptions.hasReply = true;
    notificationOptions.replyPlaceholder = typeof options.replyPlaceholder === 'string' && options.replyPlaceholder
      ? options.replyPlaceholder
      : 'Reply...';
  }

  const notification = new Notification(notificationOptions);
  const contentsId = event.sender.id;
  const key = `${contentsId}:${id}`;

  // Replace-by-tag (like the DOM Notification `tag` semantics the official
  // client relies on): a new notification for the same conversation closes
  // the previous banner instead of stacking a duplicate.
  const tag = typeof options.tag === 'string' && options.tag ? options.tag : null;
  const tagKey = tag ? `${contentsId}:tag:${tag}` : null;
  if (tagKey) {
    const previousKey = NOTIFICATION_TAGS.get(tagKey);
    if (previousKey) {
      const previous = ACTIVE_NOTIFICATIONS.get(previousKey);
      if (previous) {
        try { previous.close(); } catch (err) { /* ignore */ }
        ACTIVE_NOTIFICATIONS.delete(previousKey);
      }
    }
    NOTIFICATION_TAGS.set(tagKey, key);
  }
  ACTIVE_NOTIFICATIONS.set(key, notification);

  notification.on('click', () => {
    sendNotificationEvent(contentsId, { id, type: 'click' });
    const contents = webContents.fromId(contentsId);
    const win = contents ? BrowserWindow.fromWebContents(contents) : null;
    if (win) {
      bringWindowToFront(win);
    }
  });

  notification.on('reply', (_replyEvent, reply) => {
    sendNotificationEvent(contentsId, { id, type: 'reply', reply: String(reply || '') });
    ACTIVE_NOTIFICATIONS.delete(key);
    if (tagKey && NOTIFICATION_TAGS.get(tagKey) === key) NOTIFICATION_TAGS.delete(tagKey);
  });

  notification.on('close', () => {
    sendNotificationEvent(contentsId, { id, type: 'close' });
    ACTIVE_NOTIFICATIONS.delete(key);
    if (tagKey && NOTIFICATION_TAGS.get(tagKey) === key) NOTIFICATION_TAGS.delete(tagKey);
  });

  try {
    notification.show();
    return { status: 'shown' };
  } catch (err) {
    console.warn('Failed to display notification:', err);
    ACTIVE_NOTIFICATIONS.delete(key);
    return { status: 'error', reason: 'show-failed' };
  }
});

ipcMain.handle('slack-autocomplete:notification-close', async (event, id) => {
  const key = `${event.sender.id}:${id}`;
  const notification = ACTIVE_NOTIFICATIONS.get(key);
  if (notification) {
    notification.close();
    ACTIVE_NOTIFICATIONS.delete(key);
  }
  return { status: 'closed' };
});

ipcMain.handle('slack-autocomplete:update-badge', (_event, text) => {
  if (process.platform === 'darwin' && app.dock) {
    // Ensure text is a string
    const badgeText = typeof text === 'string' ? text : '';
    app.dock.setBadge(badgeText);
  }
  return { status: 'ok' };
});

ipcMain.handle('slack-autocomplete:context-menu', (event, payload = {}) => {
  const browserWindow = BrowserWindow.fromWebContents(event.sender);
  if (!browserWindow) {
    return { status: 'no-window' };
  }

  const contents = event.sender;
  const { selectionText = '', isEditable = false, hasSelection = false, canGoBack: rendererCanGoBack = false } = payload;
  const template = [];

  if (typeof payload.threadUrl === 'string' && isThreadUrl(payload.threadUrl)) {
    const threadUrl = payload.threadUrl;
    template.push({
      label: 'Open Thread in New Window',
      click: () => openThreadPopout(threadUrl)
    }, { type: 'separator' });
  }

  const canGoBack = Boolean(rendererCanGoBack) || (contents && contents.canGoBack && contents.canGoBack());

  template.push({
    label: 'Go Back',
    accelerator: 'Esc',
    enabled: canGoBack,
    click: () => {
      if (!canGoBack) return;
      try {
        if (contents && contents.canGoBack && contents.canGoBack()) {
          contents.goBack();
        } else {
          contents?.send('slack-autocomplete:attachment-go-back');
        }
      } catch (err) {
        console.warn('Failed to go back from context menu', err);
      }
    }
  }, { type: 'separator' });

  if (isEditable) {
    template.push({ role: 'cut' });
  }

  if (hasSelection || selectionText) {
    template.push({ role: 'copy' });
  }

  if (isEditable) {
    template.push({ role: 'paste' }, { role: 'selectAll' });
  } else {
    template.push({ role: 'selectAll' });
  }

  if (!template.length) {
    return { status: 'no-items' };
  }

  try {
    const menu = Menu.buildFromTemplate(template);
    menu.popup({ window: browserWindow, positioningItem: 0 });
    return { status: 'shown' };
  } catch (err) {
    console.warn('Failed to show context menu:', err);
    return { status: 'error' };
  }
});

ipcMain.handle('slack-autocomplete:get-idle-time', () => {
  return powerMonitor.getSystemIdleTime();
});

// --- Channel export: streaming save to a temp file, atomic rename on commit ---
const exportSaveSessions = new Map();
let exportSaveCounter = 0;

function isSlackSender(event) {
  try {
    const url = (event.senderFrame && event.senderFrame.url)
      || (event.sender && typeof event.sender.getURL === 'function' && event.sender.getURL())
      || '';
    return /^https:\/\/[a-z0-9.-]*\.slack\.com(\/|$)/i.test(url);
  } catch (e) { return false; }
}

// Channel export: perform the Slack web-API call from the main process via net.fetch.
// Renderer fetch to the team API host (e.g. cdn77.slack.com) is blocked by cross-origin
// CORS in the preload's isolated world; net.fetch is not subject to page CORS and uses the
// default session cookie jar, so the HttpOnly `d` auth cookie is sent automatically.
ipcMain.handle('slack-autocomplete:api-call', async (event, payload = {}) => {
  if (!isSlackSender(event)) throw new Error('api-call rejected: untrusted sender');
  const { apiBase, teamId, token, method, params } = payload;
  if (typeof apiBase !== 'string' || typeof method !== 'string') throw new Error('api-call: bad arguments');
  // Harden against SSRF / credential exfiltration: the renderer supplies apiBase + method,
  // and this request carries the auth token + session cookies. Confine the destination to
  // Slack hosts and a well-formed method name, and build the URL via the URL parser (no
  // string concatenation) so a compromised renderer cannot point it at an arbitrary host.
  if (!/^[a-zA-Z][a-zA-Z0-9._]*$/.test(method)) throw new Error('api-call: bad method');
  let url;
  try {
    url = new URL(method, apiBase);
  } catch (e) {
    throw new Error('api-call: bad apiBase');
  }
  const host = url.hostname.replace(/\.$/, '');
  if (url.protocol !== 'https:' || !/^([a-z0-9-]+\.)*slack\.com$/i.test(host)) {
    throw new Error('api-call: host not permitted');
  }
  url.searchParams.set('slack_route', String(teamId || ''));
  const body = new URLSearchParams();
  body.append('token', token);
  for (const [k, v] of Object.entries(params || {})) {
    body.append(k, typeof v === 'boolean' ? String(v) : String(v));
  }
  const resp = await net.fetch(url.toString(), {
    method: 'POST',
    body,
    credentials: 'include',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8' }
  });
  let json = null;
  try { json = await resp.json(); } catch (e) { json = null; }
  return { status: resp.status, retryAfter: resp.headers.get('retry-after'), json };
});

ipcMain.handle('slack-autocomplete:save-export:begin', async (event, payload = {}) => {
  if (!isSlackSender(event)) throw new Error('export save rejected: untrusted sender');
  // allowText: offer a Plain Text filter next to JSON; the format the user picks in
  // the save dialog (via the chosen extension) is returned to the renderer.
  const allowText = payload.allowText === true;
  const safe = exportCore.sanitizeExportFilename(payload.suggestedName || 'slack-export.json');
  const win = BrowserWindow.fromWebContents(event.sender);
  const defaultPath = path.join(app.getPath('downloads'), safe);
  const filters = allowText
    ? [{ name: 'JSON', extensions: ['json'] }, { name: 'Plain Text', extensions: ['txt'] }]
    : [{ name: 'JSON', extensions: ['json'] }];
  const res = await dialog.showSaveDialog(win, { defaultPath, filters });
  if (res.canceled || !res.filePath) return { canceled: true };
  const finalPath = res.filePath;
  const format = (allowText && /\.txt$/i.test(finalPath)) ? 'txt' : 'json';
  const tmpPath = finalPath + '.partial';
  const stream = fs.createWriteStream(tmpPath, { encoding: 'utf8' });
  const token = 'exp' + (++exportSaveCounter);
  exportSaveSessions.set(token, { stream, tmpPath, finalPath });
  const cleanupOnDestroy = () => {
    const s = exportSaveSessions.get(token);
    if (!s) return;
    try { s.stream.end(() => {}); } catch (e) { /* ignore */ }
    fs.promises.unlink(s.tmpPath).catch(() => {});
    exportSaveSessions.delete(token);
  };
  event.sender.once('destroyed', cleanupOnDestroy);
  return { ok: true, token, format };
});

ipcMain.handle('slack-autocomplete:save-export:write', async (event, payload = {}) => {
  if (!isSlackSender(event)) throw new Error('export save rejected: untrusted sender');
  const s = exportSaveSessions.get(payload.token);
  if (!s) throw new Error('unknown export token');
  await new Promise((resolve, reject) => {
    s.stream.write(payload.chunk, (err) => (err ? reject(err) : resolve()));
  });
  return { ok: true };
});

ipcMain.handle('slack-autocomplete:save-export:commit', async (event, payload = {}) => {
  if (!isSlackSender(event)) throw new Error('export save rejected: untrusted sender');
  const s = exportSaveSessions.get(payload.token);
  if (!s) throw new Error('unknown export token');
  await new Promise((resolve, reject) => s.stream.end((err) => (err ? reject(err) : resolve())));
  await fs.promises.rename(s.tmpPath, s.finalPath);
  exportSaveSessions.delete(payload.token);
  return { saved: true, path: s.finalPath };
});

ipcMain.handle('slack-autocomplete:save-export:abort', async (event, payload = {}) => {
  if (!isSlackSender(event)) throw new Error('export save rejected: untrusted sender');
  const s = exportSaveSessions.get(payload.token);
  if (!s) return { ok: true };
  try { await new Promise((resolve) => s.stream.end(() => resolve())); } catch (e) { /* ignore */ }
  try { await fs.promises.unlink(s.tmpPath); } catch (e) { /* ignore */ }
  exportSaveSessions.delete(payload.token);
  return { ok: true };
});

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

ipcMain.handle('slack-autocomplete:open-external', async (_event, targetUrl) => {
  if (typeof targetUrl !== 'string' || !targetUrl.trim()) {
    return { status: 'error', reason: 'invalid-url' };
  }

  openExternalUrl(targetUrl);
  return { status: 'opened' };
});

// Permissions the Slack client legitimately needs. 'media' (microphone +
// camera) and 'display-capture' make huddles and calls work like the
// official app; the rest were already granted.
const SLACK_ALLOWED_PERMISSIONS = new Set([
  'idle-detection',
  'notifications',
  'media',
  'audioCapture',
  'videoCapture',
  'display-capture',
  'speaker-selection',
  'fullscreen'
]);

// Strict hostname check for permission grants: a URL merely containing the
// substring "slack.com" (e.g. https://evil.com/slack.com) must not qualify.
function isSlackHostUrl(rawUrl) {
  try {
    const u = new URL(rawUrl);
    if (u.protocol !== 'https:') return false;
    const h = u.hostname.toLowerCase().replace(/\.$/, '');
    return h === 'slack.com' || h.endsWith('.slack.com');
  } catch (err) {
    return false;
  }
}

function installPermissionHandlers(ses) {
  ses.setPermissionRequestHandler((wc, permission, callback) => {
    if (isSlackHostUrl(wc.getURL()) && SLACK_ALLOWED_PERMISSIONS.has(permission)) {
      return callback(true);
    }
    callback(false);
  });

  ses.setPermissionCheckHandler((_wc, permission, requestingOrigin) => {
    return isSlackHostUrl(requestingOrigin) && SLACK_ALLOWED_PERMISSIONS.has(permission);
  });

  // Screen sharing for huddles via the native macOS picker (same UX as the
  // official app). The handler callback only runs when the system picker is
  // unavailable; never silently hand over a screen without user selection.
  try {
    ses.setDisplayMediaRequestHandler((_request, callback) => {
      callback({});
    }, { useSystemPicker: true });
  } catch (err) {
    console.warn('Failed to install display media handler', err);
  }
}

app.whenReady().then(() => {
  // Global default UA (covers auth popups etc.).
  session.defaultSession.setUserAgent(CHROME_UA);
  loadAppSettings();
  installPermissionHandlers(session.defaultSession);
  installDownloadTracking(session.defaultSession);
  registerProtocolHandler();
  installApplicationMenu();

  const dockIcon = getIconImage();
  if (dockIcon && app.dock) {
    app.dock.setIcon(dockIcon);
  }

  const initialWindows = loadWindowState();
  const urlsToOpen = initialWindows.length ? initialWindows : [SLACK_URL];
  urlsToOpen.forEach((url) => createWindow(url));

  // Warm the pop-out pool once the main window has had a head start.
  setTimeout(() => { try { createPoolWindow(); } catch (err) { /* ignore */ } }, 6000);

  processPendingDeepLinks();

  app.on('activate', () => {
    showAllWindows();
  });
});

app.on('browser-window-created', (_event, window) => {
  applyWindowPolicies(window);
  if (constructingPoolWindow) {
    // Pool windows stay hidden and untracked; tracking one persists its URL
    // into window-state.json and a ghost second window opens at next launch.
    window.__sawPool = true;
    return;
  }
  attachWindowStateTracking(window);
  installHideOnClose(window);
});

app.on('before-quit', () => {
  isQuitting = true;
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

  const { ipcRenderer } = require('electron');
  const exportCore = require('./export-core.js');

  const DEBUG = (() => {
    try {
      return Boolean(window?.localStorage?.getItem('slackAutocompleteDebug'));
    } catch (err) {
      return false;
    }
  })();
  // Pop-out mode is PER WINDOW, fetched from the main process over IPC
  // (keyed by webContents id). Never derive it from process.argv: Electron
  // shares renderer processes between same-origin windows, so a process-level
  // flag leaked pop-out mode into the main window (hiding its sidebar) and
  // pop-outs in an unflagged process rendered the full client.
  let THREAD_POPOUT_MODE = false;
  let CHANNEL_POPOUT_MODE = false;
  let THREAD_POPOUT_URL = null;
  const windowModeReady = (async () => {
    if (!ipcRenderer) return;
    let m = null;
    try { m = await ipcRenderer.invoke('slack-autocomplete:window-mode'); } catch (err) { m = null; }
    if (!m || m.mode === 'normal') {
      // The sender-frame check can race the frame URL during early preload;
      // retry once when the document is ready.
      await new Promise((resolve) => {
        if (document.readyState !== 'loading') resolve();
        else window.addEventListener('DOMContentLoaded', resolve, { once: true });
      });
      try { m = await ipcRenderer.invoke('slack-autocomplete:window-mode'); } catch (err) { /* keep first result */ }
    }
    if (m && m.mode === 'thread') {
      THREAD_POPOUT_MODE = true;
      THREAD_POPOUT_URL = typeof m.threadUrl === 'string' ? m.threadUrl : null;
    } else if (m && m.mode === 'channel') {
      CHANNEL_POPOUT_MODE = true;
    }
  })();

  // Warm-pool adoption: the main process hands this pre-booted hidden window
  // a pop-out role. Client-side navigation (pushState + popstate) routes the
  // already-running client instantly - no reload, no cold boot.
  ipcRenderer?.on('slack-autocomplete:adopt-popout', (_event, payload) => {
    if (!payload || THREAD_POPOUT_MODE || CHANNEL_POPOUT_MODE) return;
    if (payload.mode === 'thread') {
      THREAD_POPOUT_MODE = true;
      THREAD_POPOUT_URL = typeof payload.threadUrl === 'string' ? payload.threadUrl : null;
    } else if (payload.mode === 'channel') {
      CHANNEL_POPOUT_MODE = true;
    } else {
      return;
    }
    let targetPath = null;
    try { targetPath = new URL(payload.url).pathname; } catch (err) { targetPath = null; }
    if (THREAD_POPOUT_MODE) applyThreadPopoutMode();
    else applyChannelPopoutMode(targetPath);
    // Navigate client-side: Slack's global link handler intercepts anchor
    // clicks to client URLs and routes WITHOUT a reload (verified live -
    // pushState+popstate changes the URL but never fires their router).
    try {
      const a = document.createElement('a');
      a.href = payload.url;
      a.style.display = 'none';
      (document.body || document.documentElement).appendChild(a);
      a.click();
      a.remove();
    } catch (err) {
      try { window.location.href = payload.url; } catch (err2) { /* ignore */ }
    }
    setTimeout(() => { ipcRenderer.invoke('slack-autocomplete:popout-ready').catch(() => {}); }, 400);
  });
  const IS_MAC_PRELOAD = (() => {
    try { return process.platform === 'darwin'; } catch (err) { return false; }
  })();
  const CHANNEL_CONTEXT_TTL = 4000;
  const LISTBOX_SCAN_INTERVAL_MS = 140;
  const LISTBOX_IDLE_TIMEOUT_MS = 1500;
  const THREAD_CONTEXT_REFRESH_INTERVAL = 1500;
  const THREAD_GLOBAL_SCAN_MAX_NODES = 12000;
  const THREAD_GLOBAL_SCAN_MAX_DEPTH = 8;
  const THREAD_BUTTON_ID = 'slack-autocomplete-thread-popout';
  const THREAD_BUTTON_WRAPPER_ID = 'slack-autocomplete-thread-popout-wrapper';
  const CHANNEL_MENU_ITEM_QA = 'slack_autocomplete_open_window';
  const CHANNEL_MENU_SEPARATOR_QA = 'slack_autocomplete_open_window_separator';
  const THREAD_MENU_ITEM_QA = 'slack_autocomplete_open_thread_window';
  const ATTACHMENT_EXIT_ID = 'slack-autocomplete-attachment-exit';
  const LAST_MAIN_URL_KEY = 'slackAutocompleteLastMainUrl';

  let allowAutoSelect = true;
  let pendingChannelContext = null;
  let menuObserver = null;
  let menuScanHandle = null;
  let listboxObserver = null;
  let listboxScanHandle = null;
  let listboxIntervalHandle = null;
  let listboxLastSeenAt = 0;
  let cachedThreadContext = null;
  let cachedThreadContextTimestamp = 0;
  let lastThreadContextSource = null;
  let lastThreadContextError = null;
  let notificationBridgeInstalled = false;

  function log(...args) {
    if (!DEBUG) return;
    console.log('[SlackAutocompletePreload]', ...args);
  }

  function exposeDebugHelpers() {
    const api = {
      getThreadContext() {
        return {
          cachedThreadContext,
          cachedThreadContextTimestamp,
          lastThreadContextSource,
          lastThreadContextError,
          buttonState: document.getElementById(THREAD_BUTTON_ID)?.dataset?.state || null
        };
      },
      forceThreadRefresh() {
        refreshThreadContext(true);
        return api.getThreadContext();
      },
      installNotifications() {
        installNativeNotificationBridge();
      },
      threadPopoutStatus() {
        return {
          mode: THREAD_POPOUT_MODE,
          paneFound: Boolean(document.querySelector(THREAD_PANE_SELECTORS)),
          paneMatch: threadPopoutPaneMatch
        };
      },
      enableDebug() {
        try {
          window.localStorage.setItem('slackAutocompleteDebug', '1');
        } catch (err) {
          console.error('Unable to persist debug flag', err);
        }
      },
      disableDebug() {
        try {
          window.localStorage.removeItem('slackAutocompleteDebug');
        } catch (err) {
          console.error('Unable to remove debug flag', err);
        }
      }
    };

    window.slackAutocomplete = Object.freeze(api);
  }

  function emitNotificationEvent(instance, type) {
    if (!instance) return;
    const event = new Event(type);
    instance.dispatchEvent(event);
    const handler = instance[`on${type}`];
    if (typeof handler === 'function') {
      try {
        handler.call(instance, event);
      } catch (err) {
        log('Notification handler error', err);
      }
    }
  }

  function installNativeNotificationBridge() {
    if (notificationBridgeInstalled) return;
    if (!ipcRenderer) return;
    if (!window.Notification) return;

    const notificationRegistry = new Map();

    class SlackAutocompleteNotification extends EventTarget {
      constructor(title = '', options = {}) {
        super();
        this.title = title;
        this.options = options;
        this.onclick = null;
        this.onclose = null;
        this.tag = options.tag || null;
        this.data = options.data;
        this.dir = options.dir || 'auto';
        this.lang = options.lang || 'en';
        this.silent = Boolean(options.silent);
        this.renotify = Boolean(options.renotify);
        this.requireInteraction = Boolean(options.requireInteraction);
        this.timestamp = Date.now();
        this.icon = options.icon || null;
        this.badge = options.badge || null;
        this.image = options.image || null;
        this.__id = `${this.timestamp}-${Math.random().toString(16).slice(2)}`;
        // Conversation id + ts recovered from the options Slack's client passed in;
        // when found, the banner gets a native inline Reply field (like the official app).
        this.__target = exportCore.extractNotificationTarget({ tag: this.tag, data: this.data, options });
        if (DEBUG) {
          try { log('Notification options', JSON.stringify(options), 'target', JSON.stringify(this.__target)); } catch (err) { /* ignore */ }
        }

        notificationRegistry.set(this.__id, this);

        ipcRenderer
          .invoke('slack-autocomplete:notify', {
            id: this.__id,
            title,
            options: {
              body: options.body || '',
              silent: this.silent,
              requireInteraction: this.requireInteraction,
              subtitle: options.subtitle,
              urgency: options.urgency,
              tag: this.tag,
              hasReply: Boolean(this.__target)
            }
          })
          .catch((err) => {
            log('Failed to request native notification', err);
          });
      }

      close() {
        ipcRenderer
          .invoke('slack-autocomplete:notification-close', this.__id)
          .catch((err) => log('Failed to close native notification', err));
        notificationRegistry.delete(this.__id);
        emitNotificationEvent(this, 'close');
      }

      static requestPermission(callback) {
        const result = 'granted';
        if (typeof callback === 'function') {
          callback(result);
        }
        return Promise.resolve(result);
      }

      static get permission() {
        return 'granted';
      }
    }

    window.Notification = SlackAutocompleteNotification;
    notificationBridgeInstalled = true;

    async function postNotificationReply(instance, text) {
      const target = instance.__target;
      const reply = String(text || '').trim();
      if (!target || !reply) return;
      try {
        const teamId = exportCore.parseClientTeam(window.location.pathname)?.teamId;
        const raw = window.localStorage.getItem('localConfig_v2');
        const token = teamId ? exportCore.getTokenForTeam(raw, teamId) : null;
        const apiBase = teamId ? exportCore.inferApiBase(raw, teamId) : null;
        if (!token || !apiBase) throw new Error('missing token/config');
        const params = { channel: target.channel, text: reply };
        if (target.threadTs) params.thread_ts = target.threadTs;
        const res = await ipcRenderer.invoke('slack-autocomplete:api-call', {
          apiBase, teamId, token, method: 'chat.postMessage', params
        });
        if (!res || !res.json || res.json.ok !== true) {
          throw new Error((res && res.json && res.json.error) || ('HTTP ' + (res && res.status)));
        }
        log('Notification reply sent to', target.channel);
      } catch (err) {
        console.warn('[SlackAutocompletePreload] Notification reply failed:', err);
        ipcRenderer.invoke('slack-autocomplete:notify', {
          id: `reply-failed-${Date.now()}`,
          title: 'Reply not sent',
          options: { body: 'Sending the notification reply failed: ' + (err?.message || err), urgency: 'critical' }
        }).catch(() => {});
      }
    }

    ipcRenderer.on('slack-autocomplete:notification-event', (_event, payload) => {
      const instance = payload?.id ? notificationRegistry.get(payload.id) : null;
      if (!instance) return;
      if (payload.type === 'reply') {
        postNotificationReply(instance, payload.reply);
        notificationRegistry.delete(payload.id);
        return;
      }
      emitNotificationEvent(instance, payload.type);
      if (payload.type === 'close') {
        notificationRegistry.delete(payload.id);
      }
    });
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
    if (listboxes.length) {
      listboxLastSeenAt = Date.now();
    }

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
    startListboxInterval();
  }

  function stopListboxIntervalWhenIdle() {
    if (!listboxIntervalHandle) return;
    const idle = Date.now() - listboxLastSeenAt;
    if (idle > LISTBOX_IDLE_TIMEOUT_MS) {
      clearInterval(listboxIntervalHandle);
      listboxIntervalHandle = null;
    }
  }

  function startListboxInterval() {
    if (listboxIntervalHandle) return;
    listboxLastSeenAt = Date.now();
    listboxIntervalHandle = setInterval(() => {
      if (document.hidden) {
        stopListboxIntervalWhenIdle();
        return;
      }
      scanForListboxes();
      stopListboxIntervalWhenIdle();
    }, LISTBOX_SCAN_INTERVAL_MS);
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
    startListboxInterval();

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

  function isEditableTarget(node) {
    if (!(node instanceof Element)) return false;
    if (node.closest('input, textarea, [contenteditable="true"], [contenteditable=""]')) {
      return true;
    }
    const role = node.getAttribute('role');
    return role === 'textbox' || role === 'combobox' || role === 'searchbox';
  }

  function setupNativeContextMenu() {
    document.addEventListener(
      'contextmenu',
      (event) => {
        try {
          // Slack's client renders its own context menu on messages, links,
          // etc. and calls preventDefault when it does. Showing our native
          // menu on top of it double-stacked the menus - official behavior
          // is Slack's menu only wherever the client provides one.
          if (event.defaultPrevented) return;

          const selection = window.getSelection ? window.getSelection() : null;
          const selectionText = selection ? String(selection).trim() : '';
          const isEditable = isEditableTarget(event.target);
          const hasSelection = Boolean(selectionText);
          const canGoBack = true; // Always expose Go Back in menu; enable/disable in main process.

          // Right-clicks inside the thread pane offer the official-style
          // "Open Thread in New Window" (not inside an existing pop-out).
          let threadUrl = null;
          if (!THREAD_POPOUT_MODE && event.target instanceof Element
            && event.target.closest('.p-workspace__secondary_view, .p-flexpane, [data-qa="threads_flexpane"]')) {
            try { threadUrl = getCurrentThreadUrl(false); } catch (err) { threadUrl = null; }
          }

          event.preventDefault();

          ipcRenderer?.invoke('slack-autocomplete:context-menu', {
            selectionText,
            hasSelection,
            isEditable,
            canGoBack,
            threadUrl
          });
        } catch (err) {
          log('Context menu error', err);
        }
      },
      false
    );
  }

  function attachMouseListener() {
    document.addEventListener(
      'mousemove',
      (ev) => {
        if (!ev.isTrusted) return;
        if (!allowAutoSelect) return;

        if (ev.target instanceof Element) {
          const listbox = ev.target.closest('[role="listbox"]');
          if (listbox) {
            allowAutoSelect = false;
            log('User mouse interaction detected in listbox; disabling auto-select.');
          }
        }
      },
      true
    );
  }

  function fallbackWindowOpen(url) {
    try {
      window.open(url, '_blank', 'noopener');
    } catch (err) {
      log('Failed to open new window via fallback', err);
    }
  }

  function openSlackWindow(url) {
    if (!url) return;
    if (ipcRenderer?.invoke) {
      ipcRenderer.invoke('slack-autocomplete:open-window', url).catch((err) => {
        log('IPC open-window failed, falling back to window.open', err);
        fallbackWindowOpen(url);
      });
      return;
    }

    fallbackWindowOpen(url);
  }

  // NOTE: There used to be a capture-phase click interceptor here that sent
  // any external anchor straight to the system browser. It preempted Slack's
  // own click handling, so e.g. Giphy images opened in the browser instead of
  // Slack's in-app lightbox. The official app does no renderer-level click
  // interception - external routing happens in the main process via the
  // window-open handler and will-navigate, which this app also has.

  ipcRenderer?.on('slack-autocomplete:open-url', (_event, targetUrl) => {
    if (typeof targetUrl !== 'string') return;
    if (window.location.href === targetUrl) return;
    try {
      window.location.href = targetUrl;
    } catch (err) {
      log('Failed to navigate to target URL', targetUrl, err);
    }
  });

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
      if (!pendingChannelContext && !pendingThreadContext) return;
      document
        .querySelectorAll('[data-qa="menu_items"], .c-menu__items, [role="menu"]')
        .forEach((menu) => {
          injectChannelMenuItem(menu);
          injectThreadMenuItem(menu);
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

  // Right-click inside the thread pane: remember the thread so the item can
  // be injected into whatever menu Slack renders for that click (the official
  // client puts its "Open in new window" inside its own menu the same way).
  let pendingThreadContext = null;

  // Reliable thread URL from the pane's own DOM: thread list items carry ids
  // like "C0AB12CDE-1783109507.888099-thread-list-Thread" (verified live).
  // This does not depend on the cached thread context or the address bar
  // (which shows the channel, not the thread, while a thread pane is open).
  function threadUrlFromPane(pane) {
    if (!pane) return null;
    const el = pane.querySelector('[id*="-thread-list-Thread"]') || pane.querySelector('[id*="/thread/"]');
    const m = el && /([CDG][A-Z0-9]+)-(\d+\.\d+)/.exec(el.id);
    if (!m) return null;
    const teamId = exportCore.parseClientTeam(window.location.pathname)?.teamId;
    if (!teamId) return null;
    return `${window.location.origin}/client/${teamId}/${m[1]}/thread/${m[1]}-${m[2]}`;
  }

  function captureThreadContext(event) {
    pendingThreadContext = null;
    if (THREAD_POPOUT_MODE) return; // no pop-out from inside a pop-out
    if (!(event.target instanceof Element)) return;
    const pane = event.target.closest(THREAD_PANE_SELECTORS);
    if (!pane) return;
    let url = threadUrlFromPane(pane);
    if (!url) { try { url = getCurrentThreadUrl(true); } catch (err) { url = null; } }
    if (!url || !url.includes('/thread/')) return;
    pendingThreadContext = { url, ts: Date.now() };
    requestMenuScan();
  }

  function injectThreadMenuItem(menuEl) {
    if (!pendingThreadContext) return;
    const normalizedMenu = normalizeMenuElement(menuEl);
    if (!normalizedMenu) return;
    if (normalizedMenu.dataset.slackAutocompleteThreadMenuPatched === '1') return;
    if (visibleMenuItemExists(THREAD_MENU_ITEM_QA)) return;
    if (Date.now() - pendingThreadContext.ts > CHANNEL_CONTEXT_TTL) {
      pendingThreadContext = null;
      return;
    }

    normalizedMenu.dataset.slackAutocompleteThreadMenuPatched = '1';

    const wrapper = document.createElement('div');
    wrapper.className = 'c-menu_item__li';
    wrapper.dataset.qa = THREAD_MENU_ITEM_QA;

    const button = document.createElement('button');
    button.className = 'c-button-unstyled c-menu_item__button';
    button.type = 'button';
    button.setAttribute('role', 'menuitem');
    button.tabIndex = -1;

    const label = document.createElement('div');
    label.className = 'c-menu_item__label';
    label.textContent = pendingThreadContext.label || 'Open thread in new window';

    button.appendChild(label);
    wrapper.appendChild(button);

    addMenuItemHighlight(wrapper, button);

    const threadUrl = pendingThreadContext.url;
    button.addEventListener('click', (clickEvent) => {
      clickEvent.preventDefault();
      clickEvent.stopPropagation();
      pendingThreadContext = null;
      closeContextMenus(); // close first so the menu never lingers over the new window
      openSlackWindow(threadUrl);
    });

    normalizedMenu.appendChild(wrapper);
    log('Inserted custom "Open thread in new window" action.');
  }

  // Slack drives menu-item highlighting with React state classes, not CSS
  // :hover - injected items must toggle those classes themselves (and clear
  // Slack's own highlight so two rows never glow at once).
  function addMenuItemHighlight(wrapper, button) {
    wrapper.addEventListener('mouseenter', () => {
      const menu = wrapper.parentElement;
      if (menu) {
        menu.querySelectorAll('.c-menu_item__li--highlighted').forEach((el) => el.classList.remove('c-menu_item__li--highlighted'));
        menu.querySelectorAll('.c-menu_item__button--highlighted').forEach((el) => el.classList.remove('c-menu_item__button--highlighted'));
      }
      wrapper.classList.add('c-menu_item__li--highlighted');
      button.classList.add('c-menu_item__button--highlighted');
    });
    wrapper.addEventListener('mouseleave', () => {
      wrapper.classList.remove('c-menu_item__li--highlighted');
      button.classList.remove('c-menu_item__button--highlighted');
    });
  }

  // Only one menu can be open at a time - if a visible copy of our item
  // already exists anywhere, don't add another (nested menu containers used
  // to each receive a copy, showing the item twice).
  function visibleMenuItemExists(qa) {
    return Array.from(document.querySelectorAll(`[data-qa="${qa}"]`))
      .some((el) => el.getClientRects().length > 0);
  }

  function injectChannelMenuItem(menuEl) {
    if (!pendingChannelContext) return;
    const normalizedMenu = normalizeMenuElement(menuEl);
    if (!normalizedMenu) return;
    if (!looksLikeChannelMenu(normalizedMenu)) return;
    if (normalizedMenu.dataset.slackAutocompleteMenuPatched === '1') return;
    if (visibleMenuItemExists(CHANNEL_MENU_ITEM_QA)) return;
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

    addMenuItemHighlight(wrapper, button);

    // Capture the URL at injection time: pendingChannelContext is shared
    // mutable state that later menu scans may clear before the user clicks.
    const channelUrl = pendingChannelContext.url;
    button.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      pendingChannelContext = null;
      closeContextMenus(); // close first so the menu never lingers over the new window
      openSlackWindow(channelUrl);
    });

    // Official placement: own section right before "Leave channel".
    const leaveItem = Array.from(normalizedMenu.querySelectorAll('.c-menu_item__li')).find(
      (li) => /^leave\s/i.test((li.textContent || '').trim())
    );
    if (leaveItem) {
      normalizedMenu.insertBefore(wrapper, leaveItem);
      normalizedMenu.insertBefore(separator, leaveItem);
    } else {
      normalizedMenu.appendChild(wrapper);
      normalizedMenu.appendChild(separator);
    }
    log('Inserted custom "Open in new window" channel action.');
  }

  function handleMenuMutations(mutations) {
    if (!pendingChannelContext && !pendingThreadContext) return;

    for (const mutation of mutations) {
      mutation.addedNodes.forEach((node) => {
        if (!(node instanceof HTMLElement)) return;

        const menuEl = resolveMenuContainer(node);
        if (menuEl) {
          injectChannelMenuItem(menuEl);
          injectThreadMenuItem(menuEl);
        }

        node
          .querySelectorAll?.('[data-qa="menu_items"], .c-menu__items, [role="menu"]')
          .forEach((menu) => {
            injectChannelMenuItem(menu);
            injectThreadMenuItem(menu);
          });
      });
    }

    requestMenuScan();
  }

  function setupChannelContextMenuSupport() {
    document.addEventListener('contextmenu', captureChannelContext, true);
    document.addEventListener('contextmenu', captureThreadContext, true);
    // Thread header "..." menu gets "Open in new window", matching where the
    // official app puts it.
    document.addEventListener('click', (event) => {
      if (THREAD_POPOUT_MODE) return;
      if (!(event.target instanceof Element)) return;
      const moreBtn = event.target.closest('[data-qa="secondary-header-more"]');
      if (!moreBtn) return;
      const pane = moreBtn.closest(THREAD_PANE_SELECTORS);
      if (!pane) return;
      const url = threadUrlFromPane(pane);
      if (!url) return;
      pendingThreadContext = { url, ts: Date.now(), label: 'Open in new window' };
      requestMenuScan();
    }, true);

    if (menuObserver) {
      menuObserver.disconnect();
    }

    menuObserver = new MutationObserver(handleMenuMutations);
    menuObserver.observe(document.body, {
      childList: true,
      subtree: true
    });
  }

  let lastMainUrl = (() => {
    try {
      return window.sessionStorage.getItem(LAST_MAIN_URL_KEY) || null;
    } catch (err) {
      return null;
    }
  })();

  function rememberMainUrl(url) {
    if (!url) return;
    lastMainUrl = url;
    try {
      window.sessionStorage.setItem(LAST_MAIN_URL_KEY, url);
    } catch (err) {
      log('Unable to persist last main URL', err);
    }
  }

  function isSlackClientRoute(targetUrl) {
    try {
      const u = new URL(targetUrl);
      return u.hostname.endsWith('slack.com') && u.pathname.includes('/client/');
    } catch (err) {
      return false;
    }
  }

  function isLikelyAttachmentRoute(targetUrl) {
    try {
      const u = new URL(targetUrl);
      const segments = u.pathname.split('/').filter(Boolean);
      const clientIdx = segments.indexOf('client');
      const afterClient = clientIdx >= 0 ? segments.slice(clientIdx + 2) : segments;
      const markers = ['file', 'files', 'file-upload', 'file_upload', 'notes', 'downloads'];
      if (afterClient.some((part) => markers.includes(part))) {
        return true;
      }

      if (u.searchParams.get('file') || u.searchParams.get('attachment') || u.searchParams.get('raw')) {
        return true;
      }
    } catch (err) {
      /* ignore parse issues */
    }

    return Boolean(
      document.querySelector(
        '.p-file_viewer, .p-file_viewer_modal, [data-qa="file_viewer"], [data-qa="file_viewer_root"], [data-qa="file_preview_body"], [data-qa="file_title"]'
      )
    );
  }

  function isNativeSlackFileViewerOpen() {
    const selectors = [
      '.p-file_viewer',
      '.p-file_viewer_modal',
      '.c-lightbox__container',
      '[data-qa="file_viewer"]',
      '[data-qa="file_viewer_root"]',
      '[data-qa="file_preview_body"]',
      '[data-qa="file_title"]'
    ];

    return selectors.some((selector) => {
      const el = document.querySelector(selector);
      return el && isVisible(el);
    });
  }

  function isLikelyMainClientRoute(targetUrl) {
    return isSlackClientRoute(targetUrl) && !isLikelyAttachmentRoute(targetUrl);
  }

  function goBackFromAttachment() {
    const target = lastMainUrl || `${window.location.origin}/client`;

    if (window.history.length > 1) {
      window.history.back();
      setTimeout(() => {
        if (isLikelyAttachmentRoute(window.location.href) && target) {
          window.location.href = target;
        }
      }, 400);
      return;
    }

    if (target) {
      window.location.href = target;
    }
  }

  function renderAttachmentExitButton() {
    const shouldShow = isLikelyAttachmentRoute(window.location.href);
    const existing = document.getElementById(ATTACHMENT_EXIT_ID);

    if (!shouldShow) {
      existing?.remove();
      return;
    }

    if (existing) return;

    const button = document.createElement('button');
    button.id = ATTACHMENT_EXIT_ID;
    button.type = 'button';
    button.textContent = 'X';
    button.setAttribute('aria-label', 'Close attachment');
    button.setAttribute('title', 'Back to Slack');

    Object.assign(button.style, {
      position: 'fixed',
      top: '12px',
      right: '12px',
      width: '32px',
      height: '32px',
      borderRadius: '16px',
      border: '1px solid rgba(0, 0, 0, 0.2)',
      background: '#fff',
      color: '#1d1c1d',
      fontSize: '18px',
      lineHeight: '32px',
      textAlign: 'center',
      boxShadow: '0 6px 18px rgba(0, 0, 0, 0.16)',
      zIndex: '99999',
      cursor: 'pointer',
      padding: '0'
    });

    button.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopPropagation();
      goBackFromAttachment();
    });

    document.body.appendChild(button);
  }

  function handleAttachmentState() {
    const href = window.location.href;
    if (isLikelyMainClientRoute(href)) {
      rememberMainUrl(href);
    }
    renderAttachmentExitButton();
  }

  function setupAttachmentEscape() {
    handleAttachmentState();

    window.addEventListener('hashchange', handleAttachmentState);
    window.addEventListener('popstate', handleAttachmentState);

    window.addEventListener(
      'keydown',
      (ev) => {
        if (ev.key === 'Escape' && isLikelyAttachmentRoute(window.location.href)) {
          if (isNativeSlackFileViewerOpen()) {
            return;
          }
          ev.preventDefault();
          goBackFromAttachment();
        }
      },
      true
    );

    ipcRenderer?.on('slack-autocomplete:attachment-go-back', () => {
      goBackFromAttachment();
    });

    setInterval(handleAttachmentState, 800);
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
  const THREAD_MESSAGE_SELECTORS = [
    '[data-qa="message_container"]',
    '.c-virtual_list__item',
    '[data-item-key]'
  ];
  const THREAD_CONTAINER_SELECTOR = THREAD_CONTAINER_SELECTORS.join(', ');
  const THREAD_HEADER_SELECTOR = THREAD_HEADER_SELECTORS.join(', ');
  const THREAD_MESSAGE_SELECTOR = THREAD_MESSAGE_SELECTORS.join(', ');

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

  function threadContextFromUrl() {
    try {
      const url = new URL(window.location.href);
      const searchParams = url.searchParams;
      const hash = window.location.hash || '';
      const hashQuery = hash.includes('?') ? hash.substring(hash.indexOf('?') + 1) : '';
      const hashParams = new URLSearchParams(hashQuery);

      const channelCandidates = [
        searchParams.get('cid'),
        searchParams.get('channel'),
        searchParams.get('conversation'),
        hashParams.get('cid'),
        hashParams.get('channel'),
        hashParams.get('conversation')
      ];

      const threadCandidates = [
        searchParams.get('thread_ts'),
        searchParams.get('thread_ts_root'),
        hashParams.get('thread_ts'),
        hashParams.get('thread_ts_root')
      ];

      const channelId = channelCandidates.map(coerceChannelId).find(Boolean);
      const threadTs = threadCandidates.map(coerceThreadTs).find(Boolean);

      if (channelId && threadTs) {
        return { channelId, threadTs };
      }
    } catch (err) {
      log('Failed to parse URL for thread context', err);
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
    const normalized = trimmed.toUpperCase();
    if (/^[CDGSPW][A-Z0-9]{7,}$/.test(normalized)) {
      return normalized;
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

    const virtualItem = el.closest?.('.c-virtual_list__item');
    const virtualId = virtualItem?.id || '';
    const virtualKey = virtualItem?.getAttribute?.('data-item-key');
    const virtualTs = virtualItem?.querySelector?.('[data-ts]')?.getAttribute('data-ts');

    const threadAttrs = [
      'data-thread-root-ts',
      'data-thread-ts',
      'data-qa-thread-root-ts',
      'data-qa-thread-ts',
      'data-message-ts',
      'data-qa-thread-root-message-ts',
      'data-qa-message-ts',
      'data-root-ts',
      'data-qa-root-ts',
      'data-ts',
      'data-qa-ts',
      'data-thread-parent-ts',
      'data-thread-root-message-id',
      'data-qa-thread-root-message-id'
    ];
    const channelAttrs = [
      'data-channel-id',
      'data-qa-channel-id',
      'data-qa-channel',
      'data-message-channel-id',
      'data-conversation-id',
      'data-qa-conversation-id',
      'data-qa-thread-channel-id',
      'data-qa-surface-channel-id',
      'data-ts-channel-id',
      'data-qa-ts-channel-id',
      'data-root-channel-id',
      'data-qa-inline-channel-id'
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
      const carrierSelector = [
        '[data-channel-id]',
        '[data-qa-channel-id]',
        '[data-qa-channel]',
        '[data-message-channel-id]',
        '[data-conversation-id]',
        '[data-qa-conversation-id]',
        '[data-qa-thread-channel-id]',
        '[data-qa-surface-channel-id]',
        '[data-ts-channel-id]',
        '[data-qa-ts-channel-id]',
        '[data-root-channel-id]',
        '[data-qa-inline-channel-id]'
      ].join(', ');

      const channelCarrier = el.closest?.(carrierSelector);
      if (channelCarrier) {
        const attrsToTry = [
          'data-channel-id',
          'data-qa-channel-id',
          'data-qa-channel',
          'data-message-channel-id',
          'data-conversation-id',
          'data-qa-conversation-id',
          'data-qa-thread-channel-id',
          'data-qa-surface-channel-id',
          'data-ts-channel-id',
          'data-qa-ts-channel-id',
          'data-root-channel-id',
          'data-qa-inline-channel-id'
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

    if (!channelId && virtualId) {
      const idParts = virtualId.split(/[-_]/);
      for (const part of idParts) {
        const coerced = coerceChannelId(part);
        if (coerced) {
          channelId = coerced;
          break;
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

        if (!channelId && virtualId) {
          const idParts = virtualId.split(/[-_]/);
          for (const part of idParts) {
            const coerced = coerceChannelId(part);
            if (coerced) {
              channelId = coerced;
              break;
            }
          }
        }
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

    if (!threadTs && virtualKey) {
      threadTs = coerceThreadTs(virtualKey);
    }

    if (!threadTs && virtualTs) {
      threadTs = coerceThreadTs(virtualTs);
    }

    if (!threadTs && virtualId) {
      const idParts = virtualId.split(/[-_]/);
      for (const part of idParts) {
        const coerced = coerceThreadTs(part);
        if (coerced) {
          threadTs = coerced;
          break;
        }
      }
    }

    if (channelId && threadTs) {
      return { channelId, threadTs };
    }

    return null;
  }

  function collectThreadDomCandidates() {
    const selectors = [
      '[data-qa="thread_permalink_button"]',
      '[data-qa="thread_permalink_button"] a[href*="/thread/"]',
      '.p-threads_flexpane__header_permalink',
      '[data-qa="thread-pane"] [data-thread-root-ts]',
      '[data-qa="thread-pane"] [data-thread-ts]',
      '[data-qa="thread-pane"] [data-root-ts]',
      '[data-qa="thread-pane"] [data-message-ts]',
      '[data-qa="thread-pane"] [data-ts]',
      '.p-threads_view__root_message',
      '[data-qa="thread-pane"] [data-qa="message_container"]',
      '[data-qa="ai_summary_summarize_thread_button"]',
      '[data-qa="thread-pane"] [data-qa-thread-root-ts]',
      '[data-qa="thread-pane"] [data-qa-thread-ts]',
      '[data-qa="thread-pane"] .c-virtual_list__item',
      '[data-qa="thread-pane"] [data-item-key]',
      '[data-qa="thread-pane"] .c-message_kit__thread_message',
      '.c-message_kit__thread_message',
      '.c-virtual_list__item[id*="thread-list"]',
      '[data-item-key*="thread"]'
    ];

    const seen = new Set();
    const nodes = [];

    function addNode(node) {
      if (!node || !(node instanceof Element)) return;
      if (seen.has(node)) return;
      seen.add(node);
      nodes.push(node);
    }

    selectors.forEach((selector) => {
      document.querySelectorAll(selector).forEach(addNode);
    });

    const pane = document.querySelector('[data-qa="thread-pane"]') || document.querySelector('.p-threads_view');
    if (pane) {
      pane.querySelectorAll('[data-qa="message_container"], [data-thread-root-ts], [data-thread-ts]').forEach(addNode);
    }

    return nodes;
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
      if (w.__remixContext.state.loaderData) {
        candidates.push(w.__remixContext.state.loaderData);
      }
      if (Array.isArray(w.__remixContext.state.matches)) {
        candidates.push(...w.__remixContext.state.matches);
      }
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

    if (w.__SLACK_WEBAPP_CONTEXT__) {
      candidates.push(w.__SLACK_WEBAPP_CONTEXT__);
    }

    if (w.__INITIAL_STATE__) {
      candidates.push(w.__INITIAL_STATE__);
    }

    if (w.__BOOTSTRAP_DATA__) {
      candidates.push(w.__BOOTSTRAP_DATA__);
    }

    if (w.boot_data) {
      candidates.push(w.boot_data);
    }

    if (w.__slackAutocompleteThreadContext) {
      candidates.push(w.__slackAutocompleteThreadContext);
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
      'selected_channel_id',
      'selectedChannelId',
      'selected_conversation_id',
      'selectedConversationId',
      'pane_channel_id',
      'thread_channel_id'
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
      'selectedThreadTs',
      'selected_message_ts',
      'selectedMessageTs',
      'current_thread_ts',
      'currentThreadTs'
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
      coerceChannelId(obj?.conversation?.id || obj?.conversation) ||
      coerceChannelId(obj?.thread?.channel_id) ||
      coerceChannelId(obj?.pane_channel_id);

    const threadTs =
      threadKeys
        .map((key) => coerceThreadTs(obj[key]))
        .find(Boolean) ||
      coerceThreadTs(obj?.thread?.thread_ts || obj?.thread?.root_ts) ||
      coerceThreadTs(obj?.threadSidebar?.thread_ts) ||
      coerceThreadTs(obj?.threadSidebar?.thread?.thread_ts) ||
      coerceThreadTs(obj?.threadSidebar?.thread?.root_ts) ||
      coerceThreadTs(obj?.thread_pane?.thread_ts) ||
      coerceThreadTs(obj?.rightPane?.threadSidebar?.thread_ts);

    if (channelId && threadTs) {
      return { channelId, threadTs };
    }

    if (threadTs) {
      const nestedChannel =
        coerceChannelId(obj?.channel?.id) ||
        coerceChannelId(obj?.conversation?.id) ||
        coerceChannelId(obj?.thread?.channel_id) ||
        coerceChannelId(obj?.threadSidebar?.channel_id) ||
        coerceChannelId(obj?.threadSidebar?.thread?.channel_id) ||
        coerceChannelId(obj?.rightPane?.threadSidebar?.channel_id);
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

    for (const candidate of candidates) {
      const context = attemptExtractThreadContext(candidate);
      if (context) {
        return context;
      }
    }

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

    let context = null;
    let source = null;

    const urlContext = threadContextFromUrl();
    if (urlContext) {
      context = urlContext;
      source = 'url';
    }

    if (!context) {
      const domContext = deriveThreadContextFromDom();
      if (domContext) {
        context = domContext;
        source = 'dom';
      }
    }

    if (!context) {
      const globalContext = deriveThreadContextFromGlobals();
      if (globalContext) {
        context = globalContext;
        source = 'globals';
      }
    }

    if (context) {
      cachedThreadContext = context;
      cachedThreadContextTimestamp = Date.now();
      lastThreadContextSource = source;
      lastThreadContextError = null;

      const payload = {
        ...context,
        source,
        updatedAt: cachedThreadContextTimestamp
      };

      window.__slackAutocompleteThreadContext = payload;
      window.__slackAutocompleteThreadContextMeta = {
        source,
        updatedAt: cachedThreadContextTimestamp
      };

      log('Thread context refreshed', payload);
      return context;
    }

    if (force) {
      cachedThreadContext = null;
      cachedThreadContextTimestamp = 0;
    }

    lastThreadContextError = {
      timestamp: Date.now(),
      reason: 'context-not-found'
    };

    return null;
  }

  function clearThreadContextCache() {
    cachedThreadContext = null;
    cachedThreadContextTimestamp = 0;
     lastThreadContextSource = null;
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
    button.disabled = false;
    button.setAttribute('aria-disabled', 'false');
    if (hasUrl) {
      button.classList.remove('c-button--disabled', 'is-disabled');
      button.dataset.state = 'ready';
      button.setAttribute('title', 'Open thread in new window');
    } else {
      button.classList.remove('c-button--disabled', 'is-disabled');
      button.dataset.state = 'searching';
      button.setAttribute('title', 'Locating thread metadata…');
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
        console.warn('[SlackAutocomplete] No thread URL detected; cannot open thread window.',
          window.slackAutocomplete?.getThreadContext?.());
        updateThreadButtonState(button);
        return;
      }

      openSlackWindow(threadUrl);
      log('Opening thread window', threadUrl);
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
      refreshThreadContext(true);
      ensureThreadPopoutButton();
      updateThreadButtonState(document.getElementById(THREAD_BUTTON_ID));
    });
  }

  function setupThreadWatcher() {
    refreshThreadContext(true);
    ensureThreadPopoutButton();
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
            node.matches?.(THREAD_CONTAINER_SELECTOR) ||
            node.querySelector?.(THREAD_CONTAINER_SELECTOR) ||
            node.matches?.(THREAD_HEADER_SELECTOR) ||
            node.querySelector?.(THREAD_HEADER_SELECTOR) ||
            node.matches?.(THREAD_MESSAGE_SELECTOR) ||
            node.querySelector?.(THREAD_MESSAGE_SELECTOR)
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

  function setupBadgeUpdater() {
    // client.counts drives the badge, mimicking the official app (algorithm
    // decompiled from Slack.app's main bundle and verified live over CDP):
    //   mentions/DM count > 0            -> numbered badge
    //   else any qualifying unread       -> dot, gated on the mac_ssb_bullet
    //   else                             -> no badge
    // A qualifying unread is a non-muted, non-archived conversation with
    // has_unreads (client.counts flags muted and archived ones too, but the
    // official badge ignores them). Muting lives in the
    // all_notifications_prefs JSON pref (users.prefs.get); archived status is
    // checked once per flagged id via conversations.info and cached. Reads
    // are picked up quickly via repolls triggered by title changes (channel
    // switches) and window focus.
    const COUNTS_POLL_INTERVAL_MS = 30000;
    const MUTED_POLL_INTERVAL_MS = 600000;
    let countsMentions = 0;
    let countsUnread = false;
    let haveCounts = false;
    let mutedIds = new Set();
    let showBullet = true;
    const archivedById = new Map();
    let refreshHandles = [];

    const apiCall = async (method, params = {}) => {
      const teamId = exportCore.parseClientTeam(window.location.pathname)?.teamId;
      const raw = window.localStorage.getItem('localConfig_v2');
      const token = teamId ? exportCore.getTokenForTeam(raw, teamId) : null;
      const apiBase = teamId ? exportCore.inferApiBase(raw, teamId) : null;
      if (!token || !apiBase || !ipcRenderer) return null;
      return ipcRenderer.invoke('slack-autocomplete:api-call', {
        apiBase, teamId, token, method, params
      });
    };

    const isArchived = async (id) => {
      if (archivedById.has(id)) return archivedById.get(id);
      try {
        const res = await apiCall('conversations.info', { channel: id });
        if (res?.json?.ok) {
          const archived = !!res.json.channel?.is_archived;
          archivedById.set(id, archived);
          return archived;
        }
      } catch (err) {
        log('conversations.info failed', err);
      }
      return false; // unknown: assume live, retry next poll (not cached)
    };

    const applyBadge = () => {
      if (!haveCounts || !ipcRenderer) return;
      const badge = countsMentions > 0 ? String(countsMentions) : (countsUnread ? '•' : '');
      ipcRenderer.invoke('slack-autocomplete:update-badge', badge).catch((err) => {
        log('Failed to update badge', err);
      });
    };

    const pollCounts = async () => {
      try {
        const res = await apiCall('client.counts');
        const summary = exportCore.summarizeCounts(res?.json, mutedIds);
        if (!summary) return;
        let unread = summary.threadsUnread;
        for (const id of summary.unreadIds) {
          if (unread) break;
          if (!(await isArchived(id))) unread = true;
        }
        haveCounts = true;
        countsMentions = summary.mentions;
        countsUnread = unread && showBullet;
        applyBadge();
      } catch (err) {
        log('client.counts poll failed', err);
      }
    };

    const pollMuted = async () => {
      try {
        const res = await apiCall('users.prefs.get');
        if (res?.json?.ok) {
          mutedIds = exportCore.parseMutedChannels(res.json);
          showBullet = exportCore.parseShowBullet(res.json);
        }
      } catch (err) {
        log('users.prefs.get poll failed', err);
      }
    };

    setInterval(pollCounts, COUNTS_POLL_INTERVAL_MS);
    setInterval(pollMuted, MUTED_POLL_INTERVAL_MS);
    setTimeout(async () => { await pollMuted(); pollCounts(); }, 5000);

    // Reads usually coincide with a channel switch (title change) or the
    // window regaining focus; repoll shortly after so the dot clears fast.
    const scheduleRepolls = () => {
      refreshHandles.forEach(clearTimeout);
      refreshHandles = [setTimeout(pollCounts, 1000), setTimeout(pollCounts, 4000)];
    };

    const titleEl = document.querySelector('title');
    if (titleEl) {
      const observer = new MutationObserver(scheduleRepolls);
      observer.observe(titleEl, {
        childList: true,
        characterData: true,
        subtree: true
      });
    }
    window.addEventListener('focus', scheduleRepolls);
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') scheduleRepolls();
    });
  }

  function installIdleDetector() {
    const IDLE_THRESHOLD_S = 300;
    const POLL_INTERVAL_MS = 15000;

    class SlackIdleDetector extends EventTarget {
      constructor() {
        super();
        this.userState = 'active';
        this.screenState = 'unlocked';
        this.onchange = null;
        this._polling = null;
      }

      async start() {
        if (this._polling) return;

        const poll = async () => {
          try {
            const idleSeconds = await ipcRenderer.invoke('slack-autocomplete:get-idle-time');
            const newUserState = idleSeconds >= IDLE_THRESHOLD_S ? 'idle' : 'active';
            if (newUserState !== this.userState) {
              this.userState = newUserState;
              log('IdleDetector: userState changed to', newUserState);
              const ev = new Event('change');
              this.dispatchEvent(ev);
              if (typeof this.onchange === 'function') {
                try { this.onchange(ev); } catch (err) { log('IdleDetector onchange error', err); }
              }
            }
          } catch (err) {
            log('IdleDetector poll error', err);
          }
        };

        await poll();
        this._polling = setInterval(poll, POLL_INTERVAL_MS);
      }

      stop() {
        if (this._polling) {
          clearInterval(this._polling);
          this._polling = null;
        }
      }

      static async requestPermission() {
        return 'granted';
      }
    }

    window.IdleDetector = SlackIdleDetector;
    log('IdleDetector polyfill installed');
  }

  function init() {
    attachKeyListener();
    attachMouseListener();
    setupNativeContextMenu();
    setupAutocompleteObservers();
    setupChannelContextMenuSupport();
    setupAttachmentEscape();
    windowModeReady.then(() => {
      if (THREAD_POPOUT_MODE) {
        applyThreadPopoutMode();
      } else if (CHANNEL_POPOUT_MODE) {
        applyChannelPopoutMode();
        setupThreadWatcher(); // threads can still pop out from a channel window
      } else {
        applyHiddenTitleBarPadding();
        setupThreadWatcher(); // no pop-out button inside a thread pop-out window
      }
    });
    setupBadgeUpdater();
    setupDownloadsPanel();
    setupTeamsReporter();
    installNativeNotificationBridge();
    installIdleDetector();
    log('Slack autocomplete preload initialized.');
    exposeDebugHelpers();
  }

  // Thread-only pop-out. Verified against the live Slack DOM: the client uses
  // a CSS grid layout with `display:contents` wrappers, so the thread sits in
  // a fixed-width (~440px) grid track. Two moves are both required:
  //   1. Hide every ancestor sibling up to <body> - kills the rail, workspace
  //      switcher and the primary channel view (which paint over the thread
  //      because they live in sibling stacking contexts, so z-index alone
  //      can't cover them).
  //   2. position:fixed the pane to fill the viewport - escapes the grid track
  //      that otherwise pins it to ~440px.
  // This is layout-name-agnostic (only the pane must be found) and re-applied
  // because React re-renders drop our inline styles.
  const THREAD_PANE_CANDIDATES = [
    '[data-qa="threads_flexpane"]',
    '.p-thread_view',
    '[data-qa="thread_container"]',
    '.p-workspace__secondary_view',
    '.p-flexpane'
  ];
  const THREAD_PANE_SELECTORS = THREAD_PANE_CANDIDATES.join(', ');
  let threadPopoutPaneMatch = null;

  function queryFirstPane(candidates) {
    for (const sel of candidates) {
      const el = document.querySelector(sel);
      if (el) return el;
    }
    return null;
  }

  // Official pop-outs never flash the full client (the official app boots
  // pooled hidden windows). We approximate: cover the window until the pane
  // isolation succeeds, then reveal.
  let popoutCover = null;
  function installPopoutCover() {
    const add = () => {
      if (popoutCover || document.getElementById('slack-autocomplete-popout-cover')) return;
      popoutCover = document.createElement('div');
      popoutCover.id = 'slack-autocomplete-popout-cover';
      popoutCover.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#1a1d21;';
      (document.body || document.documentElement).appendChild(popoutCover);
    };
    if (document.body) add();
    else window.addEventListener('DOMContentLoaded', add, { once: true });
  }
  function removePopoutCover() {
    const c = popoutCover || document.getElementById('slack-autocomplete-popout-cover');
    popoutCover = null;
    if (c) setTimeout(() => c.remove(), 250);
  }

  // Attribute + stylesheet based isolation, re-marked from scratch on every
  // tick: React RECYCLES DOM nodes, so a node hidden with an inline style
  // during boot can later be reused for visible content and stay hidden.
  // Clearing and re-marking each pass self-heals that.
  function ensureIsolationStyle() {
    if (document.getElementById('slack-autocomplete-popout-isolation')) return;
    const style = document.createElement('style');
    style.id = 'slack-autocomplete-popout-isolation';
    style.textContent = [
      '[data-saw-popout-hidden] { display: none !important; }',
      '[data-saw-popout-pane] {',
      '  position: fixed !important;',
      '  top: var(--saw-titlebar-h, 0px) !important; left: 0 !important;',
      '  right: 0 !important; bottom: 0 !important;',
      '  width: 100vw !important; height: auto !important;',
      '  max-width: none !important; background: #1a1d21 !important;',
      '}'
    ].join('\n');
    (document.head || document.documentElement).appendChild(style);
  }

  function isolatePaneElement(pane) {
    ensureIsolationStyle();
    document.querySelectorAll('[data-saw-popout-hidden]').forEach((el) => el.removeAttribute('data-saw-popout-hidden'));
    document.querySelectorAll('[data-saw-popout-pane]').forEach((el) => { if (el !== pane) el.removeAttribute('data-saw-popout-pane'); });
    let node = pane;
    while (node && node.parentElement && node.parentElement !== document.body && node !== document.body) {
      const parent = node.parentElement;
      for (const sib of Array.from(parent.children)) {
        if (sib === node) continue;
        if (sib.tagName === 'SCRIPT' || sib.tagName === 'STYLE' || sib.tagName === 'LINK') continue;
        // keep the theme gradient: it paints behind the transparent title strip
        if (sib.classList && sib.classList.contains('p-theme_background')) continue;
        sib.setAttribute('data-saw-popout-hidden', '1');
      }
      node = parent;
    }
    pane.setAttribute('data-saw-popout-pane', '1');
    return true;
  }

  function isolateThreadPane() {
    const pane = queryFirstPane(THREAD_PANE_CANDIDATES);
    if (!pane) return false;
    threadPopoutPaneMatch = pane.getAttribute('data-qa') || pane.className || pane.tagName;
    return isolatePaneElement(pane);
  }

  // Pop-out chrome polish (official-app parity): no back chevron / close-pane
  // X in thread windows.
  function installPopoutChromeStyle(rootClass) {
    const style = document.createElement('style');
    style.textContent = [
      // In the pop-out's narrow layout the close control renders as a "<"
      // chevron with aria-label="Close" (verified live) - hide every variant.
      `html.${rootClass} [data-qa="close_flexpane"],`,
      `html.${rootClass} [data-qa="flexpane_back"],`,
      `html.${rootClass} .p-flexpane_header button[aria-label="Close"],`,
      `html.${rootClass} .p-flexpane_header button[aria-label="Back"],`,
      `html.${rootClass} #slack-autocomplete-thread-popout-wrapper { display: none !important; }`
    ].join('\n');
    (document.head || document.documentElement).appendChild(style);
  }

  // Official-style pop-out title bar: a dedicated strip at the top holding
  // the traffic lights, back/forward buttons and the window title, acting as
  // the drag region (the official shell draws exactly this - titleBarStyle
  // hidden with a 31px overlay strip; see its window.name config).
  const POPOUT_TITLEBAR_H = 38;
  function installPopoutTitleBar(kind) {
    document.documentElement.style.setProperty('--saw-titlebar-h', POPOUT_TITLEBAR_H + 'px');
    const bar = document.createElement('div');
    bar.id = 'slack-autocomplete-popout-titlebar';
    bar.style.cssText = 'position:fixed;top:0;left:0;right:0;height:' + POPOUT_TITLEBAR_H + 'px;'
      + 'z-index:2147483200;-webkit-app-region:drag;display:flex;align-items:center;'
      + 'justify-content:center;color:#d1d2d3;font-size:13px;font-weight:600;'
      + 'background:#1a1d21;font-family:-apple-system,Segoe UI,sans-serif;';
    const titleEl = document.createElement('span');
    titleEl.style.cssText = 'max-width:60%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
    bar.appendChild(titleEl);
    const nav = document.createElement('div');
    nav.style.cssText = 'position:absolute;left:' + (IS_MAC_PRELOAD ? 84 : 8) + 'px;top:0;bottom:0;'
      + 'display:flex;align-items:center;gap:2px;-webkit-app-region:no-drag;';
    const mkNav = (glyph, fn) => {
      const b = document.createElement('button');
      b.textContent = glyph;
      b.style.cssText = 'background:none;border:0;color:#9a9a9a;font-size:16px;cursor:pointer;padding:2px 8px;';
      b.addEventListener('click', fn);
      return b;
    };
    nav.appendChild(mkNav('←', () => window.history.back()));
    nav.appendChild(mkNav('→', () => window.history.forward()));
    bar.appendChild(nav);
    const attach = () => { (document.body || document.documentElement).appendChild(bar); };
    if (document.body) attach();
    else window.addEventListener('DOMContentLoaded', attach, { once: true });

    const sync = () => {
      let t = String(document.title || '');
      const isThreadTitle = /\(Thread\)/.test(t);
      const isChannelTitle = /\(Channel\)/.test(t);
      t = t.replace(/\s*\((Thread|Channel|DM)\).*$/, '').replace(/\s*-\s*Slack\s*$/, '');
      if (kind === 'thread' || isThreadTitle) t = 'Thread in ' + t;
      else if (isChannelTitle) t = '#' + t;
      titleEl.textContent = t;
    };
    sync();
    setInterval(sync, 1000);

    // The strip is transparent so Slack's theme gradient
    // (.p-theme_background, spanning the whole window) shows through, like
    // the official pop-out chrome. Only the workspace content moves down.
    bar.style.background = 'transparent';
    const style = document.createElement('style');
    style.textContent = [
      // Padding, NOT margin: a wrapper margin collapses through to the client
      // container and drags the theme gradient down with it, leaving the
      // strip over a white body.
      'html.saw-channel-popout .p-ia4_client {',
      '  padding-top: var(--saw-titlebar-h) !important;',
      '  box-sizing: border-box !important;',
      '}',
      // The theme gradient div positions statically (auto top), so the
      // padding would push it below the strip - pin it to the full viewport.
      'html.saw-channel-popout .p-theme_background,',
      'html.saw-thread-popout .p-theme_background {',
      '  position: fixed !important; inset: 0 !important;',
      '  width: 100vw !important; height: 100vh !important;',
      '}',
      'html.saw-channel-popout, html.saw-thread-popout { background: #1a1d21; }'
    ].join('\n');
    (document.head || document.documentElement).appendChild(style);
  }

  function applyThreadPopoutMode() {
    if (document.documentElement.classList.contains('saw-thread-popout')) return;
    document.documentElement.classList.add('saw-thread-popout');
    installPopoutChromeStyle('saw-thread-popout');
    installPopoutTitleBar('thread');
    installPopoutCover();
    // Cold-boot path: the window boots on the channel route and we navigate
    // to the thread URL once the client shell is up. Adopted warm windows are
    // already routed client-side, so the pane just appears.
    const startedAt = Date.now();
    let lastAssign = Date.now(); // grace period covers adopted windows' client-side navigation
    const tick = () => {
      const pane = document.querySelector(THREAD_PANE_SELECTORS);
      if (pane) {
        if (isolateThreadPane()) removePopoutCover();
      } else if (!window.location.pathname.includes('/thread/') && THREAD_POPOUT_URL
        && document.querySelector('.p-client_container')
        && Date.now() - lastAssign > 2500) {
        lastAssign = Date.now();
        try { window.location.assign(THREAD_POPOUT_URL); } catch (err) { /* ignore */ }
      }
      if (Date.now() - startedAt > 25000) removePopoutCover(); // never brick the window
    };
    tick();
    setInterval(tick, 300);
  }

  // Channel pop-out. Recipe verified live over CDP against a real pop-out
  // window (screenshot-matched to the official app's channel window):
  //   - hide by stable class: rail, sidebar, control strip (the +/theme/
  //     avatar buttons), global top nav
  //   - collapse the leftover grid tracks: the rail column on the wrapper and
  //     the sidebar column on the tabpanel (Slack's fresh-boot DOM places the
  //     sidebar INSIDE the tabpanel grid: areas "sidebar primary"). The :has()
  //     rule only adjusts columns, never display, so it cannot nuke content.
  //   - a JS tick hides stray hash-classed gutter containers at the layout
  //     level (other boot variants put the sidebar wrapper there); React
  //     focus wrappers (display:contents) are left alone.
  function applyChannelPopoutMode(targetPath) {
    if (document.documentElement.classList.contains('saw-channel-popout')) return;
    document.documentElement.classList.add('saw-channel-popout');
    installPopoutChromeStyle('saw-channel-popout');
    installPopoutTitleBar('channel');
    const style = document.createElement('style');
    style.id = 'slack-autocomplete-channel-popout';
    style.textContent = [
      'html.saw-channel-popout .p-tab_rail,',
      'html.saw-channel-popout [data-qa="tab_rail_desktop"],',
      'html.saw-channel-popout .p-channel_sidebar,',
      'html.saw-channel-popout .p-view_contents--sidebar,',
      'html.saw-channel-popout [data-qa="channel_sidebar"],',
      'html.saw-channel-popout .p-control_strip,',
      // The hidden sidebar's resizer handle stays interactive otherwise (a
      // draggable blue divider floating mid-window).
      'html.saw-channel-popout .p-resizer,',
      'html.saw-channel-popout .p-resizer__input,',
      'html.saw-channel-popout .p-ia4_top_nav { display: none !important; }',
      'html.saw-channel-popout .p-client_workspace_wrapper { grid-template-columns: 0 1fr !important; }',
      'html.saw-channel-popout .p-client_workspace__tabpanel:has(.p-view_contents--sidebar) { grid-template-columns: 0 1fr !important; }'
    ].join('\n');
    (document.head || document.documentElement).appendChild(style);
    installPopoutCover();
    const startedAt = Date.now();
    const tick = () => {
      const layout = document.querySelector('.p-client_workspace__layout');
      if (layout) {
        for (const el of Array.from(layout.children)) {
          if (el.classList.contains('p-client_workspace__tabpanel')) continue;
          if (el.tagName === 'SCRIPT' || el.tagName === 'STYLE') continue;
          if (getComputedStyle(el).display === 'contents') continue;
          el.style.setProperty('display', 'none', 'important');
        }
      }
      const routed = !targetPath || window.location.pathname === targetPath;
      if (routed && document.querySelector('.p-view_header, [data-qa="message_pane"]')) removePopoutCover();
      if (Date.now() - startedAt > 20000) removePopoutCover();
    };
    tick();
    setInterval(tick, 500);
  }

  // hiddenInset title bar in regular windows: pad Slack's top nav so its
  // leftmost controls aren't covered by the macOS traffic lights, and make it
  // the window drag strip (like the official app's own title area).
  function applyHiddenTitleBarPadding() {
    if (!IS_MAC_PRELOAD) return;
    const style = document.createElement('style');
    style.textContent = [
      '.p-ia4_top_nav { padding-left: 72px !important; -webkit-app-region: drag; }',
      '.p-ia4_top_nav button, .p-ia4_top_nav a, .p-ia4_top_nav input, .p-ia4_top_nav [role="button"], .p-ia4_top_nav [role="search"] { -webkit-app-region: no-drag; }'
    ].join('\n');
    (document.head || document.documentElement).appendChild(style);
  }

  // ===================== Downloads panel (official-style pane) =====================
  function formatBytes(n) {
    if (!isFinite(n) || n <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    let i = 0;
    let v = n;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    return (v >= 10 || i === 0 ? Math.round(v) : v.toFixed(1)) + ' ' + units[i];
  }

  function setupDownloadsPanel() {
    if (!ipcRenderer) return;
    const items = new Map(); // id -> snapshot (insertion order = arrival order)
    let root = null;
    let listEl = null;
    let visible = false;

    function ensurePanel() {
      if (root) return;
      root = document.createElement('div');
      root.id = 'slack-autocomplete-downloads-panel';
      root.style.cssText = 'position:fixed;top:44px;right:8px;width:340px;max-height:70vh;z-index:2147483000;'
        + 'background:#1d1c1d;color:#fff;border:1px solid #3a393a;border-radius:10px;'
        + 'box-shadow:0 10px 40px rgba(0,0,0,0.5);display:none;flex-direction:column;'
        + 'font-family:-apple-system,Segoe UI,sans-serif;overflow:hidden;';
      const header = document.createElement('div');
      header.style.cssText = 'display:flex;align-items:center;justify-content:space-between;padding:10px 12px;border-bottom:1px solid #3a393a;';
      const title = document.createElement('div');
      title.textContent = 'Downloads';
      title.style.cssText = 'font-weight:700;font-size:14px;';
      const headerBtns = document.createElement('div');
      const clearBtn = document.createElement('button');
      clearBtn.textContent = 'Clear';
      clearBtn.style.cssText = 'background:none;border:0;color:#9a9a9a;cursor:pointer;font-size:12px;margin-right:8px;';
      clearBtn.addEventListener('click', async () => {
        try {
          const remaining = await ipcRenderer.invoke('slack-autocomplete:downloads:clear');
          items.clear();
          for (const it of (remaining || [])) items.set(it.id, it);
          render();
        } catch (err) { log('downloads clear failed', err); }
      });
      const closeBtn = document.createElement('button');
      closeBtn.textContent = '✕';
      closeBtn.style.cssText = 'background:none;border:0;color:#9a9a9a;cursor:pointer;font-size:13px;';
      closeBtn.addEventListener('click', () => setVisible(false));
      headerBtns.appendChild(clearBtn);
      headerBtns.appendChild(closeBtn);
      header.appendChild(title);
      header.appendChild(headerBtns);
      listEl = document.createElement('div');
      listEl.style.cssText = 'overflow-y:auto;padding:6px 0;';
      root.appendChild(header);
      root.appendChild(listEl);
      document.body.appendChild(root);
    }

    function actionButton(label, handler) {
      const b = document.createElement('button');
      b.textContent = label;
      b.style.cssText = 'background:#2c2d30;border:1px solid #4a4a4a;border-radius:5px;color:#d1d2d3;'
        + 'cursor:pointer;font-size:11px;padding:3px 8px;margin-right:6px;';
      b.addEventListener('click', handler);
      return b;
    }

    function render() {
      ensurePanel();
      listEl.textContent = '';
      const all = Array.from(items.values());
      if (!all.length) {
        const empty = document.createElement('div');
        empty.textContent = 'No downloads yet';
        empty.style.cssText = 'padding:18px 12px;color:#9a9a9a;font-size:13px;text-align:center;';
        listEl.appendChild(empty);
        return;
      }
      for (const it of all) {
        const row = document.createElement('div');
        row.style.cssText = 'padding:8px 12px;border-bottom:1px solid #2a292a;';
        const name = document.createElement('div');
        name.textContent = it.filename || '(file)';
        name.style.cssText = 'font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;';
        row.appendChild(name);
        const status = document.createElement('div');
        status.style.cssText = 'font-size:11px;color:#9a9a9a;margin:3px 0 5px;';
        if (it.state === 'progressing') {
          const pct = it.totalBytes > 0 ? Math.round((it.receivedBytes / it.totalBytes) * 100) : null;
          status.textContent = formatBytes(it.receivedBytes)
            + (it.totalBytes > 0 ? ' of ' + formatBytes(it.totalBytes) + ' (' + pct + '%)' : '');
          const barWrap = document.createElement('div');
          barWrap.style.cssText = 'height:4px;background:#3a393a;border-radius:2px;overflow:hidden;margin-bottom:6px;';
          const bar = document.createElement('div');
          bar.style.cssText = 'height:100%;background:#36c5f0;width:' + (pct === null ? 30 : pct) + '%;';
          barWrap.appendChild(bar);
          row.appendChild(status);
          row.appendChild(barWrap);
          row.appendChild(actionButton('Cancel', () => {
            ipcRenderer.invoke('slack-autocomplete:downloads:cancel', it.id).catch(() => {});
          }));
        } else if (it.state === 'completed') {
          status.textContent = formatBytes(it.totalBytes || it.receivedBytes) + ' - completed';
          row.appendChild(status);
          row.appendChild(actionButton('Open', () => {
            ipcRenderer.invoke('slack-autocomplete:downloads:open', it.id).catch(() => {});
          }));
          row.appendChild(actionButton('Show in Finder', () => {
            ipcRenderer.invoke('slack-autocomplete:downloads:show-in-folder', it.id).catch(() => {});
          }));
        } else {
          status.textContent = it.state; // cancelled | interrupted
          status.style.color = '#e01e5a';
          row.appendChild(status);
        }
        listEl.appendChild(row);
      }
    }

    function setVisible(v) {
      ensurePanel();
      visible = v;
      root.style.display = v ? 'flex' : 'none';
      if (v) render();
    }

    async function refreshFromMain() {
      try {
        const list = await ipcRenderer.invoke('slack-autocomplete:downloads:list');
        items.clear();
        for (const it of (list || [])) items.set(it.id, it);
      } catch (err) { log('downloads list failed', err); }
    }

    ipcRenderer.on('slack-autocomplete:download-event', (_event, snapshot) => {
      if (!snapshot || !snapshot.id) return;
      const isNew = !items.has(snapshot.id);
      items.set(snapshot.id, snapshot);
      if (isNew && snapshot.state === 'progressing') setVisible(true); // surface new downloads
      if (visible) render();
    });

    ipcRenderer.on('slack-autocomplete:toggle-downloads', async () => {
      if (!visible) await refreshFromMain();
      setVisible(!visible);
    });

    refreshFromMain();
  }
  // =================== end downloads panel ===================

  // Report signed-in workspaces to the main process so the Workspace menu
  // (Cmd+1..9 switching) stays in sync with Slack's own local config.
  function setupTeamsReporter() {
    if (!ipcRenderer) return;
    const report = () => {
      try {
        const raw = window.localStorage.getItem('localConfig_v2');
        const cfg = JSON.parse(raw);
        const teams = Object.values((cfg && cfg.teams) || {})
          .filter((t) => t && t.id)
          .map((t) => ({ id: t.id, name: t.name }));
        if (teams.length) ipcRenderer.invoke('slack-autocomplete:teams', teams).catch(() => {});
      } catch (err) { /* ignore */ }
    };
    report();
    setInterval(report, 60000);
  }

  // ===================== Channel JSON export (web API) =====================
  function exportSleep(ms, signal) {
    return new Promise((resolve, reject) => {
      if (signal && signal.aborted) { const e = new Error('aborted'); e.name = 'AbortError'; return reject(e); }
      const t = setTimeout(resolve, ms);
      if (signal) signal.addEventListener('abort', () => { clearTimeout(t); const e = new Error('aborted'); e.name = 'AbortError'; reject(e); }, { once: true });
    });
  }

  function exportTsStamp() {
    const d = new Date();
    const p = (n) => String(n).padStart(2, '0');
    return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '-' + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
  }

  function getExportConfig(log, opts) {
    log = log || function () {};
    opts = opts || {};
    let ids = exportCore.parseClientUrl(window.location.pathname);
    if (!ids && opts.requireChannel === false) {
      const team = exportCore.parseClientTeam(window.location.pathname);
      if (team) ids = { teamId: team.teamId, channelId: null };
    }
    if (!ids) {
      throw new Error(opts.requireChannel === false
        ? 'Could not determine the workspace from the URL.'
        : 'Open a channel first (no channel in the URL).');
    }
    log('url: teamId=' + ids.teamId + ' channelId=' + (ids.channelId || '(none)'));
    const raw = window.localStorage.getItem('localConfig_v2');
    const token = exportCore.getTokenForTeam(raw, ids.teamId);
    const apiBase = exportCore.inferApiBase(raw, ids.teamId);
    log('localConfig_v2 present=' + (!!raw)
      + ' token=' + (token ? 'found(' + token.length + ' chars)' : 'MISSING')
      + ' apiBase=' + (apiBase || 'MISSING'));
    if (!token || !apiBase) throw new Error('Could not find the Slack token/config in this workspace.');
    return { teamId: ids.teamId, channelId: ids.channelId, token, apiBase, localConfigRaw: raw };
  }

  function createApiCall(cfg, signal, log) {
    log = log || function () {};
    const lastAt = {};
    async function spaceFor(method) {
      const tier = exportCore.methodTier(method);
      const interval = exportCore.tierIntervalMs(method);
      const now = Date.now();
      const wait = Math.max(0, (lastAt[tier] || 0) + interval - now);
      if (wait) await exportSleep(wait, signal);
      lastAt[tier] = Date.now();
    }
    return async function apiCall(method, params) {
      let attempt = 0;
      const url = cfg.apiBase + method + '?slack_route=' + encodeURIComponent(cfg.teamId);
      for (;;) {
        if (signal && signal.aborted) { const e = new Error('aborted'); e.name = 'AbortError'; throw e; }
        await spaceFor(method);
        log('-> ' + method + '  ' + url);
        // The actual HTTP request runs in the main process (net.fetch) to bypass renderer
        // cross-origin CORS and reuse the session's HttpOnly auth cookie.
        let res;
        try {
          res = await ipcRenderer.invoke('slack-autocomplete:api-call', {
            apiBase: cfg.apiBase, teamId: cfg.teamId, token: cfg.token, method, params: params || {}
          });
        } catch (e) {
          if (signal && signal.aborted) throw e;
          attempt++;
          log('   request ERROR: ' + (e && e.message) + '  [attempt ' + attempt + ']');
          if (attempt > 2) {
            const err = new Error(method + ' request failed: ' + (e && e.message) + '  (url: ' + url + ')');
            err.cause = e;
            throw err;
          }
          await exportSleep(exportCore.backoffDelay(attempt), signal);
          continue;
        }
        log('<- ' + method + '  HTTP ' + res.status);
        if (res.status === 429) { log('   rate-limited; waiting'); await exportSleep(exportCore.parseRetryAfter(res.retryAfter) * 1000, signal); continue; }
        if (res.status >= 500) { attempt++; if (attempt > 2) throw new Error('Slack server error ' + res.status + ' for ' + method); await exportSleep(exportCore.backoffDelay(attempt), signal); continue; }
        const json = res.json;
        if (json && json.ok === false) {
          log('   ' + method + ' ok=false error=' + json.error);
          if (json.error === 'ratelimited') { await exportSleep(exportCore.parseRetryAfter(res.retryAfter) * 1000, signal); continue; }
        }
        return json;
      }
    };
  }

  function createExportOverlay(titleText) {
    const root = document.createElement('div');
    root.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:rgba(0,0,0,0.55);display:flex;align-items:center;justify-content:center;font-family:-apple-system,Segoe UI,sans-serif;';
    const box = document.createElement('div');
    box.style.cssText = 'background:#1d1c1d;color:#fff;min-width:480px;max-width:80vw;padding:20px 22px;border-radius:10px;box-shadow:0 10px 40px rgba(0,0,0,0.5);';
    const title = document.createElement('div');
    title.textContent = titleText || 'Exporting channel...';
    title.style.cssText = 'font-weight:700;font-size:15px;margin-bottom:10px;';
    const phase = document.createElement('div');
    phase.style.cssText = 'font-size:13px;opacity:0.85;margin-bottom:10px;';
    const barWrap = document.createElement('div');
    barWrap.style.cssText = 'height:8px;background:#3a393a;border-radius:4px;overflow:hidden;margin-bottom:14px;';
    const bar = document.createElement('div');
    bar.style.cssText = 'height:100%;width:0;background:#36c5f0;transition:width 0.2s;';
    barWrap.appendChild(bar);
    // Indeterminate animation for phases where the total is unknown (paginated fetches).
    const styleEl = document.createElement('style');
    styleEl.textContent = '@keyframes slack-export-indet { 0% { margin-left:-35%; } 100% { margin-left:100%; } }';
    root.appendChild(styleEl);
    function barDeterminate(pct) { bar.style.animation = ''; bar.style.marginLeft = '0'; bar.style.width = pct + '%'; }
    function barIndeterminate() {
      if (!bar.style.animation) { bar.style.width = '35%'; bar.style.animation = 'slack-export-indet 1.2s linear infinite'; }
    }
    const logEl = document.createElement('pre');
    logEl.style.cssText = 'font-size:11px;line-height:1.45;color:#cfd3d6;background:#121212;border-radius:6px;padding:8px 10px;margin:0 0 12px;max-height:220px;overflow:auto;white-space:pre-wrap;word-break:break-all;';
    const cancelBtn = document.createElement('button');
    cancelBtn.textContent = 'Cancel';
    cancelBtn.style.cssText = 'background:#444;color:#fff;border:0;border-radius:6px;padding:7px 14px;cursor:pointer;font-size:13px;';
    box.appendChild(title); box.appendChild(phase); box.appendChild(barWrap); box.appendChild(logEl); box.appendChild(cancelBtn);
    root.appendChild(box);
    // modal: swallow clicks behind the overlay
    root.addEventListener('click', (e) => { if (e.target === root) e.stopPropagation(); }, true);
    document.body.appendChild(root);
    let cancelCb = null;
    cancelBtn.addEventListener('click', () => { cancelBtn.disabled = true; cancelBtn.textContent = 'Canceling...'; if (cancelCb) cancelCb(); });
    return {
      onCancel(cb) { cancelCb = cb; },
      setPhase(text) { phase.textContent = text; },
      appendLog(line) {
        const t = new Date();
        const p2 = (n) => String(n).padStart(2, '0');
        const ts = p2(t.getHours()) + ':' + p2(t.getMinutes()) + ':' + p2(t.getSeconds());
        logEl.textContent += '[' + ts + '] ' + line + '\n';
        logEl.scrollTop = logEl.scrollHeight;
      },
      setProgress(label, cur, total) {
        if (total && total > 0) { barDeterminate(Math.round((cur / total) * 100)); phase.textContent = label + ' ' + cur + ' / ' + total; }
        else { barIndeterminate(); phase.textContent = label + ' ' + cur + '...'; }
      },
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
      done(text) { title.textContent = 'Export complete'; phase.textContent = text; barDeterminate(100); cancelBtn.textContent = 'Close'; cancelBtn.disabled = false; cancelBtn.onclick = () => root.remove(); },
      fail(text) { title.textContent = 'Export failed'; phase.textContent = text; barDeterminate(100); bar.style.background = '#e01e5a'; cancelBtn.textContent = 'Close'; cancelBtn.disabled = false; cancelBtn.onclick = () => root.remove(); },
      destroy() { if (root.parentNode) root.remove(); },
    };
  }

  function phaseLabel(p) {
    if (p === 'channels') return 'Fetching channels';
    if (p === 'messages') return 'Fetching messages';
    if (p === 'threads') return 'Fetching threads';
    if (p === 'thread-page') return 'Fetching thread replies';
    if (p === 'reactions') return 'Resolving reaction authors';
    if (p === 'actors') return 'Resolving users';
    return p;
  }

  let exportInProgress = false;
  ipcRenderer.on('slack-autocomplete:export-channel', async () => {
    if (exportInProgress) return;
    exportInProgress = true;
    const overlay = createExportOverlay();
    const log = (msg) => { try { console.log('[slack-export]', msg); } catch (e) {} overlay.appendLog(msg); };
    const ac = new AbortController();
    overlay.onCancel(() => { log('cancel requested'); ac.abort(); });
    let saveToken = null;
    try {
      log('starting export');
      const cfg = getExportConfig(log);
      const apiCall = createApiCall(cfg, ac.signal, log);
      overlay.setPhase('Reading channel info...');
      let channel = { id: cfg.channelId, name: cfg.channelId };
      try {
        const info = await apiCall('conversations.info', { channel: cfg.channelId });
        if (info && info.ok && info.channel) channel = info.channel;
        log('channel: ' + (channel.name || cfg.channelId));
      } catch (e) {
        if (e && e.name === 'AbortError') throw e;
        log('conversations.info failed (continuing with channel id): ' + (e && e.message));
      }
      const workspace = exportCore.workspaceFromConfig(cfg.localConfigRaw, cfg.teamId);

      const suggested = 'slack-export-' + (channel.name || cfg.channelId) + '-' + exportTsStamp() + '.json';
      log('choosing save destination...');
      const begin = await ipcRenderer.invoke('slack-autocomplete:save-export:begin', { suggestedName: suggested });
      if (begin && begin.canceled) { log('save dialog canceled'); overlay.destroy(); return; }
      saveToken = begin.token;

      const exportedAt = new Date().toISOString();
      let lastPhase = null;
      const doc = await exportCore.runExport(apiCall, {
        channelId: cfg.channelId, channel, workspace, exportedAt
      }, {
        signal: ac.signal,
        onProgress: (p, cur, total) => {
          overlay.setProgress(phaseLabel(p), cur, total);
          if (p !== lastPhase) { lastPhase = p; log(phaseLabel(p) + '...'); }
          // Verbose progress: unknown-total phases fire once per fetched page;
          // known-total phases fire per item, so log milestones + the last one.
          if (total && total > 0) { if (cur === total || cur % 25 === 0) log(phaseLabel(p) + ': ' + cur + ' / ' + total); }
          else log(phaseLabel(p) + ': ' + cur + ' so far');
        },
      });
      log('assembled: ' + doc.export.counts.messages + ' messages, '
        + doc.export.counts.replies + ' replies, '
        + doc.export.counts.reactions + ' reactions, '
        + Object.keys(doc.users || {}).length + ' users; complete=' + doc.export.complete);

      overlay.setPhase('Saving file...');
      log('writing file...');
      for (const chunk of exportCore.streamExportJson(doc)) {
        await ipcRenderer.invoke('slack-autocomplete:save-export:write', { token: saveToken, chunk });
      }
      const res = await ipcRenderer.invoke('slack-autocomplete:save-export:commit', { token: saveToken });
      log('saved: ' + res.path);
      overlay.done('Saved to ' + res.path + (doc.export.complete ? '' : ' (incomplete - see export.warnings)'));
    } catch (e) {
      log('FAILED: ' + ((e && e.message) || e));
      if (saveToken) { try { await ipcRenderer.invoke('slack-autocomplete:save-export:abort', { token: saveToken }); } catch (e2) { /* ignore */ } }
      if (e && e.name === 'AbortError') overlay.done('Export canceled.');
      else overlay.fail(String((e && e.message) || e));
    } finally {
      exportInProgress = false;
    }
  });

  // ===================== Channel list export (web API) =====================
  // Exports the names + IDs of every channel the user is a member of
  // (public, private, or both) as JSON or plain text (one channel per line).
  ipcRenderer.on('slack-autocomplete:export-channel-list', async (_event, opts) => {
    if (exportInProgress) return;
    exportInProgress = true;
    const types = exportCore.normalizeChannelTypes(opts && opts.types);
    const typesLabel = exportCore.channelTypesLabel(types);
    const overlay = createExportOverlay('Exporting channel list (' + typesLabel + ')...');
    const log = (msg) => { try { console.log('[slack-export]', msg); } catch (e) {} overlay.appendLog(msg); };
    const ac = new AbortController();
    overlay.onCancel(() => { log('cancel requested'); ac.abort(); });
    let saveToken = null;
    try {
      log('starting channel list export (' + typesLabel + ')');
      const cfg = getExportConfig(log, { requireChannel: false });
      const apiCall = createApiCall(cfg, ac.signal, log);
      const workspace = exportCore.workspaceFromConfig(cfg.localConfigRaw, cfg.teamId);

      const suggested = 'slack-channels-' + typesLabel + '-' + (workspace.name || cfg.teamId) + '-' + exportTsStamp() + '.json';
      log('choosing save destination...');
      const begin = await ipcRenderer.invoke('slack-autocomplete:save-export:begin', { suggestedName: suggested, allowText: true });
      if (begin && begin.canceled) { log('save dialog canceled'); overlay.destroy(); return; }
      saveToken = begin.token;
      const format = begin.format === 'txt' ? 'txt' : 'json';
      log('format: ' + format);

      const channels = await exportCore.fetchAllMemberChannels(apiCall, { types }, {
        signal: ac.signal,
        onProgress: (p, cur, total) => {
          overlay.setProgress(phaseLabel(p), cur, total);
          log(phaseLabel(p) + ': ' + cur + ' so far');
        },
      });
      log('fetched ' + channels.length + ' channels');

      overlay.setPhase('Saving file...');
      const content = format === 'txt'
        ? exportCore.formatChannelListText(channels)
        : JSON.stringify(exportCore.buildChannelListDoc(channels, {
            exportedAt: new Date().toISOString(), workspace, types
          }), null, 2) + '\n';
      await ipcRenderer.invoke('slack-autocomplete:save-export:write', { token: saveToken, chunk: content });
      const res = await ipcRenderer.invoke('slack-autocomplete:save-export:commit', { token: saveToken });
      log('saved: ' + res.path);
      overlay.done('Saved ' + channels.length + ' channels to ' + res.path);
    } catch (e) {
      log('FAILED: ' + ((e && e.message) || e));
      if (saveToken) { try { await ipcRenderer.invoke('slack-autocomplete:save-export:abort', { token: saveToken }); } catch (e2) { /* ignore */ } }
      if (e && e.name === 'AbortError') overlay.done('Export canceled.');
      else overlay.fail(String((e && e.message) || e));
    } finally {
      exportInProgress = false;
    }
  });
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

  // ===================== Channel sections import (web API) =====================
  // Additive apply: creates missing sections, moves listed channels into them.
  // Never deletes anything. Nothing is mutated before the user clicks Apply.
  ipcRenderer.on('slack-autocomplete:import-sections', async () => {
    if (exportInProgress) return;
    exportInProgress = true;
    const overlay = createExportOverlay('Importing channel sections...');
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

      // Execute: create sections first so moves have a target id.
      const idByName = new Map();
      let created = 0, moved = 0, failed = 0;
      let step = 0;
      const totalSteps = plan.create.length + plan.moves.length;
      for (const s of plan.create) {
        if (ac.signal.aborted) { const e = new Error('aborted'); e.name = 'AbortError'; throw e; }
        overlay.setProgress('Applying', ++step, totalSteps);
        // Live-verified: create takes a BARE emoji name ('wrench'); the
        // colon-wrapped form ':wrench:' fails with emoji_invalid. Omit the
        // param entirely when the section has no emoji ('' is unverified).
        const params = { name: s.name };
        if (s.emoji) params.emoji = s.emoji;
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
  // =================== end channel list export ===================

  if (document.readyState === 'loading') {
    window.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
EOF

# ---------------------------------------------------------------------------
# Copy pure export-core module (unit-tested separately) into the app dir
# ---------------------------------------------------------------------------
if [[ -f "$SCRIPT_DIR/export-core.js" ]]; then
  cp "$SCRIPT_DIR/export-core.js" "$APP_DIR/export-core.js"
  echo "Copied export-core.js"
else
  echo "WARNING: export-core.js not found next to the script; export feature will not load." >&2
fi

echo "Created preload.js"

ICON_ARGS=()
if [[ -f "$APP_ICON" ]]; then
  ICON_ARGS+=("--icon=$APP_ICON")
fi

# TCC usage descriptions: without these macOS terminates the app the moment
# a huddle asks for the microphone or camera.
cat > "$APP_DIR/extend-info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSMicrophoneUsageDescription</key>
  <string>Microphone access is used for Slack huddles and calls.</string>
  <key>NSCameraUsageDescription</key>
  <string>Camera access is used for Slack huddles and calls.</string>
</dict>
</plist>
PLIST

echo "Packaging macOS app with electron-packager..."
npx electron-packager . "$APP_NAME" \
  --platform=darwin \
  --arch="$EP_ARCH" \
  --out=dist \
  --overwrite \
  --app-bundle-id="$BUNDLE_ID" \
  --protocol=slack \
  --protocol-name="Slack URL" \
  --extend-info="$APP_DIR/extend-info.plist" \
  "${ICON_ARGS[@]}" > /dev/null

APP_PATH="$APP_DIR/dist/${APP_NAME}-darwin-${EP_ARCH}/${APP_NAME}.app"

# ---------------------------------------------------------------------------
# Code signing: use a real identity from the local keychain when available.
# The identity is auto-detected (or taken from SLACK_CODESIGN_IDENTITY) and is
# never written to the repo. CI runners have no signing identity, so builds
# there keep the ad-hoc signature applied by electron-packager/the workflow.
# ---------------------------------------------------------------------------
CODESIGN_IDENTITY="${SLACK_CODESIGN_IDENTITY:-}"
if [[ -z "$CODESIGN_IDENTITY" ]] && command -v security >/dev/null 2>&1; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
  fi
fi
if [[ -n "$CODESIGN_IDENTITY" ]]; then
  echo "Code signing with identity: $CODESIGN_IDENTITY"
  codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_PATH"
  codesign --verify --verbose=2 "$APP_PATH"
  echo "Signed. Notification Center identity will persist across rebuilds."
else
  echo "No code-signing identity found; keeping ad-hoc signature."
fi

echo
echo "Done."
echo
echo "To run your custom Slack app:"
echo "  open \"$APP_PATH\""
echo
echo "For dev mode instead of the packaged .app:"
echo "  cd \"$APP_DIR\""
echo "  npm start"
echo
echo "Use \"Clear Cache (Keep Login)\" in the menubar to refresh Slack without signing out."
echo "Use \"Clear Cache (Full Reset)\" for a complete reset if things are really wedged."
