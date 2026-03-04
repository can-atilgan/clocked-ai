#!/usr/bin/env bash
set -euo pipefail

REPO="can-atilgan/clocked-ai"
CLOCKED_DIR="$HOME/.clocked"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

echo ""
echo "  Clocked AI — installer"
echo ""

# ── 1. Write record.js ───────────────────────────────────────────
mkdir -p "$CLOCKED_DIR"
cat > "$CLOCKED_DIR/record.js" << 'RECORDJS'
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const DIR = path.join(os.homedir(), '.clocked');
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
echo "  [ok] Hook script written to $CLOCKED_DIR/record.js"

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
const hookEntry = { hooks: [{ type: 'command', command: 'node ~/.clocked/record.js', async: true }] };
let added = 0;
for (const ev of events) {
  if (!settings.hooks[ev]) settings.hooks[ev] = [];
  const exists = settings.hooks[ev].some(g => Array.isArray(g.hooks) && g.hooks.some(h => h.command && h.command.includes('clocked/record.js')));
  if (!exists) { settings.hooks[ev].push(hookEntry); added++; }
}
fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
if (added > 0) console.log('  [ok] ' + added + ' hook event(s) registered');
else console.log('  [ok] Hooks already configured');
MERGEJS

# ── 3. Download and install .vsix ─────────────────────────────────
echo "  [..] Fetching latest release..."

# Use Node to parse JSON — grep/sed are unreliable across platforms
VSIX_URL=$(node -e "
  const https = require('https');
  const url = 'https://api.github.com/repos/$REPO/releases/latest';
  https.get(url, { headers: { 'User-Agent': 'clocked-ai-installer' } }, res => {
    let data = '';
    res.on('data', c => data += c);
    res.on('end', () => {
      try {
        const rel = JSON.parse(data);
        const asset = (rel.assets || []).find(a => a.name && a.name.endsWith('.vsix'));
        if (asset) process.stdout.write(asset.browser_download_url);
        else { console.error('  \x1b[31m[error]\x1b[0m No .vsix asset in latest release'); process.exit(1); }
      } catch (e) { console.error('  \x1b[31m[error]\x1b[0m Failed to parse GitHub response: ' + e.message); process.exit(1); }
    });
  }).on('error', e => { console.error('  \x1b[31m[error]\x1b[0m Could not reach GitHub: ' + e.message); process.exit(1); });
") || VSIX_URL=""

INSTALLED=false

if [ -z "$VSIX_URL" ]; then
  echo "  \033[31m[fail]\033[0m Could not fetch .vsix from GitHub releases"
  echo "         Install manually: https://github.com/$REPO/releases"
  echo "         Or build it: git clone https://github.com/$REPO && cd clocked-ai && npm install && npm run package"
  echo "         Then: code --install-extension clocked-ai-*.vsix"
else
  VSIX_TMP="$(mktemp /tmp/clocked-XXXXXX).vsix"
  if curl -fsSL -o "$VSIX_TMP" "$VSIX_URL"; then
    if code --install-extension "$VSIX_TMP" --force >/dev/null 2>&1; then
      echo "  [ok] Extension installed"
      rm -f "$VSIX_TMP"
      INSTALLED=true
    else
      echo "  \033[33m[info]\033[0m 'code' CLI not in PATH. Install manually:"
      echo "         1. Open VSCode → Cmd+Shift+P → 'Shell Command: Install code command in PATH'"
      echo "         2. Then run: code --install-extension $VSIX_TMP"
      echo "         Or drag-and-drop the .vsix into VSCode Extensions panel."
    fi
  else
    echo "  \033[31m[fail]\033[0m Download failed from: $VSIX_URL"
    rm -f "$VSIX_TMP"
  fi
fi

echo ""
if [ "$INSTALLED" = true ]; then
  echo "  Done! Restart Claude Code and open the Clocked AI panel in VSCode."
else
  echo "  Hooks are ready. Install the extension above, then restart Claude Code."
fi
echo ""
