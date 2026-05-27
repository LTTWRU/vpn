#!/usr/bin/env bash
# Creates VLESS+Reality inbound in 3x-ui (v3, CSRF-aware)
set -uo pipefail

cd /opt/vpn
source .env

XUI="http://127.0.0.1:2053"
COOKIE=$(mktemp)
JSON=$(mktemp)
PYOUT=$(mktemp)
trap "rm -f $COOKIE $JSON $PYOUT /tmp/reality_keys.env" EXIT

echo ""
echo "=== Creating VLESS Reality inbound ==="
echo ""

# ── CSRF token (use sed, no python in subshell) ─────────────────────────
echo "[+] Fetching CSRF token..."
HTML_FILE=$(mktemp)
curl -s --max-time 10 -c "$COOKIE" "${XUI}/" > "$HTML_FILE"
CSRF=$(grep -o 'csrf-token" content="[^"]*' "$HTML_FILE" | sed 's/csrf-token" content="//' || true)
rm -f "$HTML_FILE"
echo "[+] CSRF: ${CSRF:0:20}..."

# ── Login ──────────────────────────────────────────────────────────────
login_ok=0
ACTUAL_PASS=""
for PASS in "${XUI_PASSWORD:-}" "admin"; do
    [[ -z "$PASS" ]] && continue
    RESP=$(curl -s --max-time 10 \
        -c "$COOKIE" -b "$COOKIE" \
        -X POST "${XUI}/login" \
        -H "X-CSRF-Token: ${CSRF}" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${XUI_USERNAME:-admin}\",\"password\":\"${PASS}\"}") || true
    if echo "$RESP" | grep -q '"success":true'; then
        echo "[+] Logged in (pass: ${PASS})"
        ACTUAL_PASS="$PASS"
        login_ok=1
        sed -i "s/^XUI_PASSWORD=.*/XUI_PASSWORD=${PASS}/" .env
        break
    fi
done
[[ $login_ok -eq 0 ]] && { echo "ERROR: Login failed. Last response: $RESP"; exit 1; }

# ── Generate X25519 keys ───────────────────────────────────────────────
echo "[+] Generating X25519 keys..."
docker exec 3xui xray x25519 > "$PYOUT" 2>&1
PRIV=$(grep 'Private' "$PYOUT" | awk '{print $NF}')
PUB=$(grep  'Public'  "$PYOUT" | awk '{print $NF}')
SHORTID=$(openssl rand -hex 4)
echo "    Private : $PRIV"
echo "    Public  : $PUB"
echo "    ShortID : $SHORTID"

# ── Build JSON payload via python heredoc ───────────────────────────────
python3 - "$PRIV" "$PUB" "$SHORTID" << 'PYEOF' > "$JSON"
import json, sys
priv, pub, shortid = sys.argv[1], sys.argv[2], sys.argv[3]
stream = {
    'network':'tcp','security':'reality',
    'realitySettings':{
        'show':False,'xver':0,'dest':'www.apple.com:443',
        'serverNames':['www.apple.com'],'privateKey':priv,
        'minClient':'','maxTimeDiff':0,'shortIds':[shortid],
        'fingerprint':'chrome','headers':{}
    },
    'tcpSettings':{'acceptProxyProtocol':False,'header':{'type':'none'}}
}
payload = {
    'remark':'VLESS-Reality','enable':True,'listen':'','port':443,
    'protocol':'vless','expiryTime':0,
    'settings':       json.dumps({'clients':[],'decryption':'none','fallbacks':[]}),
    'streamSettings': json.dumps(stream),
    'sniffing':       json.dumps({'enabled':True,'destOverride':['http','tls','quic','fakedns'],'metadataOnly':False,'routeOnly':False}),
    'tag':'inbound-443'
}
print(json.dumps(payload))
PYEOF

# ── Create inbound via API ─────────────────────────────────────────────────
echo "[+] Sending to 3x-ui API..."
ADD=$(curl -s --max-time 15 \
    -b "$COOKIE" \
    -X POST "${XUI}/xui/API/inbounds/add" \
    -H "Content-Type: application/json" \
    -H "X-CSRF-Token: ${CSRF}" \
    -d @"$JSON") || true

echo "    Response: $(echo $ADD | cut -c1-100)"

if echo "$ADD" | grep -q '"success":true'; then
    IID=$(echo "$ADD" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "1")
    sed -i "s/^INBOUND_ID=.*/INBOUND_ID=${IID}/" .env
    echo "[+] Inbound created (id=${IID})"
else
    echo "[!] API failed, writing directly to SQLite..."
    python3 - "$PRIV" "$PUB" "$SHORTID" << 'PYEOF2'
import sqlite3, json, sys
priv, pub, shortid = sys.argv[1], sys.argv[2], sys.argv[3]
stream = {
    'network':'tcp','security':'reality',
    'realitySettings':{'show':False,'xver':0,'dest':'www.apple.com:443','serverNames':['www.apple.com'],
                       'privateKey':priv,'minClient':'','maxTimeDiff':0,'shortIds':[shortid],'fingerprint':'chrome','headers':{}},
    'tcpSettings':{'acceptProxyProtocol':False,'header':{'type':'none'}}
}
row = {
    'user_id':1,'up':0,'down':0,'total':0,'remark':'VLESS-Reality','enable':1,'expiry_time':0,
    'listen':'','port':443,'protocol':'vless',
    'settings':json.dumps({'clients':[],'decryption':'none','fallbacks':[]}),
    'stream_settings':json.dumps(stream),'tag':'inbound-443',
    'sniffing':json.dumps({'enabled':True,'destOverride':['http','tls','quic','fakedns'],'metadataOnly':False,'routeOnly':False}),
    'allocate':json.dumps({'strategy':'always','refresh':5,'concurrency':3})
}
db = sqlite3.connect('/opt/vpn/3xui/db/x-ui.db')
try:
    db.execute('INSERT INTO inbounds(user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing,allocate) VALUES(:user_id,:up,:down,:total,:remark,:enable,:expiry_time,:listen,:port,:protocol,:settings,:stream_settings,:tag,:sniffing,:allocate)',row)
    db.commit(); print('[+] Written to SQLite')
except Exception as e: print(f'Error: {e}')
finally: db.close()
PYEOF2
    docker restart 3xui > /dev/null 2>&1 && echo "[+] 3x-ui restarted"
fi

# Save keys
grep -q REALITY_PUBLIC_KEY .env || echo "REALITY_PUBLIC_KEY=${PUB}"     >> .env
grep -q REALITY_SHORT_ID   .env || echo "REALITY_SHORT_ID=${SHORTID}"   >> .env

echo ""
echo "=========================================="
echo "  VLESS Reality — DONE"
echo "  Port       : 443"
echo "  Dest       : www.apple.com:443"
echo "  Public key : ${PUB}"
echo "  Short ID   : ${SHORTID}"
echo "=========================================="
echo ""
echo "Panel : https://panel.pravoslavny-obereg.ru"
echo "Login : admin / ${ACTUAL_PASS}"
echo ""
echo "Add user: bash /opt/vpn/scripts/add-user.sh email@example.com"
echo ""
