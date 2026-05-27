#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"
source .env

EMAIL="${1:-}"
[[ -z "$EMAIL" ]] && { echo "Usage: bash scripts/remove-user.sh <email>"; exit 1; }

XUI_HOST="http://127.0.0.1:2053"
SUB_HOST="http://127.0.0.1:8001"

COOKIE=$(mktemp)
cleanup() { rm -f "$COOKIE"; }
trap cleanup EXIT

curl -sf -c "$COOKIE" -X POST "$XUI_HOST/login" \
    -d "username=${XUI_USERNAME}&password=${XUI_PASSWORD}" > /dev/null

INBOUND_DATA=$(curl -sf -b "$COOKIE" "$XUI_HOST/xui/API/inbounds/get/${INBOUND_ID}" 2>/dev/null || echo '{}')
UUID=$(python3 - <<EOF 2>/dev/null || echo ""
import sys, json
try:
    data = json.loads('''${INBOUND_DATA}''')
    settings = json.loads(data.get('obj', {}).get('settings', '{}'))
    for c in settings.get('clients', []):
        if c.get('email') == '${EMAIL}':
            print(c['id'])
except Exception:
    pass
EOF
)

if [[ -n "$UUID" ]]; then
    curl -sf -b "$COOKIE" -X POST \
        "$XUI_HOST/xui/API/inbounds/${INBOUND_ID}/delClient/${UUID}" > /dev/null
    echo "Removed from 3x-ui: ${EMAIL} (uuid=${UUID})"
else
    echo "WARN: Client not found in 3x-ui"
fi

curl -sf -X DELETE "$SUB_HOST/admin/users/${EMAIL}" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}" > /dev/null

echo "Subscription deactivated: ${EMAIL}"
echo "Done."
