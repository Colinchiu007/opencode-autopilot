#!/bin/bash
# ============================================================================
# opencode-autopilot — Pre-flight environment validation
#
# Checks prerequisites before starting a long-running execution.
# Exits with code 1 if any CRITICAL prerequisite fails.
# Reports WARN for non-critical missing items.
#
# Usage:
#   ./bin/preflight.sh <plan-file>
#   ./bin/preflight.sh .omo/plans/my-plan.md
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

PLAN_FILE="${1:-}"
ALLOW_WARN_FAIL=true  # set to false to exit on warnings too

# ── Banner ──────────────────────────────────────────────────────────────────
header "PRE-FLIGHT CHECK"
echo "  Started: $(timestamp)"
echo ""

# ── Stats ───────────────────────────────────────────────────────────────────
FAILED=0
WARNED=0

# ── 1. Plan file ────────────────────────────────────────────────────────────
echo -e "${CYAN}[1/8] Plan File${NC}"
if [[ -n "$PLAN_FILE" ]]; then
    PLAN_ABS=""
    if [[ -f "$PROJECT_DIR/$PLAN_FILE" ]]; then
        PLAN_ABS="$PROJECT_DIR/$PLAN_FILE"
    elif [[ -f "$PLAN_FILE" ]]; then
        PLAN_ABS="$PLAN_FILE"
    fi

    if [[ -n "$PLAN_ABS" ]]; then
        TOTAL=$(count_remaining "$PLAN_ABS" 2>/dev/null || echo "0")
        DONE=$(count_completed "$PLAN_ABS" 2>/dev/null || echo "0")
        echo "     ✓ Plan exists: $PLAN_ABS"
        echo "     Tasks: $DONE done, $TOTAL remaining"
    else
        err "Plan file not found: $PLAN_FILE"
        FAILED=$((FAILED + 1))
    fi
else
    echo "     - No plan file specified (optional for non-plan checks)"
fi
echo ""

# ── 2. opencode CLI ─────────────────────────────────────────────────────────
echo -e "${CYAN}[2/8] opencode CLI${NC}"
if command -v opencode &>/dev/null; then
    VER=$(opencode --version 2>&1 || echo "version info unavailable")
    echo "     ✓ opencode installed: $VER"
else
    err "opencode CLI not found in PATH"
    FAILED=$((FAILED + 1))
fi
echo ""

# ── 3. Agent config ────────────────────────────────────────────────────────
echo -e "${CYAN}[3/8] Agent Configuration${NC}"
CONFIG_PATH="$HOME/.config/opencode/oh-my-openagent.jsonc"
if [[ -f "$CONFIG_PATH" ]]; then
    if grep -q "$AGENT_NAME" "$CONFIG_PATH" 2>/dev/null; then
        echo "     ✓ Agent '$AGENT_NAME' found in $CONFIG_PATH"
    else
        warn "Agent '$AGENT_NAME' not defined in config (will use default)"
        WARNED=$((WARNED + 1))
    fi
    echo "     Config: $CONFIG_PATH"
else
    warn "No agent config at $CONFIG_PATH (will use opencode defaults)"
    WARNED=$((WARNED + 1))
fi
echo ""

# ── 4. Python ───────────────────────────────────────────────────────────────
echo -e "${CYAN}[4/8] Python${NC}"
if command -v "$PYTHON_CMD" &>/dev/null; then
    VER=$("$PYTHON_CMD" --version 2>&1)
    echo "     ✓ Selected Python: $PYTHON_CMD ($VER)"
    # Warn if default python3 resolves to a version < 3.10
    if command -v python3 &>/dev/null; then
        DEF_VER=$(python3 --version 2>&1 | grep -oP '\d+\.\d+' || echo "0")
        if [[ "$(echo "$DEF_VER < 3.10" | bc -l 2>/dev/null)" == "1" ]]; then
            warn "Default python3 is $DEF_VER (PYTHON_CMD=$PYTHON_CMD auto-selected)"
            WARNED=$((WARNED + 1))
        fi
    fi
else
    err "Python ($PYTHON_CMD) not found in PATH"
    FAILED=$((FAILED + 1))
fi
echo ""

# ── 5. Node.js (opencode runtime) ──────────────────────────────────────────
echo -e "${CYAN}[5/8] Node.js${NC}"
if command -v node &>/dev/null; then
    echo "     ✓ Node $(node --version)"
