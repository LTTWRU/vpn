#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

info "=== VPN Service Installer ==="

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash scripts/install.sh"

# ── Docker ────────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker && systemctl start docker
fi

if ! docker compose version &>/dev/null 2>&1; then
    info "Installing Docker Compose plugin..."
    apt-get install -y docker-compose-plugin 2>/dev/null || \
        error "Install Docker Compose manually: https://docs.docker.com/compose/install/"
fi

# ── Create directories ────────────────────────────────────────────────────────
mkdir -p 3xui/db 3xui/cert subscription/data

# ── Bootstrap .env ────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
    cp .env.example .env

    XUI_PASS=$(openssl rand -hex 16)
    ADMIN_TOKEN=$(openssl rand -hex 32)
    sed -i "s/change_me_strong_password/$XUI_PASS/" .env
    sed -i "s/REPLACE_WITH_RANDOM_SECRET/$ADMIN_TOKEN/" .env

    echo ""
    warn "------------------------------------------------------------"
    warn "Generated and saved to .env:"
    warn "  3x-ui password : $XUI_PASS"
    warn "  Admin token    : $ADMIN_TOKEN"
    warn "------------------------------------------------------------"
    warn ""
    warn "ACTION REQUIRED: edit .env and set SERVER_DOMAIN to your"
    warn "server IP or domain, then run this script again."
    warn "  nano .env"
    exit 0
fi

# ── Validate .env ─────────────────────────────────────────────────────────────
source .env
if [[ "${SERVER_DOMAIN:-YOUR_SERVER_IP_OR_DOMAIN}" == "YOUR_SERVER_IP_OR_DOMAIN" ]]; then
    error "Set SERVER_DOMAIN in .env first, then re-run."
fi

# ── Start services ────────────────────────────────────────────────────────────
info "Building and starting services..."
docker compose up -d --build

echo ""
info "=== Done ==="
info ""
info "  3x-ui panel   : http://127.0.0.1:2053  (SSH tunnel: ssh -L 2053:127.0.0.1:2053 user@server)"
info "  Subscriptions : http://${SERVER_DOMAIN}/sub/<token>"
info ""
info "Next steps:"
info "  1. bash scripts/generate-keys.sh   — generate Reality keys"
info "  2. Open 3x-ui → create VLESS+Reality inbound on port 443"
info "  3. bash scripts/add-user.sh <email> — add first user"
