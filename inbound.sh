#!/usr/bin/env bash
# Creates VLESS+Reality inbound in 3x-ui via local API
set -euo pipefail

cd /opt/vpn
source .env

XUI="http://127.0.0.1:2053"
COOKIE=$(mktemp)
JSON=$(mktemp)
trap "rm -f $COOKIE $JSON" EXIT

echo ""
echo "=== Creating VLESS Reality inbound ==="

# Login
LOGIN=$(curl -sf -c "$COOKIE" -X POST "$XUI/login" \
    -d "username=${XUI_USERNAME}&password=${XUI_PASSWORD}")
echo "$LOGIN" | grep -q '"success":true' || { echo "ERROR: Login failed"; exit 1; }
echo "[+] Logged in"

# Build full payload in one Python script
python3 << 'PYEOF' > "$JSON"
import json, subprocess, secrets, sys

# Generate X25519 keys via xray
r = subprocess.run(['docker', 'exec', '3xui', 'xray', 'x25519'],
                   capture_output=True, text=True)
priv = pub = ''
for line in r.stdout.strip().splitlines():
    if 'Private' in line: priv = line.split()[-1]
    if 'Public'  in line: pub  = line.split()[-1]

if not priv or not pub:
    print('ERROR: could not generate X25519 keys', file=sys.stderr)
    sys.exit(1)

shortid = secrets.token_hex(4)

# Print keys to stderr so they appear in terminal
print(f'    Private key : {priv}', file=sys.stderr)
print(f'    Public key  : {pub}',  file=sys.stderr)
print(f'    Short ID    : {shortid}', file=sys.stderr)

stream = {
    'network': 'tcp',
    'security': 'reality',
    'realitySettings': {
        'show': False, 'xver': 0,
        'dest': 'www.apple.com:443',
        'serverNames': ['www.apple.com'],
        'privateKey': priv,
        'minClient': '', 'maxTimeDiff': 0,
        'shortIds': [shortid],
        'fingerprint': 'chrome',
        'headers': {}
    },
    'tcpSettings': {'acceptProxyProtocol': False, 'header': {'type': 'none'}}
}

payload = {
    'remark': 'VLESS-Reality',
    'enable': True,
    'listen': '',
    'port': 443,
    'protocol': 'vless',
    'expiryTime': 0,
    'settings':       json.dumps({'clients': [], 'decryption': 'none', 'fallbacks': []}),
    'streamSettings': json.dumps(stream),
    'sniffing':       json.dumps({'enabled': True, 'destOverride': ['http','tls','quic','fakedns'],
                                  'metadataOnly': False, 'routeOnly': False}),
    'tag': 'inbound-443'
}

# Write pub/shortid as env vars to a sidecar file
with open('/tmp/reality_keys.env', 'w') as f:
    f.write(f'REALITY_PUBLIC_KEY={pub}\nREALITY_SHORT_ID={shortid}\n')

print(json.dumps(payload))
PYEOF

echo "[+] JSON payload ready"

# Create inbound
RESP=$(curl -sf -b "$COOKIE" -X POST "$XUI/xui/API/inbounds/add" \
    -H 'Content-Type: application/json' \
    -d @"$JSON")

if echo "$RESP" | grep -q '"success":true'; then
    INBOUND_ID=$(python3 -c "import sys,json; print(json.load(sys.stdin)['obj']['id'])" <<< "$RESP" 2>/dev/null || echo "1")
    sed -i "s/^INBOUND_ID=.*/INBOUND_ID=${INBOUND_ID}/" .env
    # Append reality keys to .env if not already there
    grep -q REALITY_PUBLIC_KEY .env 2>/dev/null || cat /tmp/reality_keys.env >> .env
    echo "[+] Inbound created (id=${INBOUND_ID})"
else
    echo "Response: $RESP"
    echo "WARN: inbound may already exist, or check the panel manually."
fi

# Show summary
source /tmp/reality_keys.env 2>/dev/null || true
echo ""
echo "================================================"
echo "  VLESS Reality inbound"
echo "  Port       : 443"
echo "  Dest       : www.apple.com:443"
echo "  Public key : ${REALITY_PUBLIC_KEY:-see above}"
echo "  Short ID   : ${REALITY_SHORT_ID:-see above}"
echo "================================================"
echo ""
echo "Add first user:"
echo "  bash /opt/vpn/scripts/add-user.sh user@email.com"
echo ""
