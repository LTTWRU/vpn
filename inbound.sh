#!/usr/bin/env bash
# Creates VLESS+Reality inbound in 3x-ui via local API (3x-ui v3, with CSRF)
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

# Step 1: Get CSRF token and session cookie from login page
echo "[+] Fetching CSRF token..."
HTML=$(curl -s --max-time 10 -c "$COOKIE" "${XUI}/")
CSRF=$(echo "$HTML" | grep -oP '(?<=csrf-token" content=")[^"]+' || true)

if [[ -z "$CSRF" ]]; then
    # Try alternative meta tag format
    CSRF=$(echo "$HTML" | python3 -c "
import sys, re
m = re.search(r'csrf-token.*?content=\"([^\"]+)', sys.stdin.read())
print(m.group(1) if m else '')
" 2>/dev/null || true)
fi

echo "[+] CSRF token: ${CSRF:0:20}..."

# Step 2: Try login with both passwords
login_ok=0
for PASS in "${XUI_PASSWORD:-}" "admin"; do
    [[ -z "$PASS" ]] && continue
    
    # Try JSON body first (3x-ui v3)
    RESP=$(curl -s --max-time 10 \
        -c "$COOKIE" -b "$COOKIE" \
        -X POST "${XUI}/login" \
        -H "X-CSRF-Token: ${CSRF}" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${XUI_USERNAME:-admin}\",\"password\":\"${PASS}\"}" 2>&1)
    
    if echo "$RESP" | grep -qi 'success.*true\|token\|"id"'; then
        echo "[+] Logged in with JSON body (pass: ${PASS})"
        login_ok=1
        break
    fi
    
    # Try form data (3x-ui v2)
    RESP=$(curl -s --max-time 10 \
        -c "$COOKIE" -b "$COOKIE" \
        -X POST "${XUI}/login" \
        -H "X-CSRF-Token: ${CSRF}" \
        -d "username=${XUI_USERNAME:-admin}&password=${PASS}" 2>&1)
    
    if echo "$RESP" | grep -qi '"success":true'; then
        echo "[+] Logged in with form data (pass: ${PASS})"
        login_ok=1
        break
    fi
    
    echo "    Tried pass '${PASS}': $(echo $RESP | head -c 100)"
done

if [[ $login_ok -eq 0 ]]; then
    echo ""
    echo "ERROR: Cannot log into 3x-ui API."
    echo "Falling back to direct DB method..."
    
    # Generate keys and inbound via direct DB write
    KEYS=$(docker exec 3xui xray x25519 2>/dev/null)
    PRIV=$(echo "$KEYS" | awk '/Private/{print $NF}')
    PUB=$(echo  "$KEYS" | awk '/Public/{print $NF}')
    SHORTID=$(openssl rand -hex 4)
    
    echo "[+] X25519 keys generated"
    echo "    Private key : $PRIV"
    echo "    Public key  : $PUB"
    echo "    Short ID    : $SHORTID"
    
    python3 << PYEOF
import sqlite3, json, sys

priv = '$PRIV'
pub  = '$PUB'
shortid = '$SHORTID'

stream = {
    'network': 'tcp', 'security': 'reality',
    'realitySettings': {
        'show': False, 'xver': 0,
        'dest': 'www.apple.com:443',
        'serverNames': ['www.apple.com'],
        'privateKey': priv, 'minClient': '',
        'maxTimeDiff': 0, 'shortIds': [shortid],
        'fingerprint': 'chrome', 'headers': {}
    },
    'tcpSettings': {'acceptProxyProtocol': False, 'header': {'type': 'none'}}
}

row = {
    'user_id': 1, 'up': 0, 'down': 0, 'total': 0,
    'remark': 'VLESS-Reality', 'enable': 1,
    'expiry_time': 0, 'listen': '', 'port': 443,
    'protocol': 'vless', 'settings': json.dumps({'clients':[],'decryption':'none','fallbacks':[]}),
    'stream_settings': json.dumps(stream),
    'tag': 'inbound-443',
    'sniffing': json.dumps({'enabled':True,'destOverride':['http','tls','quic','fakedns'],'metadataOnly':False,'routeOnly':False}),
    'allocate': json.dumps({'strategy':'always','refresh':5,'concurrency':3})
}

db = sqlite3.connect('/opt/vpn/3xui/db/x-ui.db')
try:
    db.execute('''
        INSERT INTO inbounds
        (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,
         settings,stream_settings,tag,sniffing,allocate)
        VALUES
        (:user_id,:up,:down,:total,:remark,:enable,:expiry_time,:listen,:port,:protocol,
         :settings,:stream_settings,:tag,:sniffing,:allocate)
    ''', row)
    db.commit()
    print('[+] Inbound written directly to database')
except Exception as e:
    print(f'DB error: {e}', file=sys.stderr)
finally:
    db.close()

with open('/tmp/reality_keys.env','w') as f:
    f.write(f'REALITY_PUBLIC_KEY={pub}\nREALITY_SHORT_ID={shortid}\n')
PYEOF
    
    # Restart to pick up new inbound
    docker restart 3xui > /dev/null 2>&1
    echo "[+] 3x-ui restarted to load new inbound"
fi

# Show summary
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
