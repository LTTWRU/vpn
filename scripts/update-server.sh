#!/usr/bin/env bash
# Update server address in subscription links.
# Users do NOT need to do anything — their clients auto-refresh on next sync.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

NEW_DOMAIN="${1:-}"
if [[ -z "$NEW_DOMAIN" ]]; then
    echo "Usage: bash scripts/update-server.sh <new-ip-or-domain>"
    exit 1
fi

source .env
OLD_DOMAIN="$SERVER_DOMAIN"
sed -i "s|^SERVER_DOMAIN=.*|SERVER_DOMAIN=${NEW_DOMAIN}|" .env
docker compose restart subscription

echo ""
echo "Server address updated:"
echo "  Old : ${OLD_DOMAIN}"
echo "  New : ${NEW_DOMAIN}"
echo ""
echo "All subscriptions now point to the new address."
