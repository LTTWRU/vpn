#!/usr/bin/env bash
# Creates VLESS+Reality inbound in 3x-ui via local API
set -euo pipefail

cd /opt/vpn
source .env

XUI="http://127.0.0.1:2053"
COOKIE=$(mktemp)
trap "rm -f $COOKIE" EXIT

echo ""
echo "=== Creating VLESS Reality inbound ==="
echo ""

# Login
LOGIN=$(curl -sf -c "$COOKIE" -X POST "$XUI/login" \
    -d "username=${XUI_USERNAME}&password=${XUI_PASSWORD}")
echo "$LOGIN" | grep -q '"success":true' || { echo "ERROR: Login failed. Check .env"; exit 1; }
echo "[+] Logged in to 3x-ui"

# Generate X25519 keys
KEYS=$(docker exec 3xui xray x25519 2>/dev/null)
PRIV=$(echo "$KEYS" | grep 'Private' | awk '{print $3}')
PUB=$(echo  "$KEYS" | grep 'Public'  | awk '{print $3}')
echo "[+] X25519 keys generated"
echo "    Private : $PRIV"
echo "    Public  : $PUB"

# Generate short ID (8 hex chars)
SHORTID=$(openssl rand -hex 4)
echo "[+] Short ID: $SHORTID"

# Build inbound JSON
SETTINGS='{"clients":[],"decryption":"none","fallbacks":[]}'

STREAM=$(python3 -c "
import json
d = {
    'network': 'tcp',
    'security': 'reality',
    'realitySettings': {
        'show': False,
        'xver': 0,
        'dest': 'www.apple.com:443',
        'serverNames': ['www.apple.com'],
        'privateKey': '$PRIV',
        'minClient': '',
        'maxTimeDiff': 0,
        'shortIds': ['$SHORTID'],
        'fingerprint': 'chrome',
        'headers': {}
    },
    'tcpSettings': {
        'acceptProxyProtocol': False,
        'header': {'type': 'none'}
    }
}
print(json.dumps(d))
")

SNIFFING='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'

# Create inbound
RESP=$(curl -sf -b "$COOKIE" -X POST "$XUI/xui/API/inbounds/add" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c "
import json
payload = {
    'remark': 'VLESS-Reality',
    'enable': True,
    'listen': '',
    'port': 443,
    'protocol': 'vless',
    'expiryTime': 0,
    'settings': json.dumps({\"clients\":[],\"decryption\":\"none\",\"fallbacks\":[]}),
    'streamSettings': json.dumps(${STREAM}),
    'sniffing': json.dumps({\"enabled\":True,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":False,\"routeOnly\":False}),
    'tag': 'inbound-443'
}
print(json.dumps(payload))
")"
)

if echo "$RESP" | grep -q '"success":true'; then
    INBOUND_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['obj']['id'])" 2>/dev/null || echo "1")
    # Update INBOUND_ID in .env
    sed -i "s/^INBOUND_ID=.*/INBOUND_ID=${INBOUND_ID}/" .env
    echo "[+] Inbound created (id=${INBOUND_ID})"
else
    echo "WARN: Response: $RESP"
    echo "Inbound may already exist or there was an error."
fi

# Save public key for users
echo "REALITY_PUBLIC_KEY=${PUB}" >> .env 2>/dev/null || true
echo "REALITY_SHORT_ID=${SHORTID}" >> .env 2>/dev/null || true

echo ""
echo "============================================"
echo "  VLESS Reality inbound ready"
echo "  Port       : 443"
echo "  SNI dest   : www.apple.com:443"
echo "  Public key : ${PUB}"
echo "  Short ID   : ${SHORTID}"
echo "============================================"
echo ""
echo "Next: bash /opt/vpn/scripts/add-user.sh user@example.com"
echo ""
