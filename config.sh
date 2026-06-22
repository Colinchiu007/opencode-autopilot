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