else
    warn "Node.js not found (needed if opencode is npm-based)"
    WARNED=$((WARNED + 1))
fi
echo ""

# ── 6. Disk space ───────────────────────────────────────────────────────────
echo -e "${CYAN}[6/8] Disk Space${NC}"
DISK_INFO=$(df -h "$PROJECT_DIR" | tail -1)
DISK_AVAIL=$(echo "$DISK_INFO" | awk '{print $4}')
DISK_USED=$(echo "$DISK_INFO" | awk '{print $3}')
DISK_PCT=$(echo "$DISK_INFO" | awk '{print $5}' | sed 's/%//')
echo "     Directory: $PROJECT_DIR"
echo "     Used: $DISK_USED / Available: $DISK_AVAIL"
if [[ "$DISK_PCT" -gt 90 ]]; then
    err "Disk usage at ${DISK_PCT}% — critically low"
    FAILED=$((FAILED + 1))
elif [[ "$DISK_PCT" -gt 80 ]]; then
    warn "Disk usage at ${DISK_PCT}% — getting full"
    WARNED=$((WARNED + 1))
fi
echo ""

# ── 7. Memory ───────────────────────────────────────────────────────────────
echo -e "${CYAN}[7/8] Memory${NC}"
MEM_TOTAL=$(free -h | grep Mem | awk '{print $2}')
MEM_AVAIL=$(free -h | grep Mem | awk '{print $7}')
MEM_PCT=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
echo "     Total: $MEM_TOTAL / Available: $MEM_AVAIL (${MEM_PCT}% used)"
if [[ "$MEM_PCT" -gt 90 ]]; then
    warn "Memory at ${MEM_PCT}% — close to limit"
    WARNED=$((WARNED + 1))
fi
echo ""

# ── 8. FFmpeg (media pipeline) ─────────────────────────────────────────────
echo -e "${CYAN}[8/9] FFmpeg${NC}"
if command -v ffmpeg &>/dev/null; then
    echo "     ✓ ffmpeg: $(ffmpeg -version 2>&1 | head -1)"
elif command -v ffprobe &>/dev/null; then
    echo "     ✓ ffprobe found (ffmpeg not in PATH)"
else
    warn "ffmpeg not found (needed for video/media pipeline if Story2Video is active)"
    WARNED=$((WARNED + 1))
fi
echo ""

# ── 9. Notification config ──────────────────────────────────────────────────
echo -e "${CYAN}[9/9] Notification Configuration${NC}"
if notify_is_enabled; then
    WECHAT_MSG="no"
    FEISHU_MSG="no"
    notify_is_wechat_enabled && WECHAT_MSG="yes"
    notify_is_feishu_enabled && FEISHU_MSG="yes"
    echo "     ✓ Notification configured (WeChat: $WECHAT_MSG, Feishu: $FEISHU_MSG)"
else
    warn "No notification channels configured."
    echo "     Set WECHAT_BOT_KEY or FEISHU_BOT_URL for alerts."
    echo "     See notify-config.sh for details."
    WARNED=$((WARNED + 1))
fi
echo ""

# ── 10. Process conflict check ──────────────────────────────────────────────
echo -e "${CYAN}[10/10] Existing Processes${NC}"
EXISTING=$(ps aux | grep "opencode run" | grep -v grep | wc -l)
if [[ "$EXISTING" -gt 0 ]]; then
    warn "Found $EXISTING existing opencode run process(es)"
    ps aux | grep "opencode run" | grep -v grep | awk '{print "     PID " $2 ": " $12, $13, $14}' | head -5
    echo "     Run 'kill <pid>' to stop them, or let them finish."
    WARNED=$((WARNED + 1))
else
    echo "     ✓ No conflicting opencode processes"
fi
echo ""

# ── Summary ─────────────────────────────────────────────────────────────────
header "SUMMARY"
if [[ "$FAILED" -gt 0 ]]; then
    err "$FAILED critical, $WARNED warnings"
    echo ""
    info "Fix the critical errors above and re-run."
    exit 1
elif [[ "$WARNED" -gt 0 ]]; then
    warn "0 critical, $WARNED warnings — proceeding (set ALLOW_WARN_FAIL=true to override)"
    echo ""
else
    ok "All 10 checks passed!"
    echo ""
fi

exit 0
