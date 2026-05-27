#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"
source .env

EMAIL="${1:-}"
[[ -z "$EMAIL" ]] && { echo "Usage: bash scripts/add-user.sh <email>"; exit 1; }

XUI_HOST="http://127.0.0.1:2053"
SUB_HOST="http://127.0.0.1:8000"

UUID=$(cat /proc/sys/kernel/random/uuid)
COOKIE=$(mktemp)
cleanup() { rm -f "$COOKIE"; }
trap cleanup EXIT

# ── Login to 3x-ui ────────────────────────────────────────────────────────────
LOGIN=$(curl -sf -c "$COOKIE" -X POST "$XUI_HOST/login" \
    -d "username=${XUI_USERNAME}&password=${XUI_PASSWORD}")
echo "$LOGIN" | grep -q '"success":true' || { echo "ERROR: 3x-ui login failed. Check XUI_USERNAME / XUI_PASSWORD in .env"; exit 1; }

# ── Add client (limitIp=1 enforces single-device) ─────────────────────────────
CLIENT_PAYLOAD=$(printf \
    '{"id":%d,"settings":"{\\"clients\\":[{\\"id\\":\\"%s\\",\\"email\\":\\"%s\\",\\"limitIp\\":1,\\"totalGB\\":0,\\"expiryTime\\":0,\\"enable\\":true,\\"tgId\\":\\"\\",\\"subId\\":\\"\\",\\"flow\\":\\"xtls-rprx-vision\\"}]}"}' \
    "$INBOUND_ID" "$UUID" "$EMAIL")

ADD=$(curl -sf -b "$COOKIE" -X POST "$XUI_HOST/xui/API/inbounds/addClient" \
    -H "Content-Type: application/json" \
    -d "$CLIENT_PAYLOAD")
echo "$ADD" | grep -q '"success":true' || echo "WARN: 3x-ui add-client response: $ADD"

# ── Register subscription token ───────────────────────────────────────────────
SUB_RESP=$(curl -sf -X POST "$SUB_HOST/admin/users" \
    -H "Content-Type: application/json" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}" \
    -d "{\"email\":\"${EMAIL}\"}")

TOKEN=$(python3 -c "import sys,json; print(json.loads(sys.stdin.read())['token'])" <<< "$SUB_RESP" 2>/dev/null || echo "")
[[ -z "$TOKEN" ]] && { echo "ERROR: Could not create subscription token. Response: $SUB_RESP"; exit 1; }

echo ""
echo "========================================"
echo "  User added successfully"
echo "  Email          : ${EMAIL}"
echo "  UUID           : ${UUID}"
echo "  Subscription   : http://${SERVER_DOMAIN}/sub/${TOKEN}"
echo "========================================"
echo ""
echo "Send the Subscription URL to the user."
echo "Supported clients: v2rayN, Sing-box, NekoBox, Hiddify, Streisand"
