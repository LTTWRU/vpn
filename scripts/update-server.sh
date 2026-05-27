#!/usr/bin/env bash
# Update the server IP/domain used in all subscription links.
# After running, existing clients auto-refresh on their next sync cycle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

NEW_DOMAIN="${1:-}"
if [[ -z "$NEW_DOMAIN" ]]; then
    echo "Usage: bash scripts/update-server.sh <new-ip-or-domain>"
    echo ""
    echo "Example: bash scripts/update-server.sh 1.2.3.4"
    echo "         bash scripts/update-server.sh vpn.example.com"
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
echo "All subscription links now point to the new address."
echo "Users do not need to do anything — clients auto-refresh on next sync."
