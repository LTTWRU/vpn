#!/usr/bin/env bash
# Pull latest code and rebuild subscription container.
# Run on server: bash /opt/vpn/scripts/update-server.sh
set -euo pipefail

cd /opt/vpn

echo "[+] Pulling latest code..."
git pull origin claude/vpn-3xui-subscriptions-TdUoz

echo "[+] Rebuilding subscription service..."
docker compose up -d --build subscription

echo "[+] Done"
docker compose ps
