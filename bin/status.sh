#!/bin/bash
# ============================================================================
# opencode-autopilot — Runtime status check
#
# Shows current execution status: running processes, progress, logs.
# Useful for checking overnight / long-running autonomous runs.
#
# Usage:
#   ./bin/status.sh                    # show current status
#   ./bin/status.sh --watch            # watch mode (refresh every 10s)
#   ./bin/status.sh --tail             # tail recent log output
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

WATCH=false
TAIL=false
for arg in "$@"; do
    case "$arg" in
        --watch|-w) WATCH=true ;;
        --tail|-t)  TAIL=true ;;
    esac
done

# ── Single snapshot ─────────────────────────────────────────────────────────
snapshot() {
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  opencode-autopilot — Status                            ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo "  Time:    $(timestamp)"
    echo ""

    # ── Running processes ───────────────────────────────────────────────
    echo "── Processes ──"
    RUNNING=$(ps aux | grep "opencode run" | grep -v grep)
    if [[ -n "$RUNNING" ]]; then
        echo "$RUNNING" | awk '{
            print "  PID " $2 " (uptime: " $9 ")"
            print "    " $12, $13, $14, $15
        }'
    else
        echo "  (no opencode run process)"
    fi

    # Loop process
    LOOP_PID=$(ps aux | grep "opencode-autopilot/bin/loop.sh\|auto-loop.sh" | grep -v grep | awk '{print $2}')
    if [[ -n "$LOOP_PID" ]]; then
        echo "  Loop PID: $LOOP_PID (parent)"
    fi
    echo ""

    # ── Plan progress ──────────────────────────────────────────────────
    echo "── Plan Progress ──"
    # Find newest plan file
    PLAN_FILES=()
    while IFS= read -r f; do
        if [[ -f "$f" ]] && grep -q '^- \[' "$f" 2>/dev/null; then
            PLAN_FILES+=("$f")
        fi
    done < <(find "$PROJECT_DIR" -name "*.md" -path "*plan*" 2>/dev/null | head -5)
    
    if [[ ${#PLAN_FILES[@]} -gt 0 ]]; then
        for pf in "${PLAN_FILES[@]}"; do
            REM=$(count_remaining "$pf")
            DONE=$(count_completed "$pf")
            TOTAL=$((REM + DONE))
            echo "  $pf"
            echo "  $DONE/$TOTAL done, $REM remaining"
        done
    else
        # Try .omo/plans/
        for pf in "$OMO_DIR/plans"/*.md; do
            if [[ -f "$pf" ]]; then
                REM=$(count_remaining "$pf")
                DONE=$(count_completed "$pf")
                TOTAL=$((REM + DONE))
                echo "  $(basename "$pf"): $DONE/$TOTAL done"
            fi
        done
    fi
    echo ""

    # ── Recent log ─────────────────────────────────────────────────────
    echo "── Recent Log Output ──"
    LATEST_LOG=$(ls -t "$LOG_DIR"/cycle_*.log 2>/dev/null | head -1)
    if [[ -n "$LATEST_LOG" ]]; then
        echo "  Log: $LATEST_LOG"
        echo ""
        # Extract text outputs from JSON lines
        grep -oE '"type":"text".*?"text":"[^"]*"' "$LATEST_LOG" 2>/dev/null | tail -5 | while read -r line; do
            # Extract text field
            TXT=$(echo "$line" | sed 's/.*"text":"//' | sed 's/".*//' | sed 's/\\n/\n/g' | head -3)
            echo "  > $TXT"
        done
    else
        echo "  No cycle logs found."
    fi
    echo ""

    # ── Boulder state ──────────────────────────────────────────────────
    if [[ -f "$BOULDER_FILE" ]]; then
        echo "── Boulder State ──"
        python3 -c "
import json
with open('$BOULDER_FILE') as f: b = json.load(f)
for wid, w in b.get('works', {}).items():
    print(f'  Work: {wid}')
    print(f'  Status: {w.get(\"status\", \"?\")}')
    print(f'  Sessions: {len(w.get(\"session_ids\", []))}')
    print(f'  Progress: {w.get(\"completed\", \"?\")} done, {w.get(\"remaining\", \"?\")} remaining')
" 2>/dev/null
    else
        echo "  No boulder state file."
    fi

    # ── Resource usage ─────────────────────────────────────────────────
    echo ""
    echo "── Resources ──"
    echo "  CPU:    $(uptime | grep -o 'load average:.*' | cut -d: -f2)"
    echo "  Memory: $(free -h | grep Mem | awk '{print $3" / "$2}')"
    echo "  Disk:   $(df -h "$PROJECT_DIR" | tail -1 | awk '{print $3" / "$2" ("$5")"}')"
}

# ── Mode ────────────────────────────────────────────────────────────────────
if $TAIL; then
    LATEST_LOG=$(ls -t "$LOG_DIR"/cycle_*.log 2>/dev/null | head -1)
    if [[ -n "$LATEST_LOG" ]]; then
        tail -f "$LATEST_LOG"
    else
        LATEST_LOG=$(ls -t "$LOG_DIR"/loop_*.log 2>/dev/null | head -1)
        if [[ -n "$LATEST_LOG" ]]; then
            tail -f "$LATEST_LOG"
        else
            err "No log files found."
            exit 1
        fi
    fi
elif $WATCH; then
    while true; do
        clear 2>/dev/null || true
        snapshot
        sleep 10
    done
else
    snapshot
fi
