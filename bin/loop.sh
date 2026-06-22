#!/bin/bash
# ============================================================================
# opencode-autopilot — Multi-cycle execution loop
#
# Runs opencode in a loop, continuing the same session across cycles.
# Automatically retries on timeout and detects stalled tasks.
# Designed for overnight / long-running autonomous execution.
#
# Usage:
#   ./bin/loop.sh <plan-file>
#   PROJECT_DIR=/my/project CYCLE_TIMEOUT=7200 ./bin/loop.sh plan.md
#   ./bin/loop.sh --detach plan.md                # background with nohup
#
# Environment (see config.sh for all options):
#   PROJECT_DIR     project root (default: cwd)
#   CYCLE_TIMEOUT   seconds per cycle (default: 3600)
#   AGENT_NAME      agent to use (default: sisyphus)
#   SKIP_STUCK      true to skip stalled tasks (default: false)
#   DETACH          true to background immediately (default: false)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

# ── Parse --detach flag ────────────────────────────────────────────────────
DETACH_FLAG=false
for arg in "$@"; do
    case "$arg" in
        --detach) DETACH_FLAG=true; shift ;;
        --help|-h) 
            head -30 "$0" | grep -A2 '^#'
            exit 0
            ;;
    esac
done

PLAN_FILE="${1:?Usage: $0 [--detach] <plan-file>}"

# Resolve plan path
if [[ -f "$PROJECT_DIR/$PLAN_FILE" ]]; then
    PLAN_ABS="$PROJECT_DIR/$PLAN_FILE"
elif [[ -f "$PLAN_FILE" ]]; then
    PLAN_ABS="$(cd "$(dirname "$PLAN_FILE")" && pwd)/$(basename "$PLAN_FILE")"
else
    err "Plan file not found: $PLAN_FILE"
    exit 1
fi

# ── Detach mode ─────────────────────────────────────────────────────────────
if $DETACH_FLAG; then
    nohup "$0" "$PLAN_FILE" >> "$OMO_DIR/autopilot-daemon.log" 2>&1 &
    PID=$!
    info "Detached loop as PID $PID"
    info "Log: $OMO_DIR/autopilot-daemon.log"
    info "Monitor: tail -f $OMO_DIR/autopilot-daemon.log"
    exit 0
fi

# ── Setup logging ──────────────────────────────────────────────────────────
TIMESTAMP=$(ts_slug)
mkdir -p "$LOG_DIR" "$EVIDENCE_DIR" "$CONTINUATION_DIR"
MAIN_LOG="$LOG_DIR/loop_$TIMESTAMP.log"

# Tee all output to log AND terminal
exec > >(tee -a "$MAIN_LOG") 2>&1

# ── Header ──────────────────────────────────────────────────────────────────
header "AUTOPILOT STARTED"
info  "Plan:     $PLAN_ABS"
info  "Timeout:  ${CYCLE_TIMEOUT}s ($((CYCLE_TIMEOUT / 60))min)"
info  "Agent:    $AGENT_NAME"
info  "Log:      $MAIN_LOG"
info  "Stuck:    $( $SKIP_STUCK && echo 'skip after $STUCK_THRESHOLD cycles' || echo 'disabled' )"

# ── State ───────────────────────────────────────────────────────────────────
SESSION_ID=""
FIRST_RUN=true
PREV_REMAINING=-1
STALL_COUNT=0

# ── Main loop ───────────────────────────────────────────────────────────────
for i in $(seq 1 $MAX_ITERATIONS); do
    REMAINING=$(count_remaining "$PLAN_ABS")
    COMPLETED=$(count_completed "$PLAN_ABS")
    TOTAL=$((COMPLETED + REMAINING))

    header "CYCLE $i  —  $COMPLETED/$TOTAL done, $REMAINING remaining"
    echo "  Time:     $(timestamp)"
    echo "  Uptime:   $( uptime -p 2>/dev/null || uptime )"
    echo "  Memory:   $( free -h | grep Mem | awk '{print $3" / "$2}' )"
    echo "  Disk:     $( df -h "$PROJECT_DIR" | tail -1 | awk '{print $3" / "$2" ("$5")"}' )"

    # ── Completion check ───────────────────────────────────────────────────
    if [[ "$REMAINING" -eq 0 ]]; then
        echo ""
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  🎉 ALL TASKS COMPLETE!  $COMPLETED/$TOTAL                    ║"
        echo "╚══════════════════════════════════════════════════════════╝"
        info "Completed at: $(timestamp)"

        # Update boulder
        if [[ -f "$BOULDER_FILE" ]]; then
            python3 -c "
