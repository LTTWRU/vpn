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
trap "rm -f $COOKIE" EXIT

# Login
HTML=$(curl -s --max-time 10 -c "$COOKIE" "${XUI_HOST}/")
CSRF=$(grep -o 'csrf-token" content="[^"]*' <<< "$HTML" | sed 's/csrf-token" content="//')
for PASS in "${XUI_PASSWORD:-}" "admin"; do
    [[ -z "$PASS" ]] && continue
    R=$(curl -s -c "$COOKIE" -b "$COOKIE" \
        -X POST "${XUI_HOST}/login" \
        -H "X-CSRF-Token: ${CSRF}" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${XUI_USERNAME:-admin}\",\"password\":\"${PASS}\"}" 2>/dev/null)
    echo "$R" | grep -q '"success":true' && break
done

# Get client UUID
IBD=$(curl -s -b "$COOKIE" \
    -H "X-CSRF-Token: ${CSRF}" \
    "${XUI_HOST}/xui/API/inbounds/get/${INBOUND_ID}" 2>/dev/null || echo '{}')

UUID=$(python3 - <<< "$IBD" << 'PYEOF'
import sys, json
try:
    d = json.load(sys.stdin)
    s = json.loads(d.get('obj', {}).get('settings', '{}'))
    for c in s.get('clients', []):
        if c.get('email') == 'EMAIL_PLACEHOLDER':
            print(c['id'])
except: pass
PYEOF
)
UUID=$(python3 -c "
import json, sys
data = json.loads(open('/dev/stdin').read())
obj = data.get('obj', {})
settings = json.loads(obj.get('settings', '{}'))
for c in settings.get('clients', []):
    if c.get('email') == '${EMAIL}':
        print(c['id'])
        break
" <<< "$IBD" 2>/dev/null || true)

if [[ -n "$UUID" ]]; then
    curl -s -b "$COOKIE" \
        -H "X-CSRF-Token: ${CSRF}" \
        -X POST "${XUI_HOST}/xui/API/inbounds/${INBOUND_ID}/delClient/${UUID}" > /dev/null
    echo "[+] Removed from 3x-ui: ${EMAIL}"
else
    echo "WARN: Client not found in 3x-ui"
fi

curl -s -X DELETE "${SUB_HOST}/admin/users/${EMAIL}" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}" > /dev/null
echo "[+] Subscription deactivated: ${EMAIL}"
