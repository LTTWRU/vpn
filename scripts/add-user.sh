#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"
source .env

EMAIL="${1:-}"
[[ -z "$EMAIL" ]] && { echo "Usage: bash scripts/add-user.sh <email>"; exit 1; }

SUB_HOST="http://127.0.0.1:8001"
UUID=$(cat /proc/sys/kernel/random/uuid)
DB="/opt/vpn/3xui/db/x-ui.db"

# ── Resolve inbound ID ────────────────────────────────────────────────
if [[ -z "${INBOUND_ID:-}" ]]; then
    INBOUND_ID=$(python3 -c "
import sqlite3
db = sqlite3.connect('${DB}')
row = db.execute('SELECT id FROM inbounds WHERE port=443').fetchone()
db.close()
print(row[0] if row else '')
")
    [[ -z "$INBOUND_ID" ]] && { echo "ERROR: No inbound found on port 443. Run inbound.sh first."; exit 1; }
    echo "INBOUND_ID=${INBOUND_ID}" >> .env
fi

# ── Add client to SQLite directly ──────────────────────────────────────
echo "[+] Writing client to SQLite..."
python3 - "$INBOUND_ID" "$UUID" "$EMAIL" "$DB" << 'PYEOF'
import sqlite3, json, sys

iid, uuid, email, db_path = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]

db = sqlite3.connect(db_path)
try:
    row = db.execute('SELECT settings FROM inbounds WHERE id=?', (iid,)).fetchone()
    if not row:
        print(f'ERROR: inbound {iid} not found')
        sys.exit(1)

    settings = json.loads(row[0])
    clients  = settings.get('clients', [])

    for c in clients:
        if c.get('email') == email:
            print(f'ERROR: email already exists in inbound')
            sys.exit(1)

    clients.append({
        'id': uuid, 'email': email, 'limitIp': 1,
        'totalGB': 0, 'expiryTime': 0, 'enable': True,
        'tgId': '', 'subId': '', 'flow': 'xtls-rprx-vision', 'reset': 0
    })
    settings['clients'] = clients
    db.execute('UPDATE inbounds SET settings=? WHERE id=?',
               (json.dumps(settings), iid))
    db.commit()
    print(f'[+] Client {email} added (UUID={uuid})')
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
finally:
    db.close()
PYEOF

# ── Restart 3x-ui to pick up changes ────────────────────────────────
echo "[+] Restarting 3x-ui..."
docker restart 3xui > /dev/null 2>&1
sleep 4

# ── Register in subscription service ───────────────────────────────────
SUB=$(curl -s --max-time 10 \
    -X POST "${SUB_HOST}/admin/users" \
    -H "Content-Type: application/json" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}" \
    -d "{\"email\":\"${EMAIL}\",\"uuid\":\"${UUID}\"}")

TOKEN=$(python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('token') or d.get('sub_token',''))" <<< "$SUB" 2>/dev/null || true)
[[ -z "$TOKEN" ]] && { echo "ERROR: subscription service response: $SUB"; exit 1; }

echo ""
echo "===================================="
echo "  User added"
echo "  Email : ${EMAIL}"
echo "  UUID  : ${UUID}"
echo "  Sub   : https://sub.pravoslavny-obereg.ru/sub/${TOKEN}"
echo "===================================="
echo ""