import json
with open('$BOULDER_FILE') as f: b = json.load(f)
work = b.get('works', {}).get('integration-refactor', {})
work['status'] = 'completed'
if '$SESSION_ID': work.setdefault('session_ids', []).append('codex:$SESSION_ID')
print(json.dumps(b, indent=2))
" > "${BOULDER_FILE}.tmp" && mv "${BOULDER_FILE}.tmp" "$BOULDER_FILE" 2>/dev/null || true
        fi

        exit 0
    fi

    # ── Stuck detection ────────────────────────────────────────────────────
    if [[ "$PREV_REMAINING" -ge 0 ]] && [[ "$REMAINING" -eq "$PREV_REMAINING" ]]; then
        STALL_COUNT=$((STALL_COUNT + 1))
        if [[ "$STALL_COUNT" -ge "$STUCK_THRESHOLD" ]]; then
            warn "No progress for $STALL_COUNT cycles (remaining=$REMAINING)."
            if $SKIP_STUCK; then
                warn "Skipping first unchecked task and continuing..."
                # Find first unchecked line number
                FIRST_UNCHECKED=$(grep -n '^- \[ \]' "$PLAN_ABS" | head -1 | cut -d: -f1)
                if [[ -n "$FIRST_UNCHECKED" ]]; then
                    sed -i "${FIRST_UNCHECKED}s/^- \[ \]/- [x] **STUCK-SKIPPED**/" "$PLAN_ABS"
                    info "Skipped task at line $FIRST_UNCHECKED"
                fi
            else
                warn "Remaining stuck at $REMAINING. Set SKIP_STUCK=true or investigate."
            fi
        fi
    else
        STALL_COUNT=0
    fi
    PREV_REMAINING=$REMAINING

    # ── Build command ─────────────────────────────────────────────────────
    CMD=(
        opencode run
        --dangerously-skip-permissions
        --file "$PLAN_ABS"
        --format json
        --dir "$PROJECT_DIR"
        --print-logs
        --log-level WARN
    )

    if [[ -n "$SESSION_ID" ]]; then
        CMD+=(--continue --session "$SESSION_ID")
        info "Continuing session: $SESSION_ID"
    else
        info "Starting new session..."
    fi

    CMD+=("Execute the attached task plan autonomously. Continue from where you left off. Complete all remaining unchecked checkboxes ('- [ ]'). Do NOT stop until ALL tasks are done or the plan has no more unchecked boxes.")

    # ── Execute cycle ─────────────────────────────────────────────────────
    CYCLE_LOG="$LOG_DIR/cycle_${TIMESTAMP}_${i}.log"
    EXIT_CODE=0

    # We MUST avoid set -e killing the script on timeout (exit 124)
    set +e
    timeout "$CYCLE_TIMEOUT" "${CMD[@]}" > "$CYCLE_LOG" 2>&1
    EXIT_CODE=$?
    set -e

    echo "  Cycle exit code: $EXIT_CODE"

    # ── Handle exit codes ─────────────────────────────────────────────────
    case "$EXIT_CODE" in
        0)
            ok "Cycle $i completed successfully."
            ;;
        124)
            warn "Cycle $i timed out after ${CYCLE_TIMEOUT}s."
            # Capture session from this cycle's log for next cycle
            ;;
        130)
            warn "Cycle $i interrupted (SIGINT)."
            ;;
        143)
            warn "Cycle $i killed (SIGTERM)."
            ;;
        *)
            warn "Cycle $i exited with code $EXIT_CODE — continuing..."
            ;;
    esac

    # ── Extract session ID (always, not just first run) ───────────────────
    # opencode uses 'sessionID' in step_start JSON lines
    NEW_SESSION=$(grep -oE '"sessionID":"ses_[^"]+"' "$CYCLE_LOG" 2>/dev/null | head -1 | cut -d'"' -f4)
    if [[ -z "$NEW_SESSION" ]]; then
        # Fallback: 'session_id' key
        NEW_SESSION=$(grep -oE '"session_id":"ses_[^"]+"' "$CYCLE_LOG" 2>/dev/null | tail -1 | cut -d'"' -f4)
    fi
    if [[ -z "$NEW_SESSION" ]]; then
        # Fallback: inside run-continuation JSON files
        NEW_SESSION=$(ls -t "$CONTINUATION_DIR"/*.json 2>/dev/null | head -1 | xargs -I{} python3 -c "import json; print(json.load(open('{}')).get('sessionID',''))" 2>/dev/null)
    fi

    if [[ -n "$NEW_SESSION" ]]; then
        SESSION_ID="$NEW_SESSION"
        if $FIRST_RUN; then
            info "Session captured: $SESSION_ID"
            FIRST_RUN=false
        fi
        # Persist to boulder
        mkdir -p "$(dirname "$BOULDER_FILE")"
        python3 -c "
import json, os
b = {}
if os.path.exists('$BOULDER_FILE'):
    with open('$BOULDER_FILE') as f: b = json.load(f)
b.setdefault('works', {}).setdefault('integration-refactor', {})
w = b['works']['integration-refactor']
w['status'] = 'active'
w['active_plan'] = '$PLAN_FILE'
sessions = w.setdefault('session_ids', [])
sid = 'codex:$SESSION_ID'
if sid not in sessions:
    sessions.append(sid)
w['last_cycle'] = $i
w['completed'] = $COMPLETED
w['remaining'] = $REMAINING
w['updated_at'] = '$(timestamp)'
with open('$BOULDER_FILE', 'w') as f: json.dump(b, f, indent=2)
" 2>/dev/null || true
    fi

    # ── Pause between cycles ──────────────────────────────────────────────
    if [[ "$EXIT_CODE" -ne 124 ]]; then
        # Non-timeout exit: give a brief pause before retry
        sleep "$SLEEP_BETWEEN"
    fi
    # On timeout: restart immediately (no pause needed)
done

# ── Exhausted iterations ──────────────────────────────────────────────────
err "Reached $MAX_ITERATIONS cycles without completing all tasks."
err "Last state: $(count_completed "$PLAN_ABS") done, $(count_remaining "$PLAN_ABS") remaining"
exit 1
