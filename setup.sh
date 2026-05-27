#!/usr/bin/env bash
# One-command VPN installer for pravoslavny-obereg.ru
# Usage: bash setup.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()  { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

PANEL_DOMAIN="panel.pravoslavny-obereg.ru"
SUB_DOMAIN="sub.pravoslavny-obereg.ru"
SERVER_IP="85.192.61.179"
INSTALL_DIR="/opt/vpn"
REPO_URL="https://github.com/lttwru/vpn.git"
BRANCH="claude/vpn-3xui-subscriptions-TdUoz"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║       VPN Service Installer — VLESS Reality          ║${NC}"
echo -e "${CYAN}║       panel.pravoslavny-obereg.ru                    ║${NC}"
echo -e "${CYAN}║       sub.pravoslavny-obereg.ru                      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

[[ $EUID -ne 0 ]] && err "Run as root: sudo bash setup.sh"

# ── DNS check ──────────────────────────────────────────────────────────
step "Checking DNS"
check_dns() {
    local domain="$1"
    local resolved
    resolved=$(dig +short "$domain" A 2>/dev/null | tail -1)
    if [[ "$resolved" == "$SERVER_IP" ]]; then
        info "$domain → $SERVER_IP ✓"
    else
        warn "$domain resolves to '$resolved', expected $SERVER_IP"
        warn "Make sure DNS A-record points to this server before getting SSL certs!"
        warn "Continuing anyway (certbot will fail if DNS is wrong)..."
    fi
}
check_dns "$PANEL_DOMAIN"
check_dns "$SUB_DOMAIN"

# ── System packages ────────────────────────────────────────────────────
step "Installing packages"
apt-get update -qq
apt-get install -y --quiet \
    git curl openssl python3 dnsutils ufw \
    nginx libnginx-mod-stream \
    certbot
info "Packages installed"

# ── Docker ─────────────────────────────────────────────────────────────
step "Docker"
if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
else
    info "Docker already installed: $(docker --version)"
fi

if ! docker compose version &>/dev/null 2>&1; then
    apt-get install -y --quiet docker-compose-plugin
fi
info "Docker Compose: $(docker compose version)"

# ── Firewall ───────────────────────────────────────────────────────────
step "Firewall"
ufw allow 22/tcp   comment 'SSH'   2>/dev/null || true
ufw allow 80/tcp   comment 'HTTP'  2>/dev/null || true
ufw allow 443/tcp  comment 'HTTPS+VLESS' 2>/dev/null || true
ufw --force enable 2>/dev/null || true
info "Firewall configured (22, 80, 443)"

# ── Clone / update repo ────────────────────────────────────────────────
step "Repository"
if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating repository..."
    git -C "$INSTALL_DIR" fetch origin
    git -C "$INSTALL_DIR" checkout "$BRANCH"
    git -C "$INSTALL_DIR" pull origin "$BRANCH"
else
    info "Cloning repository..."
    git clone -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"
info "Repository ready at $INSTALL_DIR"

# ── .env setup ─────────────────────────────────────────────────────────
step "Configuration"
mkdir -p 3xui/db 3xui/cert subscription/data

if [[ ! -f .env ]]; then
    XUI_PASSWORD=$(openssl rand -hex 12)
    ADMIN_TOKEN=$(openssl rand -hex 32)
    cat > .env << EOF
XUI_USERNAME=admin
XUI_PASSWORD=${XUI_PASSWORD}
XUI_URL=http://3xui:2053
SERVER_DOMAIN=${SUB_DOMAIN}
ADMIN_TOKEN=${ADMIN_TOKEN}
INBOUND_ID=1
EOF
    info "Created .env with random credentials"
else
    info "Using existing .env"
fi
source .env

# ── SSL certificates ───────────────────────────────────────────────────
step "SSL Certificates (Let's Encrypt)"
systemctl stop nginx 2>/dev/null || true

get_cert() {
    local domain="$1"
    if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
        info "Certificate for $domain already exists"
        return
    fi
    info "Requesting certificate for $domain..."
    certbot certonly --standalone \
        -d "$domain" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --key-type ecdsa
    info "Certificate for $domain obtained ✓"
}

get_cert "$PANEL_DOMAIN"
get_cert "$SUB_DOMAIN"

# ── nginx config ───────────────────────────────────────────────────────
step "Configuring nginx"

mkdir -p /var/www/certbot

cat > /etc/nginx/nginx.conf << 'NGINX_CONF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
    multi_accept on;
}

