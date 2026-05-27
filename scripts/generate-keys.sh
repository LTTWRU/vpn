#!/usr/bin/env bash
set -euo pipefail

echo "Generating X25519 key pair for VLESS Reality..."
echo ""
docker exec 3xui xray x25519
echo ""
echo "Copy the keys above into 3x-ui when creating the VLESS Reality inbound:"
echo "  Private Key → realitySettings.privateKey (server side)"
echo "  Public Key  → used by clients (subscription service reads it automatically)"
