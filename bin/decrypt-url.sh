#!/bin/bash
# ============================================================================
# opencode-autopilot — URL Decryption Tool
#
# Decrypts webhook URLs encrypted with encrypt-url.sh
# Uses openssl for decryption, no external dependencies.
#
# Usage:
#   ./bin/decrypt-url.sh <encrypted-url>
#   ./bin/decrypt-url.sh "U2FsdGVkX1+..."
#
# Environment:
#   AUTOPILOT_SECRET  Decryption key (prompted if not set)
# ============================================================================

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <encrypted-url>"
    echo ""
    echo "Decrypts a webhook URL encrypted with encrypt-url.sh"
    echo "Set AUTOPILOT_SECRET env var or enter password when prompted."
    exit 1
fi

ENCRYPTED="$1"

# Get decryption key
if [[ -z "${AUTOPILOT_SECRET:-}" ]]; then
    echo -n "Enter decryption password: "
    read -s PASSWORD
    echo ""
    
    if [[ -z "$PASSWORD" ]]; then
        echo "Error: Password cannot be empty"
        exit 1
    fi
else
    PASSWORD="$AUTOPILOT_SECRET"
fi

# Decrypt using AES-256-CBC
DECRYPTED=$(echo -n "$ENCRYPTED" | openssl enc -aes-256-cbc -d -a -pbkdf2 -pass pass:"$PASSWORD" 2>/dev/null)

if [[ $? -eq 0 ]]; then
    echo "$DECRYPTED"
else
    echo "Error: Decryption failed (wrong password or corrupted data)" >&2
    exit 1
fi
