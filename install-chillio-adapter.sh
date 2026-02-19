#!/bin/bash
# ============================================================
#  Chillio Adapter Installer
#  Bridges any Stremio addon to the ChillLink Protocol
#  for use with the Chillio app — with local HTTPS via Caddy
#
#  What this installs:
#    - Node.js 20
#    - Chillio Adapter (translates Stremio → ChillLink Protocol)
#    - Caddy with Cloudflare DNS-Challenge SSL (no open ports needed)
#
#  Supported OS: Ubuntu 22.04/24.04, Debian 11/12, Proxmox
#  Run as:       sudo bash install-chillio-adapter.sh
#
#  How it works:
#    Your Stremio addon runs locally (e.g. http://localhost:7000)
#    Caddy gives it a valid HTTPS certificate via Cloudflare DNS
#    The domain points to your local IP — only reachable on your LAN
#    Chillio app connects to https://your.domain.com from your home network
#
#  Requirements:
#    - A domain managed on Cloudflare
#    - Cloudflare API Token: dash.cloudflare.com/profile/api-tokens
#      Permission: Zone → DNS → Edit (for your domain only)
#    - DNS A-record pointing to your local server IP (Proxy: OFF)
# ============================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()    { echo -e "${CYAN}  ›${NC} $1"; }
success() { echo -e "${GREEN}  ✓${NC} $1"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $1"; }
error()   { echo -e "${RED}  ✗${NC} $1"; exit 1; }
step()    { echo -e "\n${BOLD}── $1 ${DIM}────────────────────────────────────────${NC}"; }

# ── Banner ───────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
   ___ _    _ _ _ _
  / __| |_ (_) | (_)___
 | (__| ' \| | | | / _ \
  \___|_||_|_|_|_|_\___/
   _       _
  /_\   __| |__ _ _ __  ___ _ _
 / _ \ / _` / _` | '_ \/ -_) '_|
/_/ \_\\__,_\__,_| .__/\___|_|
                 |_|
BANNER
echo -e "${NC}"
echo -e "  ${DIM}Stremio addon → ChillLink Protocol · Local HTTPS via Caddy${NC}"
echo -e "  ${DIM}https://link.chillio.app/documentation${NC}"
echo ""

# ── Root check ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Please run as root: sudo bash $0"

# ── OS check ─────────────────────────────────────────────────
if grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
    OS=$(grep ^ID= /etc/os-release | cut -d= -f2 | tr -d '"')
    success "Detected OS: ${OS}"
else
    warn "This script is tested on Ubuntu/Debian. Your OS may work but is unsupported."
    read -rp "  Continue anyway? [y/N]: " _c
    [[ "$_c" != "y" && "$_c" != "Y" ]] && exit 0
fi

# ── Configuration ────────────────────────────────────────────
step "Configuration"
echo ""
echo -e "  ${DIM}You need a domain pointing to this server's local IP.${NC}"
echo -e "  ${DIM}Example: chillio.yourdomain.com → 192.168.1.100 (Proxy: OFF in Cloudflare)${NC}"
echo ""

read -rp "  Your domain (e.g. chillio.yourdomain.com): " DOMAIN
[[ -z "$DOMAIN" ]] && error "Domain is required."

echo ""
echo -e "  ${DIM}The URL of your Stremio addon manifest.${NC}"
echo -e "  ${DIM}Examples:${NC}"
echo -e "  ${DIM}  http://localhost:7000/manifest.json${NC}"
echo -e "  ${DIM}  http://localhost:7000/mytoken/manifest.json${NC}"
echo ""
read -rp "  Stremio addon manifest URL: " MANIFEST_URL
[[ -z "$MANIFEST_URL" ]] && error "Manifest URL is required."

# Extract base URL and token from manifest URL
# e.g. http://localhost:7000/token/manifest.json → base=http://localhost:7000, path=/token
ADDON_BASE=$(echo "$MANIFEST_URL" | sed 's|/manifest\.json.*||' | sed 's|/[^/]*$||g')
# If manifest is directly at /manifest.json, base is just the host:port
if echo "$MANIFEST_URL" | grep -qE '^https?://[^/]+/manifest\.json$'; then
    ADDON_BASE=$(echo "$MANIFEST_URL" | sed 's|/manifest\.json||')
fi
ADDON_PATH=$(echo "$MANIFEST_URL" | sed "s|${ADDON_BASE}||" | sed 's|/manifest\.json||')

echo ""
read -rp "  Port for Chillio Adapter [3500]: " ADAPTER_PORT
ADAPTER_PORT="${ADAPTER_PORT:-3500}"

echo ""
read -rp "  Email for Let's Encrypt: " LE_EMAIL
[[ -z "$LE_EMAIL" ]] && error "Email is required."

echo ""
echo -e "  ${DIM}Create a token at: https://dash.cloudflare.com/profile/api-tokens${NC}"
echo -e "  ${DIM}Required permission: Zone → DNS → Edit (for your domain only)${NC}"
echo ""
read -rsp "  Cloudflare API Token: " CF_TOKEN
echo ""
[[ -z "$CF_TOKEN" ]] && error "Cloudflare API Token is required."

# ── Summary ──────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Summary:${NC}"
echo -e "  Chillio URL:    ${CYAN}https://${DOMAIN}${NC}"
echo -e "  Adapter Port:   ${ADAPTER_PORT}"
echo -e "  Upstream addon: ${ADDON_BASE}${ADDON_PATH}"
echo -e "  Email:          ${LE_EMAIL}"
echo -e "  CF Token:       ${DIM}${CF_TOKEN:0:8}...${NC}"
echo ""
echo -e "  ${YELLOW}Make sure this DNS A-record exists in Cloudflare (Proxy: OFF):${NC}"
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo -e "  ${CYAN}${DOMAIN}${NC}  →  ${LOCAL_IP}"
echo ""
read -rp "  Ready to install? [y/N]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && echo "Aborted." && exit 0

# ── Dependencies ─────────────────────────────────────────────
step "Dependencies"
apt-get update -qq
apt-get install -y -qq curl wget ca-certificates gnupg

if ! command -v node &>/dev/null || [[ "$(node --version 2>/dev/null)" != v2* ]]; then
    info "Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
    apt-get install -y -qq nodejs
fi
success "Node.js $(node --version) ready."

# ── Chillio Adapter ──────────────────────────────────────────
step "Chillio Adapter"

INSTALL_DIR="/opt/chillio-adapter"
mkdir -p "$INSTALL_DIR"

info "Writing adapter..."

cat > "$INSTALL_DIR/server.js" << JSEOF
'use strict';
const http  = require('http');
const https = require('https');

const ADDON_BASE  = process.env.ADDON_BASE  || 'http://localhost:7000';
const ADDON_PATH  = process.env.ADDON_PATH  || '';
const PORT        = parseInt(process.env.PORT) || 3500;

function fetchJSON(url, ms) {
  ms = ms || 12000;
  return new Promise(function(resolve, reject) {
    var lib = url.startsWith('https') ? https : http;
    var req = lib.get(url, { timeout: ms }, function(res) {
      if (res.statusCode !== 200) return reject(new Error('HTTP ' + res.statusCode + ' from ' + url));
      var raw = '';
      res.setEncoding('utf8');
      res.on('data', function(c) { raw += c; });
      res.on('end', function() {
        try { resolve(JSON.parse(raw)); }
        catch(e) { reject(new Error('Invalid JSON from ' + url)); }
      });
    });
    req.on('error', reject);
    req.on('timeout', function() { req.destroy(); reject(new Error('Timeout: ' + url)); });
  });
}

// CORS is handled by Caddy - do not set here to avoid duplicate headers
function sendJSON(res, status, obj) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj));
}

