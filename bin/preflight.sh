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
for py in python3 python3.11 python3.12; do
    if command -v "$py" &>/dev/null; then
        VER=$("$py" --version 2>&1)
        echo "     ✓ $VER"
        break
    fi
done
if ! command -v python3 &>/dev/null; then
    err "No Python 3 found"
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

# ── 8. Process conflict check ──────────────────────────────────────────────
echo -e "${CYAN}[8/8] Existing Processes${NC}"
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
    ok "All 8 checks passed!"
    echo ""
fi

exit 0
