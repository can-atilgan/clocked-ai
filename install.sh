#!/usr/bin/env bash
set -euo pipefail

REPO="can-atilgan/aihours"
AIHOURS_DIR="$HOME/.aihours"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

echo ""
echo "  AI Hours — installer"
echo ""

# ── 1. Write record.js ───────────────────────────────────────────
mkdir -p "$AIHOURS_DIR"
cat > "$AIHOURS_DIR/record.js" << 'RECORDJS'
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const DIR = path.join(os.homedir(), '.aihours');
const LOG = path.join(DIR, 'events.jsonl');

fs.mkdirSync(DIR, { recursive: true });

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => (raw += chunk));
process.stdin.on('end', () => {
  try {
    const payload = JSON.parse(raw);

    const event      = payload.hook_event_name;
    const session_id = payload.session_id;
    const cwd        = payload.cwd;
    const tool       = payload.tool_name || null;

    let meta = null;
    if (event === 'SessionStart' && payload.source) meta = { source: payload.source };
    if (event === 'SessionEnd'   && payload.reason) meta = { reason: payload.reason };

    const line = JSON.stringify({ ts: new Date().toISOString(), event, session_id, cwd, tool, meta });
    fs.appendFileSync(LOG, line + '\n');
  } catch (_) {
    // never fail — must not interrupt Claude
  }
  process.exit(0);
});
RECORDJS
echo "  [ok] Hook script written to $AIHOURS_DIR/record.js"

# ── 2. Merge hooks into settings.json ────────────────────────────
mkdir -p "$CLAUDE_DIR"

# Node script to safely merge hooks without clobbering existing settings
node << 'MERGEJS'
const fs = require('fs');
const os = require('os');
const path = require('path');
const settingsPath = path.join(os.homedir(), '.claude', 'settings.json');
let settings = {};
try { settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8')); } catch (e) { if (e.code !== 'ENOENT') { console.error('  [error] Cannot parse ' + settingsPath); process.exit(1); } }
if (!settings.hooks) settings.hooks = {};
const events = ['SessionStart', 'SessionEnd', 'UserPromptSubmit', 'Stop'];
const hookEntry = { hooks: [{ type: 'command', command: 'node ~/.aihours/record.js', async: true }] };
let added = 0;
for (const ev of events) {
  if (!settings.hooks[ev]) settings.hooks[ev] = [];
  const exists = settings.hooks[ev].some(g => Array.isArray(g.hooks) && g.hooks.some(h => h.command && h.command.includes('aihours/record.js')));
  if (!exists) { settings.hooks[ev].push(hookEntry); added++; }
}
fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
if (added > 0) console.log('  [ok] ' + added + ' hook event(s) registered');
else console.log('  [ok] Hooks already configured');
MERGEJS

# ── 3. Download and install .vsix ─────────────────────────────────
echo "  [..] Fetching latest release..."
VSIX_URL=$(curl -fsL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
  | grep '"browser_download_url".*\.vsix"' \
  | head -1 \
  | sed 's/.*"browser_download_url": *"\(.*\)"/\1/') || true

if [ -z "$VSIX_URL" ]; then
  echo "  [skip] No .vsix found in releases — install manually"
  echo "         Build it: git clone https://github.com/$REPO && cd aihours && npm install && npm run package"
  echo "         Then: code --install-extension aihours-*.vsix"
else
  VSIX_TMP=$(mktemp /tmp/aihours-XXXXXX.vsix)
  curl -fsSL -o "$VSIX_TMP" "$VSIX_URL"
  code --install-extension "$VSIX_TMP" --force 2>/dev/null && echo "  [ok] Extension installed" || echo "  [skip] Could not auto-install — run: code --install-extension $VSIX_TMP"
  rm -f "$VSIX_TMP"
fi

echo ""
echo "  Done! Restart Claude Code and open the AI Hours panel in VSCode."
echo ""
