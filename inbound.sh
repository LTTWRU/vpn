#!/usr/bin/env bash
# Creates VLESS+Reality inbound in 3x-ui via API (3x-ui v3)
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

# ── Step 1: Get CSRF token ────────────────────────────────────────────
echo "[+] Fetching CSRF token..."
HTML=$(curl -s --max-time 10 -c "$COOKIE" "${XUI}/")
CSRF=$(python3 -c "
import sys, re
m = re.search(r'csrf-token.*?content=\\"([^\\"]+)', sys.stdin.read())
print(m.group(1) if m else '')
" <<< "$HTML" 2>/dev/null || true)
echo "[+] CSRF: ${CSRF:0:24}..."

# ── Step 2: Login ─────────────────────────────────────────────────────
login_ok=0
ACTUAL_PASS=""
for PASS in "${XUI_PASSWORD:-}" "admin"; do
    [[ -z "$PASS" ]] && continue
    RESP=$(curl -s --max-time 10 \
        -c "$COOKIE" -b "$COOKIE" \
        -X POST "${XUI}/login" \
        -H "X-CSRF-Token: ${CSRF}" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${XUI_USERNAME:-admin}\",\"password\":\"${PASS}\"}" 2>&1)
    if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('success') else 1)" 2>/dev/null; then
        echo "[+] Logged in (password: ${PASS})"
        ACTUAL_PASS="$PASS"
        login_ok=1
        # Sync .env password
        sed -i "s/^XUI_PASSWORD=.*/XUI_PASSWORD=${PASS}/" .env
        break
    fi
done

[[ $login_ok -eq 0 ]] && { echo "ERROR: Login failed"; exit 1; }

# ── Step 3: Generate X25519 keys ─────────────────────────────────────
echo "[+] Generating X25519 key pair..."
KEYS=$(docker exec 3xui xray x25519 2>/dev/null)
PRIV=$(awk '/Private/{print $NF}' <<< "$KEYS")
PUB=$(awk  '/Public/{print $NF}'  <<< "$KEYS")
SHORTID=$(openssl rand -hex 4)

echo "    Private key : $PRIV"
echo "    Public key  : $PUB"
echo "    Short ID    : $SHORTID"

# ── Step 4: Build inbound JSON payload ───────────────────────────────
python3 << PYEOF > "$JSON"
import json

stream = {
    'network': 'tcp', 'security': 'reality',
    'realitySettings': {
        'show': False, 'xver': 0,
        'dest': 'www.apple.com:443',
        'serverNames': ['www.apple.com'],
        'privateKey': '$PRIV',
        'minClient': '', 'maxTimeDiff': 0,
        'shortIds': ['$SHORTID'],
        'fingerprint': 'chrome', 'headers': {}
    },
    'tcpSettings': {'acceptProxyProtocol': False, 'header': {'type': 'none'}}
}

payload = {
    'remark': 'VLESS-Reality',
    'enable': True, 'listen': '', 'port': 443,
    'protocol': 'vless', 'expiryTime': 0,
    'settings':       json.dumps({'clients':[],'decryption':'none','fallbacks':[]}),
    'streamSettings': json.dumps(stream),
    'sniffing':       json.dumps({'enabled':True,
                                  'destOverride':['http','tls','quic','fakedns'],
                                  'metadataOnly':False,'routeOnly':False}),
    'tag': 'inbound-443'
}
print(json.dumps(payload))
PYEOF

# ── Step 5: Create inbound via API ───────────────────────────────────
echo "[+] Creating inbound via 3x-ui API..."
ADD=$(curl -s --max-time 15 \
    -b "$COOKIE" \
    -X POST "${XUI}/xui/API/inbounds/add" \
    -H "Content-Type: application/json" \
    -H "X-CSRF-Token: ${CSRF}" \
    -d @"$JSON")

echo "    API response: $(echo $ADD | head -c 120)"

if echo "$ADD" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('success') else 1)" 2>/dev/null; then
    IID=$(python3 -c "import sys,json; print(json.load(sys.stdin)['obj']['id'])" <<< "$ADD" 2>/dev/null || echo "1")
    sed -i "s/^INBOUND_ID=.*/INBOUND_ID=${IID}/" .env
    echo "[+] Inbound created via API (id=${IID})"
else
    echo "WARN: API creation failed, writing directly to SQLite..."
    python3 << PYEOF2
import sqlite3, json

stream = {
    'network':'tcp','security':'reality',
    'realitySettings':{
        'show':False,'xver':0,'dest':'www.apple.com:443',
        'serverNames':['www.apple.com'],'privateKey':'$PRIV',
        'minClient':'','maxTimeDiff':0,'shortIds':['$SHORTID'],
        'fingerprint':'chrome','headers':{}
    },
    'tcpSettings':{'acceptProxyProtocol':False,'header':{'type':'none'}}
}
row = {
    'user_id':1,'up':0,'down':0,'total':0,
    'remark':'VLESS-Reality','enable':1,'expiry_time':0,
    'listen':'','port':443,'protocol':'vless',
    'settings':    json.dumps({'clients':[],'decryption':'none','fallbacks':[]}),
    'stream_settings': json.dumps(stream),
    'tag':'inbound-443',
    'sniffing':    json.dumps({'enabled':True,'destOverride':['http','tls','quic','fakedns'],'metadataOnly':False,'routeOnly':False}),
    'allocate':    json.dumps({'strategy':'always','refresh':5,'concurrency':3})
}
db = sqlite3.connect('/opt/vpn/3xui/db/x-ui.db')
try:
    db.execute('''INSERT INTO inbounds(user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing,allocate) VALUES(:user_id,:up,:down,:total,:remark,:enable,:expiry_time,:listen,:port,:protocol,:settings,:stream_settings,:tag,:sniffing,:allocate)''', row)
    db.commit()
    print('[+] Inbound written to SQLite directly')
except Exception as e:
    print(f'SQLite error: {e}')
finally:
    db.close()
PYEOF2
    docker restart 3xui > /dev/null 2>&1 && echo "[+] 3x-ui restarted"
fi

# Save keys to .env
grep -q REALITY_PUBLIC_KEY .env 2>/dev/null || echo "REALITY_PUBLIC_KEY=${PUB}" >> .env
grep -q REALITY_SHORT_ID   .env 2>/dev/null || echo "REALITY_SHORT_ID=${SHORTID}"   >> .env

echo ""
echo "================================================"
echo "  VLESS Reality Inbound — READY"
echo "  Port       : 443"
echo "  Dest       : www.apple.com:443"
echo "  Public key : ${PUB}"
echo "  Short ID   : ${SHORTID}"
echo "================================================"
echo ""
echo "Panel  : https://panel.pravoslavny-obereg.ru"
echo "Login  : admin / ${ACTUAL_PASS}"
echo ""
echo "Add user: bash /opt/vpn/scripts/add-user.sh email@example.com"
echo ""
