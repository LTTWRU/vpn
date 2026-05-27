#!/usr/bin/env bash
# Generate a subscription URL for a user already added via the 3x-ui panel.
# Usage: bash scripts/gen-sub.sh <email>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"
source .env

EMAIL="${1:-}"
[[ -z "$EMAIL" ]] && { echo "Usage: bash scripts/gen-sub.sh <email>"; exit 1; }

# ── Check user exists in 3x-ui ──────────────────────────────────────────────
STATUS=$(python3 -c "
import sqlite3, json
db = sqlite3.connect('/opt/vpn/3xui/db/x-ui.db')
row = db.execute(\"SELECT settings FROM inbounds WHERE port=443\").fetchone()
db.close()
if not row:
    print('no_inbound')
else:
    clients = json.loads(row[0]).get('clients', [])
    emails = [c.get('email','') for c in clients]
    print('found' if '${EMAIL}' in emails else 'not_found')
")

if [[ "$STATUS" == "not_found" ]]; then
    echo "ERROR: '${EMAIL}' not found in 3x-ui inbound."
    echo "Add the user via the panel first, then run this script."
    exit 1
elif [[ "$STATUS" == "no_inbound" ]]; then
    echo "ERROR: No VLESS inbound found on port 443."
    exit 1
fi

# ── Register in subscription service ──────────────────────────────────────────────
SUB=$(curl -s --max-time 10 \
    -X POST "http://127.0.0.1:8001/admin/users" \
    -H "Content-Type: application/json" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}" \
    -d "{\"email\":\"${EMAIL}\"}")

TOKEN=$(python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('token',''))" <<< "$SUB" 2>/dev/null || true)
[[ -z "$TOKEN" ]] && { echo "ERROR: subscription service response: $SUB"; exit 1; }

echo ""
echo "===================================="
echo "  Subscription generated"
echo "  Email : ${EMAIL}"
echo "  Sub   : https://sub.pravoslavny-obereg.ru/sub/${TOKEN}"
echo "===================================="
echo ""