async function handleManifest(res) {
  var name = 'My Addon', version = '1.0.0', description = 'Stremio addon via Chillio Adapter';
  try {
    var up = await fetchJSON(ADDON_BASE + ADDON_PATH + '/manifest.json');
    name        = up.name        || name;
    version     = up.version     || version;
    description = up.description || description;
  } catch(e) {
    console.warn('[manifest] Upstream unreachable:', e.message);
  }
  sendJSON(res, 200, {
    id:          'com.chillio.adapter',
    version:     version,
    name:        name,
    description: description,
    supported_endpoints: { feeds: null, streams: '/streams' }
  });
}

async function handleStreams(query, res) {
  var tmdbID = query.tmdbID, imdbID = query.imdbID, type = query.type;
  var season = query.season, episode = query.episode;

  if (!type || (!tmdbID && !imdbID)) {
    return sendJSON(res, 400, { sources: [], error: 'Missing required params: type + tmdbID or imdbID' });
  }

  var sType = type === 'series' ? 'series' : 'movie';
  var sID   = imdbID || ('tmdb:' + tmdbID);
  if (sType === 'series' && season && episode) sID = sID + ':' + season + ':' + episode;

  var url = ADDON_BASE + ADDON_PATH + '/stream/' + sType + '/' + encodeURIComponent(sID) + '.json';
  console.log('[streams] ->', url);

  try {
    var data    = await fetchJSON(url);
    var streams = data.streams || [];
    var sources = streams.map(function(s, i) {
      var u = s.url || (s.infoHash ? 'magnet:?xt=urn:btih:' + s.infoHash : null);
      if (!u) return null;
      var meta = [s.name, s.description].filter(Boolean);
      return {
        id:       s.infoHash || (sID + '_' + i),
        title:    s.title || s.name || ('Stream ' + (i + 1)),
        url:      u,
        metadata: meta
      };
    }).filter(Boolean);
    console.log('[streams]', sources.length, 'sources found');
    sendJSON(res, 200, { sources: sources });
  } catch(e) {
    console.error('[streams] Error:', e.message);
    sendJSON(res, 502, { sources: [], error: e.message });
  }
}

function parseQuery(s) {
  var p = {};
  if (s) new URLSearchParams(s).forEach(function(v, k) { p[k] = v; });
  return p;
}

