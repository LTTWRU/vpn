#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"
source .env

EMAIL="${1:-}"
[[ -z "$EMAIL" ]] && { echo "Usage: bash scripts/add-user.sh <email>"; exit 1; }

XUI_HOST="http://127.0.0.1:2053"
SUB_HOST="http://127.0.0.1:8001"
UUID=$(cat /proc/sys/kernel/random/uuid)
COOKIE=$(mktemp)
trap "rm -f $COOKIE" EXIT

# ── Resolve inbound ID ────────────────────────────────────────────────
if [[ -z "${INBOUND_ID:-}" ]]; then
    INBOUND_ID=$(python3 -c "
import sqlite3
db = sqlite3.connect('/opt/vpn/3xui/db/x-ui.db')
row = db.execute('SELECT id FROM inbounds WHERE port=443').fetchone()
db.close()
print(row[0] if row else '')
")
    [[ -z "$INBOUND_ID" ]] && { echo "ERROR: No inbound found on port 443. Run inbound.sh first."; exit 1; }
    # Persist it for next time
    echo "INBOUND_ID=${INBOUND_ID}" >> .env
fi

# ── Login to 3x-ui (v3 with CSRF) ───────────────────────────────────────
HTML=$(curl -s --max-time 10 -c "$COOKIE" "${XUI_HOST}/")
CSRF=$(grep -o 'csrf-token" content="[^"]*' <<< "$HTML" | sed 's/csrf-token" content="//')

login_ok=0
for PASS in "${XUI_PASSWORD:-}" "admin"; do
    [[ -z "$PASS" ]] && continue
    R=$(curl -s --max-time 10 -c "$COOKIE" -b "$COOKIE" \
        -X POST "${XUI_HOST}/login" \
        -H "X-CSRF-Token: ${CSRF}" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${XUI_USERNAME:-admin}\",\"password\":\"${PASS}\"}" 2>/dev/null)
    echo "$R" | grep -q '"success":true' && { login_ok=1; break; }
done
[[ $login_ok -eq 0 ]] && { echo "ERROR: 3x-ui login failed"; exit 1; }

# ── Add VLESS client ────────────────────────────────────────────────────
CLIENT_JSON=$(python3 -c "
import json
client = {
    'id': '${UUID}',
    'email': '${EMAIL}',
    'limitIp': 1,
    'totalGB': 0,
    'expiryTime': 0,
    'enable': True,
    'tgId': '',
    'subId': '',
    'flow': 'xtls-rprx-vision'
}
payload = {'id': ${INBOUND_ID}, 'settings': json.dumps({'clients': [client]})}
print(json.dumps(payload))
")

ADD=$(curl -s --max-time 10 \
    -b "$COOKIE" \
    -X POST "${XUI_HOST}/xui/API/inbounds/addClient" \
    -H "Content-Type: application/json" \
    -H "X-CSRF-Token: ${CSRF}" \
    -d "$CLIENT_JSON")

if ! echo "$ADD" | grep -q '"success":true'; then
    echo "WARN: 3x-ui addClient response: $ADD"
fi

# ── Register subscription token ──────────────────────────────────────
SUB=$(curl -s --max-time 10 \
    -X POST "${SUB_HOST}/admin/users" \
    -H "Content-Type: application/json" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}" \
    -d "{\"email\":\"${EMAIL}\"}")

TOKEN=$(python3 -c "import sys,json; print(json.loads(sys.stdin.read())['token'])" <<< "$SUB" 2>/dev/null || true)
[[ -z "$TOKEN" ]] && { echo "ERROR: subscription service response: $SUB"; exit 1; }

echo ""
echo "===================================="
echo "  User added"
echo "  Email : ${EMAIL}"
echo "  UUID  : ${UUID}"
echo "  Sub   : https://sub.pravoslavny-obereg.ru/sub/${TOKEN}"
echo "===================================="
echo ""
