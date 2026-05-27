#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"
source .env

curl -s "http://127.0.0.1:8001/admin/users" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}" | \
    python3 -c "
import sys, json
try:
    users = json.load(sys.stdin)
except:
    print('Error reading subscription service'); sys.exit(1)
if not users:
    print('No users registered.')
    sys.exit(0)
print(f\"{'Email':<35} {'Active':<8} {'Created':<22} Sub URL\")
print('-' * 100)
for u in users:
    active = 'YES' if u.get('active') else 'no'
    print(f\"{u['email']:<35} {active:<8} {u.get('created_at','?'):<22} {u.get('sub_url','?')}\")
"
