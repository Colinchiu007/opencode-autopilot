#!/bin/bash
# ============================================================================
# opencode-autopilot — Shared Configuration
# Source this file from any bin/* script:  source "$(dirname "$0")/../config.sh"
# Override any value via environment variable before sourcing.
# ============================================================================

# ── Project paths ──────────────────────────────────────────────────────────
: "${PROJECT_DIR:=$(pwd)}"
: "${OMO_DIR:=$PROJECT_DIR/.omo}"
: "${LOG_DIR:=$OMO_DIR/autonomous-logs}"
: "${EVIDENCE_DIR:=$OMO_DIR/evidence}"
: "${CONTINUATION_DIR:=$OMO_DIR/run-continuation}"
: "${BOULDER_FILE:=$OMO_DIR/boulder.json}"

# ── Agent defaults ─────────────────────────────────────────────────────────
: "${AGENT_NAME:=sisyphus}"
: "${PLAN_FILE:=}"

# ── Timing ─────────────────────────────────────────────────────────────────
: "${CYCLE_TIMEOUT:=3600}"      # seconds per cycle (default 1 hour)
: "${SLEEP_BETWEEN:=5}"         # seconds between cycles
: "${MAX_ITERATIONS:=60}"       # max cycles before giving up

# ── Python ──────────────────────────────────────────────────────────────────
# Auto-detect preferred Python: python3.11 > python3.12 > python3
if command -v python3.11 &>/dev/null; then
    : "${PYTHON_CMD:=python3.11}"
elif command -v python3.12 &>/dev/null; then
    : "${PYTHON_CMD:=python3.12}"
else
    : "${PYTHON_CMD:=python3}"
fi

# ── Notification (WeChat Work Bot / Feishu Bot) ─────────────────────────────
# These are handled by notify-config.sh which loads user config files.
# Do NOT set defaults here - let notify-config.sh handle it.
# : "${WECHAT_BOT_KEY:=}"   # Moved to notify-config.sh
# : "${FEISHU_BOT_URL:=}"    # Moved to notify-config.sh
: "${NOTIFY_ON_START:=true}"       # notify when loop starts
: "${NOTIFY_ON_PHASE:=5}"          # notify every N cycles (0 = disabled)
: "${NOTIFY_ON_COMPLETE:=true}"    # notify when all tasks done
: "${NOTIFY_ON_ERROR:=true}"       # notify on failures

# ── Behavior flags ─────────────────────────────────────────────────────────
: "${DETACH:=false}"            # background the loop with nohup
: "${SKIP_STUCK:=false}"        # skip tasks that haven't progressed
: "${STUCK_THRESHOLD:=3}"       # cycles without progress before warning

# ── Colors for terminal output ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ── Helpers ────────────────────────────────────────────────────────────────
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
header(){ echo -e "\n${CYAN}═══ $* ═══${NC}"; }

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
ts_slug()   { date '+%Y%m%d_%H%M%S'; }

# ── Plan checkbox counters ─────────────────────────────────────────────────
# NOTE: grep -c outputs the count (including "0") even on exit code 1 (no matches).
# Using || echo "0" would double-print. Use a local var to handle both cases.
count_remaining() {
    local c
    c=$(grep -c '^- \[ \]' "$1" 2>/dev/null) || c=0
    echo "$c"
}
count_completed() {
    local c
    c=$(grep -c '^- \[x\]' "$1" 2>/dev/null) || c=0
    echo "$c"
}

# ── Notification helper ─────────────────────────────────────────────────────
# Usage: notify <level> <title> <body>
#   level: start|phase|complete|error|warning
#   Automatically reads WECHAT_BOT_KEY and FEISHU_BOT_URL from env.
notify() {
    local level="$1" title="$2" body="$3"
    local notify_script="$SCRIPT_DIR/../bin/notify.sh"
    if [[ -x "$notify_script" ]]; then
        "$notify_script" "$level" "$title" "$body" 2>/dev/null || true
    fi
}

# ── Post-run verification helper ────────────────────────────────────────────
# Usage: verify_work <plan_abs>
# Returns: 0 if all checks pass, 1 otherwise
verify_work() {
    local plan_abs="$1"
    local verify_script="$SCRIPT_DIR/../bin/post-run-verify.sh"
    if [[ -x "$verify_script" ]]; then
        "$verify_script" "$plan_abs"
        return $?
    fi
    # No verify script available — pass by default
    return 0
}

# ── Python helper ───────────────────────────────────────────────────────────
# Usage: run_python <args...>
# Runs the auto-detected Python command
run_python() {
    "$PYTHON_CMD" "$@"
}
