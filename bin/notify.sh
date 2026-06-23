#!/bin/bash
# ============================================================================
# opencode-autopilot — Notification Sender (shell wrapper)
#
# Thin wrapper around notify.py. Sources config, resolves paths, delegates.
#
# Usage:
#   ./bin/notify.sh <level> <title> <body>
#
# Levels: start | phase | complete | error | warning | info
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../notify-config.sh"

# Export variables for notify.py
export WECHAT_BOT_KEY
export FEISHU_BOT_URL
export PROJECT_DIR

# Delegate to Python implementation
"$PYTHON_CMD" "$SCRIPT_DIR/notify.py" "$@"
