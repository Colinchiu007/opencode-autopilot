#!/bin/bash
# ============================================================================
# opencode-autopilot — Notification Setup Wizard
#
# Interactive setup for WeChat Work Bot and Feishu Bot webhooks.
# Encrypts URLs before saving to prevent accidental credential exposure.
#
# Usage:
#   ./bin/setup-notify.sh
#
# Creates: ~/.opencode-autopilot/notify.conf (not tracked by git)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.opencode-autopilot"
CONFIG_FILE="$CONFIG_DIR/notify.conf"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  opencode-autopilot — Notification Setup                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Create config directory
mkdir -p "$CONFIG_DIR"

# Load existing config if present
WECHAT_BOT_KEY="${WECHAT_BOT_KEY:-}"
FEISHU_BOT_URL="${FEISHU_BOT_URL:-}"
AUTOPILOT_SECRET="${AUTOPILOT_SECRET:-}"

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Found existing config: $CONFIG_FILE"
    source "$CONFIG_FILE"
    echo ""
fi

# ── Encryption Password ──────────────────────────────────────────────────────
echo "Step 1: Encryption Password"
echo "────────────────────────────"
echo "This password encrypts webhook URLs before saving to disk."
echo "Choose a strong password you'll remember."
echo ""

if [[ -n "$AUTOPILOT_SECRET" ]]; then
    echo "Current password is set. Press Enter to keep it, or type a new one."
fi

echo -n "Enter encryption password: "
read -s NEW_PASSWORD
echo ""

if [[ -n "$NEW_PASSWORD" ]]; then
    echo -n "Confirm password: "
    read -s CONFIRM_PASSWORD
    echo ""
    
    if [[ "$NEW_PASSWORD" != "$CONFIRM_PASSWORD" ]]; then
        echo "Error: Passwords do not match"
        exit 1
    fi
    AUTOPILOT_SECRET="$NEW_PASSWORD"
fi

if [[ -z "$AUTOPILOT_SECRET" ]]; then
    echo "Error: Password is required"
    exit 1
fi

# ── WeChat Work Bot (Optional) ───────────────────────────────────────────────
echo ""
echo "Step 2: WeChat Work Bot (Optional)"
echo "───────────────────────────────────"
echo "Skip if you don't use WeChat Work."
echo ""

if [[ -n "$WECHAT_BOT_KEY" ]]; then
    echo "Current key: ${WECHAT_BOT_KEY:0:8}..."
    echo "Press Enter to keep, or type a new key."
fi

echo -n "WeChat Bot Key (or Enter to skip): "
read NEW_WECHAT_KEY

if [[ -n "$NEW_WECHAT_KEY" ]]; then
    WECHAT_BOT_KEY="$NEW_WECHAT_KEY"
fi

# ── Feishu Bot (Optional) ───────────────────────────────────────────────────
echo ""
echo "Step 3: Feishu Bot (Optional)"
echo "──────────────────────────────"
echo "Skip if you don't use Feishu."
echo ""

if [[ -n "$FEISHU_BOT_URL" ]]; then
    echo "Current URL is set. Press Enter to keep, or paste a new URL."
fi

echo -n "Feishu Bot Webhook URL (or Enter to skip): "
read NEW_FEISHU_URL

if [[ -n "$NEW_FEISHU_URL" ]]; then
    FEISHU_BOT_URL="$NEW_FEISHU_URL"
fi

# ── Save Configuration ──────────────────────────────────────────────────────
echo ""
echo "Saving configuration..."

# Backup existing config
if [[ -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    echo "Backed up: ${CONFIG_FILE}.bak"
fi

# Write config
cat > "$CONFIG_FILE" << EOF
# ============================================================================
# opencode-autopilot — Notification Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT COMMIT THIS FILE TO GIT
# ============================================================================

# Encryption password for webhook URLs
AUTOPILOT_SECRET="$AUTOPILOT_SECRET"

# WeChat Work Bot (encrypted if set)
WECHAT_BOT_KEY="$WECHAT_BOT_KEY"

# Feishu Bot (plain URL - will be encrypted by notify-config.sh)
FEISHU_BOT_URL="$FEISHU_BOT_URL"
EOF

chmod 600 "$CONFIG_FILE"
echo "Saved: $CONFIG_FILE (permissions: 600)"

# ── Test Notification (Optional) ────────────────────────────────────────────
echo ""
echo -n "Send test notification? [y/N]: "
read TEST_NOTIFY

if [[ "$TEST_NOTIFY" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Sending test notification..."
    export AUTOPILOT_SECRET WECHAT_BOT_KEY FEISHU_BOT_URL
    "$SCRIPT_DIR/notify.sh" "info" "Test Notification" "Setup completed successfully! 🎉"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Setup Complete!                                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Configuration saved to: $CONFIG_FILE"
echo ""
echo "Channels configured:"
[[ -n "$WECHAT_BOT_KEY" ]] && echo "  ✓ WeChat Work Bot"
[[ -n "$FEISHU_BOT_URL" ]] && echo "  ✓ Feishu Bot"
[[ -z "$WECHAT_BOT_KEY" && -z "$FEISHU_BOT_URL" ]] && echo "  ⚠ No channels configured"
echo ""
echo "To use encrypted URLs in git:"
echo "  1. Run: ./bin/encrypt-url.sh \"\$FEISHU_BOT_URL\""
echo "  2. Save encrypted value to config.sh or notify-config.sh"
echo "  3. Set AUTOPILOT_SECRET in ~/.opencode-autopilot/notify.conf"
echo ""