# Port 443: route by SNI — sub/panel go to nginx HTTP, everything else → VLESS Reality
stream {
    map $ssl_preread_server_name $backend_443 {
        sub.pravoslavny-obereg.ru   127.0.0.1:8444;
        panel.pravoslavny-obereg.ru 127.0.0.1:8445;
        default                     127.0.0.1:10443;
    }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass $backend_443;
        proxy_connect_timeout 10s;
        proxy_timeout 120s;
    }
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;
    limit_req_zone $binary_remote_addr zone=sub_zone:10m rate=10r/m;

    # Subscription service — HTTPS on internal port 8444
    server {
        listen 8444 ssl;
        server_name sub.pravoslavny-obereg.ru;
        ssl_certificate     /etc/letsencrypt/live/sub.pravoslavny-obereg.ru/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/sub.pravoslavny-obereg.ru/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;

        location /sub/ {
            limit_req zone=sub_zone burst=5 nodelay;
            proxy_pass http://127.0.0.1:8001;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
        location = /health { proxy_pass http://127.0.0.1:8001; access_log off; }
        location / { return 404; }
    }

    # 3x-ui panel — HTTPS on internal port 8445
    server {
        listen 8445 ssl;
        server_name panel.pravoslavny-obereg.ru;
        ssl_certificate     /etc/letsencrypt/live/panel.pravoslavny-obereg.ru/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/panel.pravoslavny-obereg.ru/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;

        location / {
            proxy_pass http://127.0.0.1:2053;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_read_timeout 300s;
        }
    }

    # HTTP: certbot auto-renewal + redirect to HTTPS
    server {
        listen 80;
        server_name sub.pravoslavny-obereg.ru panel.pravoslavny-obereg.ru;
        location /.well-known/acme-challenge/ { root /var/www/certbot; }
        location / { return 301 https://$host$request_uri; }
    }
}
NGINX_CONF

nginx -t
systemctl enable nginx
systemctl start nginx
info "nginx configured and started"

# ── Start Docker services ──────────────────────────────────────────────
step "Starting VPN containers"
docker compose up -d --build
info "Containers starting..."

# ── Set 3x-ui credentials ──────────────────────────────────────────────
step "Configuring 3x-ui"
info "Waiting for 3x-ui to initialize (20s)..."
sleep 20

# Try CLI method first
if docker exec 3xui x-ui setting -username admin -password "${XUI_PASSWORD}" 2>/dev/null; then
    info "3x-ui credentials set via CLI"
else
    # Fallback: try API
    COOKIE_TMP=$(mktemp)
    LOGIN_RESP=$(curl -sf -c "$COOKIE_TMP" -X POST "http://127.0.0.1:2053/login" \
        -d "username=admin&password=admin" 2>/dev/null || echo '{}')
    if echo "$LOGIN_RESP" | grep -q '"success":true'; then
        curl -sf -b "$COOKIE_TMP" -X POST "http://127.0.0.1:2053/xui/API/settings" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"admin\",\"password\":\"${XUI_PASSWORD}\"}" > /dev/null 2>&1 || true
    fi
    rm -f "$COOKIE_TMP"
    warn "Set 3x-ui password manually in the panel if needed"
fi

# ── SSL auto-renewal cron ──────────────────────────────────────────────
step "SSL auto-renewal"
cat > /etc/cron.d/certbot-renew-vpn << 'CRON'
0 3 * * * root certbot renew --quiet --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"
CRON
info "Auto-renewal cron installed"

# ── Generate Reality key hint ──────────────────────────────────────────
step "Reality Keys"
info "Generating X25519 key pair..."
echo ""
docker exec 3xui xray x25519 2>/dev/null || \
    warn "Run manually later: docker exec 3xui xray x25519"
echo ""

# ── Final summary ──────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                  ✓  Installation Complete!                       ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════════╣${NC}"
printf  "${GREEN}║${NC}  Panel URL    : ${CYAN}%-49s${GREEN}║${NC}\n" "https://panel.pravoslavny-obereg.ru"
printf  "${GREEN}║${NC}  Login        : ${CYAN}%-49s${GREEN}║${NC}\n" "admin  /  ${XUI_PASSWORD}"
printf  "${GREEN}║${NC}  Sub base URL : ${CYAN}%-49s${GREEN}║${NC}\n" "https://sub.pravoslavny-obereg.ru/sub/<token>"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════════╣${NC}"
printf  "${GREEN}║${NC}  Admin token  : ${YELLOW}%-49s${GREEN}║${NC}\n" "${ADMIN_TOKEN}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  NEXT STEPS:                                                     ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  1. Copy the X25519 keys shown above                             ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  2. Open panel → Inbounds → Add (VLESS, port 443, Reality)       ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  3. bash /opt/vpn/scripts/add-user.sh email@example.com          ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Save credentials to file for reference
cat > /root/vpn-credentials.txt << CREDS
VPN Service Credentials
=======================
Panel URL  : https://panel.pravoslavny-obereg.ru
Login      : admin
Password   : ${XUI_PASSWORD}
Admin Token: ${ADMIN_TOKEN}
Install Dir: ${INSTALL_DIR}
CREDS
chmod 600 /root/vpn-credentials.txt
info "Credentials saved to /root/vpn-credentials.txt"
