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
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

[[ $EUID -ne 0 ]] && err "Run as root"

step "Checking DNS"
check_dns() {
    local domain="$1"
    local resolved
    resolved=$(dig +short "$domain" A 2>/dev/null | tail -1)
    if [[ "$resolved" == "$SERVER_IP" ]]; then
        info "$domain → $SERVER_IP ✓"
    else
        warn "$domain resolves to '$resolved', expected $SERVER_IP"
        warn "Add DNS A-record: $domain → $SERVER_IP"
    fi
}
check_dns "$PANEL_DOMAIN"
check_dns "$SUB_DOMAIN"

step "Installing packages"
apt-get update -qq
apt-get install -y --quiet git curl openssl python3 dnsutils ufw nginx libnginx-mod-stream certbot
info "Packages installed"

step "Docker"
if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker && systemctl start docker
else
    info "Docker already installed: $(docker --version)"
fi
! docker compose version &>/dev/null 2>&1 && apt-get install -y --quiet docker-compose-plugin
info "Docker Compose: $(docker compose version)"

step "Firewall"
ufw allow 22/tcp  2>/dev/null || true
ufw allow 80/tcp  2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true
ufw --force enable 2>/dev/null || true
info "Firewall: 22, 80, 443 open"

step "Repository"
if [[ -d "$INSTALL_DIR/.git" ]]; then
    git -C "$INSTALL_DIR" fetch origin && git -C "$INSTALL_DIR" checkout "$BRANCH" && git -C "$INSTALL_DIR" pull origin "$BRANCH"
else
    git clone -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"
info "Ready at $INSTALL_DIR"

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
    info "Created .env"
else
    info "Using existing .env"
fi
source .env

step "SSL Certificates"
systemctl stop nginx 2>/dev/null || true
get_cert() {
    local d="$1"
    [[ -d "/etc/letsencrypt/live/${d}" ]] && { info "Cert for $d already exists"; return; }
    info "Getting cert for $d..."
    certbot certonly --standalone -d "$d" --non-interactive --agree-tos --register-unsafely-without-email --key-type ecdsa
    info "Cert for $d done ✓"
}
get_cert "$PANEL_DOMAIN"
get_cert "$SUB_DOMAIN"

step "nginx"
mkdir -p /var/www/certbot
cat > /etc/nginx/nginx.conf << 'NGINX_CONF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 4096; multi_accept on; }

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

    server {
        listen 8444 ssl;
        server_name sub.pravoslavny-obereg.ru;
        ssl_certificate     /etc/letsencrypt/live/sub.pravoslavny-obereg.ru/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/sub.pravoslavny-obereg.ru/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        location /sub/ { limit_req zone=sub_zone burst=5 nodelay; proxy_pass http://127.0.0.1:8001; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
        location = /health { proxy_pass http://127.0.0.1:8001; access_log off; }
        location / { return 404; }
    }

    server {
        listen 8445 ssl;
        server_name panel.pravoslavny-obereg.ru;
        ssl_certificate     /etc/letsencrypt/live/panel.pravoslavny-obereg.ru/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/panel.pravoslavny-obereg.ru/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
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

    server {
        listen 80;
        server_name sub.pravoslavny-obereg.ru panel.pravoslavny-obereg.ru;
        location /.well-known/acme-challenge/ { root /var/www/certbot; }
        location / { return 301 https://$host$request_uri; }
    }
}
NGINX_CONF
nginx -t && systemctl enable nginx && systemctl start nginx
info "nginx started"

step "Starting containers"
docker compose up -d --build
info "Containers starting..."

step "3x-ui setup"
info "Waiting 20s for 3x-ui..."
sleep 20
docker exec 3xui x-ui setting -username admin -password "${XUI_PASSWORD}" 2>/dev/null && info "3x-ui password set" || warn "Set password manually in panel"

step "SSL renewal cron"
cat > /etc/cron.d/certbot-renew-vpn << 'CRON'
0 3 * * * root certbot renew --quiet --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx"
CRON
info "Cron set"

step "Reality Keys (save these!)"
echo ""
docker exec 3xui xray x25519 2>/dev/null || warn "Run: docker exec 3xui xray x25519"
echo ""

cat > /root/vpn-credentials.txt << CREDS
Panel  : https://panel.pravoslavny-obereg.ru
Login  : admin / ${XUI_PASSWORD}
Token  : ${ADMIN_TOKEN}
Dir    : ${INSTALL_DIR}
CREDS
chmod 600 /root/vpn-credentials.txt

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ✓  VPN готов! / VPN Ready!                         ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════════╣${NC}"
printf  "${GREEN}║${NC}  Panel  : ${CYAN}%-53s${GREEN}║${NC}\n" "https://panel.pravoslavny-obereg.ru"
printf  "${GREEN}║${NC}  Login  : ${CYAN}%-53s${GREEN}║${NC}\n" "admin  /  ${XUI_PASSWORD}"
printf  "${GREEN}║${NC}  Subs   : ${CYAN}%-53s${GREEN}║${NC}\n" "https://sub.pravoslavny-obereg.ru/sub/TOKEN"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════════╣${NC}"
printf  "${GREEN}║${NC}  Token  : ${YELLOW}%-53s${GREEN}║${NC}\n" "${ADMIN_TOKEN}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
