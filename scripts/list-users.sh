#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"
source .env

curl -sf "http://127.0.0.1:8000/admin/users" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}" | \
    python3 -c "
import sys, json
users = json.load(sys.stdin)
if not users:
    print('No users registered.')
    sys.exit(0)
print(f'{'Email':<30} {'Active':<8} {'Created':<20} Sub URL')
print('-' * 100)
for u in users:
    active = 'YES' if u['active'] else 'NO'
    print(f\"{u['email']:<30} {active:<8} {u['created_at']:<20} {u['sub_url']}\")
"
