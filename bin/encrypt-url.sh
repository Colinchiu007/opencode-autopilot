#!/bin/bash
# ============================================================================
# opencode-autopilot — URL Encryption Tool
#
# Encrypts webhook URLs using AES-256-CBC for safe storage in git.
# Uses openssl for encryption, no external dependencies.
#
# Usage:
#   ./bin/encrypt-url.sh <url>
#   ./bin/encrypt-url.sh "https://open.feishu.cn/open-apis/bot/v2/hook/xxxx"
#
# Output:
#   Encrypted string (base64-encoded) - safe to commit to git
#
# Environment:
#   AUTOPILOT_SECRET  Encryption key (prompted if not set)
# ============================================================================

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <url-to-encrypt>"
    echo ""
    echo "Encrypts a webhook URL for safe storage in git."
    echo "Set AUTOPILOT_SECRET env var or enter password when prompted."
    exit 1
fi

URL="$1"

# Get encryption key
if [[ -z "${AUTOPILOT_SECRET:-}" ]]; then
    echo -n "Enter encryption password: "
    read -s PASSWORD
    echo ""
    
    if [[ -z "$PASSWORD" ]]; then
        echo "Error: Password cannot be empty"
        exit 1
    fi
else
    PASSWORD="$AUTOPILOT_SECRET"
fi

# Encrypt using AES-256-CBC
# - salt: adds random salt for security
# - base64: outputs base64 string
# - md5: key derivation (compatible with most systems)
ENCRYPTED=$(echo -n "$URL" | openssl enc -aes-256-cbc -a -salt -pbkdf2 -pass pass:"$PASSWORD" 2>/dev/null)

if [[ $? -eq 0 ]]; then
    echo ""
    echo "Encrypted URL:"
    echo "$ENCRYPTED"
    echo ""
    echo "Add to config.sh or notify-config.sh:"
    echo "  FEISHU_BOT_URL_ENC=\"$ENCRYPTED\""
    echo ""
    echo "Set encryption key in ~/.opencode-autopilot/notify.conf:"
    echo "  AUTOPILOT_SECRET=\"your-password\""
else
    echo "Error: Encryption failed"
    exit 1
fi
