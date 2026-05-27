#!/usr/bin/env bash
# Diagnostics: check inbounds schema and xray binary
echo "=== inbounds table columns ==="
python3 -c "
import sqlite3
c = sqlite3.connect('/opt/vpn/3xui/db/x-ui.db')
for row in c.execute('PRAGMA table_info(inbounds)').fetchall():
    print(row[1])
"

echo ""
echo "=== xray binary location ==="
docker exec 3xui find / -name 'xray' -type f 2>/dev/null | head -5

echo ""
echo "=== xray x25519 output ==="
docker exec 3xui xray x25519 2>&1 || true
docker exec 3xui /app/bin/xray x25519 2>&1 || true

echo ""
echo "=== python cryptography available? ==="
python3 -c "from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey; print('YES')" 2>&1
