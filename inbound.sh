#!/usr/bin/env bash
# Creates VLESS+Reality inbound in 3x-ui via local API
set -uo pipefail

cd /opt/vpn
source .env

XUI="http://127.0.0.1:2053"
COOKIE=$(mktemp)
JSON=$(mktemp)
trap "rm -f $COOKIE $JSON /tmp/reality_keys.env" EXIT

echo ""
echo "=== Creating VLESS Reality inbound ==="
echo ""

# Try login with configured password, fallback to admin/admin
login_ok=0
for PASS in "${XUI_PASSWORD}" "admin"; do
    RESP=$(curl -s --max-time 10 -c "$COOKIE" -X POST "$XUI/login" \
        -d "username=${XUI_USERNAME:-admin}&password=${PASS}" 2>&1)
    if echo "$RESP" | grep -q '"success":true'; then
        echo "[+] Logged in (password: ${PASS})"
        login_ok=1
        break
    fi
done

if [[ $login_ok -eq 0 ]]; then
    echo "ERROR: Login failed. Response: $RESP"
    echo "Check credentials in /opt/vpn/.env"
    exit 1
fi

# Generate X25519 keys + payload via Python
echo "[+] Generating X25519 keys..."
python3 << 'PYEOF' > "$JSON"
import json, subprocess, secrets, sys

r = subprocess.run(['docker', 'exec', '3xui', 'xray', 'x25519'],
                   capture_output=True, text=True)
priv = pub = ''
for line in r.stdout.strip().splitlines():
    if 'Private' in line: priv = line.split()[-1]
    if 'Public'  in line: pub  = line.split()[-1]

if not priv:
    print('ERROR: xray x25519 failed:', r.stderr, file=sys.stderr)
    sys.exit(1)

shortid = secrets.token_hex(4)

print(f'    Private key : {priv}', file=sys.stderr)
print(f'    Public key  : {pub}',  file=sys.stderr)
print(f'    Short ID    : {shortid}', file=sys.stderr)

with open('/tmp/reality_keys.env', 'w') as f:
    f.write(f'REALITY_PUBLIC_KEY={pub}\nREALITY_SHORT_ID={shortid}\n')

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
    'sniffing':       json.dumps({'enabled': True,
                                  'destOverride': ['http','tls','quic','fakedns'],
                                  'metadataOnly': False, 'routeOnly': False}),
    'tag': 'inbound-443'
}
print(json.dumps(payload))
PYEOF

echo "[+] Sending to 3x-ui API..."
ADD=$(curl -s --max-time 10 -b "$COOKIE" -X POST "$XUI/xui/API/inbounds/add" \
    -H 'Content-Type: application/json' \
    -d @"$JSON")

echo "Response: $ADD"

if echo "$ADD" | grep -q '"success":true'; then
    INBOUND_ID=$(python3 -c "import sys,json; print(json.load(sys.stdin)['obj']['id'])" <<< "$ADD" 2>/dev/null || echo "1")
    sed -i "s/^INBOUND_ID=.*/INBOUND_ID=${INBOUND_ID}/" .env
    grep -q REALITY_PUBLIC_KEY .env 2>/dev/null || cat /tmp/reality_keys.env >> .env
    echo "[+] Inbound created (id=${INBOUND_ID})"
else
    echo "WARN: Could not create inbound automatically."
    echo "      Create it manually in the panel (see keys above)."
fi

source /tmp/reality_keys.env 2>/dev/null || true
echo ""
echo "================================================"
echo "  VLESS Reality Inbound"
echo "  Port       : 443"
echo "  Dest       : www.apple.com:443"
echo "  Public key : ${REALITY_PUBLIC_KEY:-see above}"
echo "  Short ID   : ${REALITY_SHORT_ID:-see above}"
echo "================================================"
echo ""
echo "Add a user:  bash /opt/vpn/scripts/add-user.sh email@example.com"
echo ""