var server = http.createServer(async function(req, res) {
  var method = req.method === 'HEAD' ? 'GET' : req.method.toUpperCase();
  var parts  = req.url.split('?');
  var p      = parts[0];
  var query  = parseQuery(parts[1]);
  console.log(req.method, p);

  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }

  try {
    if (method === 'GET' && (p === '/manifest' || p === '/')) return handleManifest(res);
    if (method === 'GET' && p === '/streams')                  return handleStreams(query, res);
    if (method === 'GET' && p === '/health')
      return sendJSON(res, 200, { status: 'ok', upstream: ADDON_BASE + ADDON_PATH });
    res.writeHead(404); res.end('Not found');
  } catch(e) {
    console.error('Unhandled:', e.message);
    sendJSON(res, 500, { error: 'Internal server error' });
  }
});

server.listen(PORT, function() {
  console.log('Chillio Adapter running on :' + PORT);
  console.log('Upstream: ' + ADDON_BASE + ADDON_PATH);
});
JSEOF

cat > /etc/systemd/system/chillio-adapter.service << EOF
[Unit]
Description=Chillio Adapter - Stremio to ChillLink Protocol
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
Environment=PORT=${ADAPTER_PORT}
Environment=ADDON_BASE=${ADDON_BASE}
Environment=ADDON_PATH=${ADDON_PATH}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now chillio-adapter
sleep 2

if systemctl is-active --quiet chillio-adapter; then
    success "Chillio Adapter running on port ${ADAPTER_PORT}."
else
    error "Chillio Adapter failed to start. Check: journalctl -u chillio-adapter -n 20"
fi

# ── Caddy ────────────────────────────────────────────────────
step "Caddy with Cloudflare SSL"

info "Downloading Caddy with Cloudflare DNS plugin..."
curl -fsSL \
    "https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com/caddy-dns/cloudflare" \
    -o /usr/local/bin/caddy
chmod +x /usr/local/bin/caddy

if /usr/local/bin/caddy list-modules 2>/dev/null | grep -q "dns.providers.cloudflare"; then
    success "Caddy $(/usr/local/bin/caddy version | head -1) with Cloudflare plugin."
else
    error "Cloudflare plugin missing. Please re-run the script."
fi

id -u caddy &>/dev/null || useradd --system --home /var/lib/caddy --shell /bin/false caddy
mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
chown -R caddy:caddy /var/lib/caddy /var/log/caddy

cat > /etc/caddy/Caddyfile << EOF
{
    email ${LE_EMAIL}
}

${DOMAIN} {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    header {
        Access-Control-Allow-Origin  *
        Access-Control-Allow-Methods "GET, OPTIONS"
        Access-Control-Allow-Headers *
    }
    reverse_proxy localhost:${ADAPTER_PORT}
}
EOF

# Caddy systemd service
if [[ ! -f /etc/systemd/system/caddy.service ]]; then
cat > /etc/systemd/system/caddy.service << 'EOF'
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
fi

# Store CF token securely
mkdir -p /etc/systemd/system/caddy.service.d
cat > /etc/systemd/system/caddy.service.d/cloudflare.conf << EOF
[Service]
Environment=CF_API_TOKEN=${CF_TOKEN}
EOF
chmod 600 /etc/systemd/system/caddy.service.d/cloudflare.conf

systemctl daemon-reload
systemctl enable --now caddy
sleep 4

if systemctl is-active --quiet caddy; then
    success "Caddy running — SSL certificate is being issued..."
else
    error "Caddy failed to start. Check: journalctl -u caddy -n 30"
fi

# ── Verify ───────────────────────────────────────────────────
step "Verification"
info "Waiting 20 seconds for SSL certificate..."
sleep 20

check() {
    local URL=$1 LABEL=$2
    local CODE
    CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$URL" 2>/dev/null || echo "000")
    if [[ "$CODE" =~ ^[23] ]]; then success "${LABEL}: HTTP ${CODE} ✓"
    else warn "${LABEL}: HTTP ${CODE} — certificate may still be issuing, wait ~60s and retry"; fi
}

check "http://localhost:${ADAPTER_PORT}/manifest" "Adapter (local)"
check "https://${DOMAIN}/manifest"                "Adapter (HTTPS)"

# ── Done ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║  Installation complete!                           ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${BOLD}Add this URL to the Chillio app:${NC}"
echo -e "  ${CYAN}https://${DOMAIN}${NC}"
echo ""
echo -e "  ${BOLD}How it works:${NC}"
echo -e "  ${DIM}• Your Stremio addon stays local and private${NC}"
echo -e "  ${DIM}• Caddy gives it a valid HTTPS certificate${NC}"
echo -e "  ${DIM}• Only devices on your home network can reach it${NC}"
echo -e "  ${DIM}• No ports open to the internet${NC}"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "  ${DIM}journalctl -u chillio-adapter -f   # adapter logs${NC}"
echo -e "  ${DIM}journalctl -u caddy -f             # caddy logs${NC}"
echo -e "  ${DIM}systemctl restart chillio-adapter  # restart adapter${NC}"
echo ""
