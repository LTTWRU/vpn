#!/usr/bin/env bash
# Creates VLESS+Reality inbound in 3x-ui (v3)
set -uo pipefail

cd /opt/vpn
source .env

XUI="http://127.0.0.1:2053"
COOKIE=$(mktemp)
JSON=$(mktemp)
trap "rm -f $COOKIE $JSON" EXIT

echo ""
echo "=== Creating VLESS Reality inbound ==="
echo ""

# ── Generate X25519 keys via Python cryptography ──────────────────────
echo "[+] Generating X25519 key pair..."
KEYS=$(python3 - << 'PYEOF'
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
import base64
pk = X25519PrivateKey.generate()
priv = base64.urlsafe_b64encode(pk.private_bytes_raw()).rstrip(b'=').decode()
pub  = base64.urlsafe_b64encode(pk.public_key().public_bytes_raw()).rstrip(b'=').decode()
print(f"{priv} {pub}")
PYEOF
)
PRIV=$(echo "$KEYS" | awk '{print $1}')
PUB=$(echo  "$KEYS" | awk '{print $2}')
SHORTID=$(openssl rand -hex 4)
echo "    Private key : $PRIV"
echo "    Public key  : $PUB"
echo "    Short ID    : $SHORTID"

# ── Write inbound directly to SQLite (correct schema) ──────────────────
echo "[+] Writing inbound to SQLite..."
python3 - "$PRIV" "$PUB" "$SHORTID" << 'PYEOF'
import sqlite3, json, sys

priv, pub, shortid = sys.argv[1], sys.argv[2], sys.argv[3]

stream = {
    'network': 'tcp', 'security': 'reality',
    'realitySettings': {
        'show': False, 'xver': 0,
        'dest': 'www.apple.com:443',
        'serverNames': ['www.apple.com'],
        'privateKey': priv,
        'publicKey': pub,
        'minClient': '', 'maxTimeDiff': 0,
        'shortIds': [shortid],
        'fingerprint': 'chrome', 'headers': {}
    },
    'tcpSettings': {'acceptProxyProtocol': False, 'header': {'type': 'none'}}
}

row = {
    'user_id': 1, 'up': 0, 'down': 0, 'total': 0,
    'remark': 'VLESS-Reality', 'enable': 1,
    'expiry_time': 0, 'listen': '', 'port': 443,
    'protocol': 'vless',
    'settings':       json.dumps({'clients': [], 'decryption': 'none', 'fallbacks': []}),
    'stream_settings': json.dumps(stream),
    'tag': 'inbound-443',
    'sniffing': json.dumps({'enabled': True,
                            'destOverride': ['http', 'tls', 'quic', 'fakedns'],
                            'metadataOnly': False, 'routeOnly': False}),
    'node_id': 0
}

db = sqlite3.connect('/opt/vpn/3xui/db/x-ui.db')
try:
    existing = db.execute('SELECT id FROM inbounds WHERE port=443').fetchone()
    if existing:
        db.execute('''UPDATE inbounds SET
            remark=:remark, enable=:enable, protocol=:protocol,
            settings=:settings, stream_settings=:stream_settings,
            tag=:tag, sniffing=:sniffing
            WHERE port=443''', row)
        iid = existing[0]
        print(f'[+] Updated existing inbound on port 443 (id={iid})')
    else:
        cur = db.execute('''INSERT INTO inbounds
            (user_id,up,down,total,remark,enable,expiry_time,listen,port,
             protocol,settings,stream_settings,tag,sniffing,node_id)
            VALUES
            (:user_id,:up,:down,:total,:remark,:enable,:expiry_time,:listen,:port,
             :protocol,:settings,:stream_settings,:tag,:sniffing,:node_id)''', row)
        iid = cur.lastrowid
        print(f'[+] Inbound inserted into SQLite (id={iid})')
    db.commit()
    with open('/tmp/xui_inbound_id', 'w') as f:
        f.write(str(iid))
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
finally:
    db.close()
PYEOF

# Save inbound ID to .env
INBOUND_ID=$(cat /tmp/xui_inbound_id 2>/dev/null || echo '')
rm -f /tmp/xui_inbound_id
if [[ -n "$INBOUND_ID" ]]; then
    if grep -q '^INBOUND_ID=' .env; then
        sed -i "s/^INBOUND_ID=.*/INBOUND_ID=${INBOUND_ID}/" .env
    else
        echo "INBOUND_ID=${INBOUND_ID}" >> .env
    fi
fi

# ── Restart 3x-ui to pick up the new inbound ─────────────────────────
echo "[+] Restarting 3x-ui..."
docker restart 3xui > /dev/null 2>&1
echo "[+] Done (waiting 5s)"
sleep 5

# ── Save keys to .env ───────────────────────────────────────────────
for kv in "REALITY_PUBLIC_KEY=${PUB}" "REALITY_SHORT_ID=${SHORTID}"; do
    key="${kv%%=*}"
    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${kv}|" .env
    else
        echo "$kv" >> .env
    fi
done
sed -i "s/^XUI_PASSWORD=.*/XUI_PASSWORD=admin/" .env

echo ""
echo "========================================"
echo "  VLESS Reality Inbound — READY"
echo "  Port       : 443"
echo "  Dest       : www.apple.com:443"
echo "  Public key : ${PUB}"
echo "  Short ID   : ${SHORTID}"
echo "========================================"
echo ""
echo "Panel : https://panel.pravoslavny-obereg.ru"
echo "Login : admin / admin"
echo ""
echo "Add user: bash /opt/vpn/scripts/add-user.sh email@example.com"
echo ""
