#!/bin/bash
# ============================================================================
# opencode-autopilot — Notification Configuration
#
# This file defines webhook URLs for WeChat Work Bot and Feishu Bot.
# It is sourced by bin/notify.sh and other scripts.
#
# IMPORTANT: Never commit real webhook URLs to git!
# Use environment variables to override:
#
#   export WECHAT_BOT_KEY="your-wechat-bot-key-here"
#   export FEISHU_BOT_URL="https://open.feishu.cn/open-apis/bot/v2/hook/your-webhook"
#
# Or create ~/.opencode-autopilot/notify.conf with:
#   WECHAT_BOT_KEY="..."
#   FEISHU_BOT_URL="..."
#
# For encrypted URLs (safe to commit):
#   FEISHU_BOT_URL_ENC="U2FsdGVkX1+..."
#   AUTOPILOT_SECRET="your-encryption-password"
#
# ============================================================================

NOTIFY_CONFIG_VERSION="1.1.0"

# ── WeChat Work Bot ──────────────────────────────────────────────────────────
# Docs: https://developer.work.weixin.qq.com/document/path/91770
# Create a bot in a WeChat Work group -> get webhook key
# API: POST https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=KEY
WECHAT_BOT_KEY="${WECHAT_BOT_KEY:-}"

# ── Feishu Bot ───────────────────────────────────────────────────────────────
# Docs: https://open.feishu.cn/document/uAjLw4CM/ukzMukzMukzM/feishu-bot/custom-bot
# Create a bot in a Feishu group -> get webhook URL
# API: POST to the webhook URL directly
FEISHU_BOT_URL="${FEISHU_BOT_URL:-}"

# ── Encrypted Feishu Bot URL (safe to commit to git) ─────────────────────────
# Use encrypt-url.sh to generate: ./bin/encrypt-url.sh "https://..."
# Requires AUTOPILOT_SECRET to be set for decryption
FEISHU_BOT_URL_ENC="${FEISHU_BOT_URL_ENC:-}"

# ── User config override ────────────────────────────────────────────────────
# Allow per-user config file to override env vars (without committing secrets)
_USER_NOTIFY_CONF="${HOME}/.opencode-autopilot/notify.conf"
if [[ -f "$_USER_NOTIFY_CONF" ]]; then
    source "$_USER_NOTIFY_CONF"
fi

# ── Decrypt encrypted URLs if needed ────────────────────────────────────────
# Auto-decrypt FEISHU_BOT_URL_ENC -> FEISHU_BOT_URL if URL is not set
_decrypt_url() {
    local encrypted="$1"
    local secret="${AUTOPILOT_SECRET:-}"
    
    if [[ -z "$secret" ]]; then
        echo "" # Cannot decrypt without secret
        return
    fi
    
    # Use openssl to decrypt AES-256-CBC
    echo -n "$encrypted" | openssl enc -aes-256-cbc -d -a -pbkdf2 -pass pass:"$secret" 2>/dev/null || echo ""
}

# Auto-decrypt if encrypted URL is set but plain URL is not
if [[ -n "$FEISHU_BOT_URL_ENC" ]] && [[ -z "$FEISHU_BOT_URL" ]]; then
    FEISHU_BOT_URL=$(_decrypt_url "$FEISHU_BOT_URL_ENC")
    if [[ -n "$FEISHU_BOT_URL" ]]; then
        # Verify it looks like a URL
        if [[ ! "$FEISHU_BOT_URL" =~ ^https?:// ]]; then
            # Decryption produced garbage - probably wrong password
            FEISHU_BOT_URL=""
            echo "[notify-config] WARNING: Failed to decrypt FEISHU_BOT_URL_ENC (wrong password?)" >&2
        fi
    fi
fi

# ── Status ───────────────────────────────────────────────────────────────────
notify_is_wechat_enabled() {
    [[ -n "$WECHAT_BOT_KEY" ]]
}

notify_is_feishu_enabled() {
    [[ -n "$FEISHU_BOT_URL" ]]
}

notify_is_enabled() {
    notify_is_wechat_enabled || notify_is_feishu_enabled
}

# ── Encryption helper ────────────────────────────────────────────────────────
# Usage: notify_encrypt_url "https://..."
# Outputs: encrypted string (base64-encoded)
notify_encrypt_url() {
    local url="$1"
    local secret="${AUTOPILOT_SECRET:-}"
    
    if [[ -z "$secret" ]]; then
        echo "Error: AUTOPILOT_SECRET not set" >&2
        return 1
    fi
    
    echo -n "$url" | openssl enc -aes-256-cbc -a -salt -pbkdf2 -pass pass:"$secret" 2>/dev/null
}
