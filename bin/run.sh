#!/bin/bash
# ============================================================================
# opencode-autopilot — Single-shot execution
#
# Runs opencode once against a plan file. Use for one-off or manual runs.
# For multi-cycle automatic retry, use loop.sh instead.
#
# Usage:
#   ./bin/run.sh <plan-file> [session-id]
#   ./bin/run.sh .omo/plans/my-plan.md
#   ./bin/run.sh .omo/plans/my-plan.md ses_abc123
#
# Environment:
#   PROJECT_DIR   project root (default: cwd)
#   AGENT_NAME    agent to use (default: sisyphus)
#   TIMEOUT       max seconds (default: 28800 = 8h)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

# ── Args ────────────────────────────────────────────────────────────────────
TASK_FILE="${1:?Usage: $0 <plan-file> [session-id]}"
SESSION_ID="${2:-}"
: "${TIMEOUT:=28800}"  # 8 hours

# Resolve absolute path
if [[ -f "$PROJECT_DIR/$TASK_FILE" ]]; then
    TASK_FILE_ABS="$PROJECT_DIR/$TASK_FILE"
elif [[ -f "$TASK_FILE" ]]; then
    TASK_FILE_ABS="$(cd "$(dirname "$TASK_FILE")" && pwd)/$(basename "$TASK_FILE")"
else
    err "Task file not found: $TASK_FILE"
    exit 1
fi

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/run_$(ts_slug).log"

# ── Print header ────────────────────────────────────────────────────────────
{
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  opencode-autopilot — Single Shot                       ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo "  Task:     $TASK_FILE_ABS"
    echo "  Session:  ${SESSION_ID:-(new)}"
    echo "  Timeout:  ${TIMEOUT}s ($((TIMEOUT / 3600))h)"
    echo "  Log:      $LOG_FILE"
    echo ""
} | tee "$LOG_FILE"

# ── Build command ───────────────────────────────────────────────────────────
CMD=(
    opencode run
    --dangerously-skip-permissions
    --file "$TASK_FILE_ABS"
    --format json
    --dir "$PROJECT_DIR"
    --print-logs
    --log-level WARN
    "Execute the attached task plan autonomously. Complete all remaining unchecked checkboxes."
)

if [[ -n "$SESSION_ID" ]]; then
    CMD+=(--continue --session "$SESSION_ID")
    info "Continuing session: $SESSION_ID" | tee -a "$LOG_FILE"
fi

# ── Execute ─────────────────────────────────────────────────────────────────
info "Starting execution..." | tee -a "$LOG_FILE"
info "Command: opencode run --file $(basename "$TASK_FILE_ABS") ..." | tee -a "$LOG_FILE"

# Notify start
notify "start" "Task Started" "Plan: $(basename "$TASK_FILE_ABS")\\nTimeout: ${TIMEOUT}s"

set +e
timeout "$TIMEOUT" "${CMD[@]}" >> "$LOG_FILE" 2>&1
EXIT_CODE=$?
set -e

echo "" >> "$LOG_FILE"
info "Exit code: $EXIT_CODE" | tee -a "$LOG_FILE"

# ── Extract session ID for continuation ────────────────────────────────────
# Try both 'sessionID' and 'session_id' JSON keys
SESSION_MATCH=$(grep -oE '"sessionI[Dd]":"ses_[^"]+"' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d'"' -f4)
if [[ -z "$SESSION_MATCH" ]]; then
    SESSION_MATCH=$(grep -oE '"session_id":"ses_[^"]+"' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d'"' -f4)
fi

if [[ -n "$SESSION_MATCH" ]]; then
    echo ""
    info "Session ID for continuation: $SESSION_MATCH"
    info "Next: $0 $TASK_FILE $SESSION_MATCH"
fi | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"
echo "=== Log saved: $LOG_FILE ===" | tee -a "$LOG_FILE"

# ── Notify result ────────────────────────────────────────────────────────────
if [[ "$EXIT_CODE" -eq 0 ]]; then
    notify "complete" "Task Completed" "Plan: $(basename "$TASK_FILE_ABS")\\nSession: ${SESSION_MATCH:-(none)}"
else
    notify "error" "Task Failed (exit $EXIT_CODE)" \
        "Plan: $(basename "$TASK_FILE_ABS")\\nExit code: ${EXIT_CODE}\\nSession: ${SESSION_MATCH:-(none)}"
fi

exit $EXIT_CODE
