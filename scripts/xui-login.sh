#!/usr/bin/env bash
# Source this file to get a logged-in 3x-ui session.
# Usage: source scripts/xui-login.sh <cookie_file>
# Sets XUI_CSRF variable.

XUI_COOKIE_FILE="${1:-}"
[[ -z "$XUI_COOKIE_FILE" ]] && { echo "Usage: source xui-login.sh <cookiefile>"; return 1; }

XUI_HOST="http://127.0.0.1:2053"

# Get CSRF token
HTML=$(curl -s --max-time 10 -c "$XUI_COOKIE_FILE" "${XUI_HOST}/")
XUI_CSRF=$(grep -o 'csrf-token" content="[^"]*' <<< "$HTML" | sed 's/csrf-token" content="//' || true)

# Login (try configured password, fallback admin)
for PASS in "${XUI_PASSWORD:-}" "admin"; do
    [[ -z "$PASS" ]] && continue
    RESP=$(curl -s --max-time 10 \
        -c "$XUI_COOKIE_FILE" -b "$XUI_COOKIE_FILE" \
        -X POST "${XUI_HOST}/login" \
        -H "X-CSRF-Token: ${XUI_CSRF}" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${XUI_USERNAME:-admin}\",\"password\":\"${PASS}\"}" 2>/dev/null)
    if echo "$RESP" | grep -q '"success":true'; then
        export XUI_CSRF XUI_HOST
        return 0
    fi
done

echo "ERROR: 3x-ui login failed" >&2
return 1
