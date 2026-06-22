#!/bin/bash
# ============================================================================
# opencode-autopilot — Self-heal: detect, diagnose, fix, and commit
#
# Scans the autopilot infrastructure for abnormalities and fixes them:
#   • Process health — loop dead but tasks remain?
#   • Log health — cycle crashes, error patterns, unexpected exit codes
#   • Script integrity — syntax errors, missing files, wrong permissions
#   • State consistency — boulder vs reality, stale sessions
#   • Resource health — disk full? OOM risk?
#
# Auto-fixes simple issues (permissions, stale state, oversized logs).
# Escalates complex issues to Sisyphus for analysis + fix + commit.
#
# Usage:
#   ./bin/self-heal.sh                    # full check + auto-fix + optional Sisyphus
#   ./bin/self-heal.sh --diagnose         # check only, no fixes (zero token)
#   ./bin/self-heal.sh --fix-only         # auto-fix known issues only, no Sisyphus
#   ./bin/self-heal.sh --force-analyze    # always run Sisyphus analysis
#
# Exit codes:
#   0 = healthy (no issues found or all fixed)
#   1 = issues found but auto-fixable
#   2 = issues require Sisyphus analysis (not run)
#   3 = critical — cannot auto-recover
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

# ── Flags ───────────────────────────────────────────────────────────────────
DIAGNOSE_ONLY=false
FIX_ONLY=false
FORCE_ANALYZE=false
for arg in "$@"; do
    case "$arg" in
        --diagnose|-d) DIAGNOSE_ONLY=true ;;
        --fix-only|-f)  FIX_ONLY=true ;;
        --force-analyze|-a) FORCE_ANALYZE=true ;;
    esac
done

TODAY=$(date '+%Y%m%d')
HEALTH_LOG="$OMO_DIR/health/health-${TODAY}.log"
mkdir -p "$OMO_DIR/health"

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE 1 — Diagnostics (bash only, zero tokens)
# ═══════════════════════════════════════════════════════════════════════════

header "SELF-HEAL: Diagnostics"

DIAG_FILE="$OMO_DIR/health/diagnosis-${TODAY}.txt"
ISSUES=0         # total issue count
CRITICAL=0       # critical (needs human)
AUTO_FIXABLE=0   # can be fixed by bash
NEEDS_SISYPHUS=0 # needs Sisyphus analysis

{
    echo "=========================================="
    echo "  SELF-HEAL DIAGNOSIS — $(date '+%Y-%m-%d %H:%M')"
    echo "=========================================="
    echo ""
} > "$DIAG_FILE"

# ── 1a. Process health ──────────────────────────────────────────────────────
echo "── 1a. Process Health ──" >> "$DIAG_FILE"
LOOP_PID=""
LOOP_PID=$(ps aux | grep "opencode-autopilot/bin/loop.sh" | grep -v grep | awk '{print $2}' | head -1) || true
OPENCODE_PID=$(ps aux | grep "opencode run" | grep -v grep | awk '{print $2}' | head -1) || true

REMAINING=$(count_remaining "$OMO_DIR/plans"/*.md 2>/dev/null || echo "0")
COMPLETED=$(count_completed "$OMO_DIR/plans"/*.md 2>/dev/null || echo "0")

if [[ -n "$LOOP_PID" ]]; then
    echo "  [OK]  Loop running (PID $LOOP_PID)" >> "$DIAG_FILE"
else
    if [[ "$REMAINING" -gt 0 ]]; then
        echo "  [ABNORMAL] Loop NOT running but $REMAINING tasks remain!" >> "$DIAG_FILE"
        ISSUES=$((ISSUES + 1))
        NEEDS_SISYPHUS=$((NEEDS_SISYPHUS + 1))
    else
        echo "  [INFO] Loop not running (no pending tasks — OK)" >> "$DIAG_FILE"
    fi
fi

if [[ -n "$OPENCODE_PID" ]]; then
    echo "  [OK]  opencode run in progress (PID $OPENCODE_PID)" >> "$DIAG_FILE"
else
    echo "  [INFO] No opencode run in progress" >> "$DIAG_FILE"
fi
echo "" >> "$DIAG_FILE"

# ── 1b. Log health ─────────────────────────────────────────────────────────
echo "── 1b. Log Health ──" >> "$DIAG_FILE"

LATEST_CYCLE=$(ls -t "$LOG_DIR"/cycle_*.log 2>/dev/null | head -1)
LATEST_LOOP=$(ls -t "$LOG_DIR"/loop_*.log 2>/dev/null | head -1)

if [[ -n "$LATEST_CYCLE" ]]; then
    # Check for abnormal exit codes in the log (non-0, non-124)
    ABNORMAL_EXITS=$(grep -oE '"exit_code":([0-9]+)' "$LATEST_CYCLE" 2>/dev/null | grep -v ':0$' | grep -v ':124$' || true)
    if [[ -n "$ABNORMAL_EXITS" ]]; then
        echo "  [ABNORMAL] Abnormal exit codes found:" >> "$DIAG_FILE"
        echo "$ABNORMAL_EXITS" | sed 's/^/    /' >> "$DIAG_FILE"
        ISSUES=$((ISSUES + 1))
        NEEDS_SISYPHUS=$((NEEDS_SISYPHUS + 1))
    fi

    # Check for ERROR or WARN patterns (agent issues)
    ERROR_COUNT=$(grep -ci '"level":"error"\|"level":"fatal"' "$LATEST_CYCLE" 2>/dev/null || true)
    WARN_COUNT=$(grep -ci '"level":"warn"' "$LATEST_CYCLE" 2>/dev/null || true)
    if [[ "$ERROR_COUNT" -gt 0 ]]; then
        echo "  [ABNORMAL] $ERROR_COUNT error(s) in latest cycle log" >> "$DIAG_FILE"
        grep -i '"level":"error"\|"level":"fatal"' "$LATEST_CYCLE" 2>/dev/null | tail -3 | sed 's/^/    /' >> "$DIAG_FILE"
        ISSUES=$((ISSUES + 1))
        NEEDS_SISYPHUS=$((NEEDS_SISYPHUS + 1))
    fi
    if [[ "$WARN_COUNT" -gt 0 ]]; then
        echo "  [WARN] $WARN_COUNT warning(s) in latest cycle log" >> "$DIAG_FILE"
        grep -i '"level":"warn"' "$LATEST_CYCLE" 2>/dev/null | tail -3 | sed 's/^/    /' >> "$DIAG_FILE"
    fi

    # Check for "agent not found" fallback
    if grep -qi "agent.*not found\|falling back" "$LATEST_CYCLE" 2>/dev/null; then
        echo "  [ABNORMAL] Agent fallback detected (agent config issue)" >> "$DIAG_FILE"
        grep -i "agent.*not found\|falling back" "$LATEST_CYCLE" 2>/dev/null | head -2 | sed 's/^/    /' >> "$DIAG_FILE"
        ISSUES=$((ISSUES + 1))
        NEEDS_SISYPHUS=$((NEEDS_SISYPHUS + 1))
    fi

    # Check for SIGTERM/SIGKILL/OOM
    if grep -qi "killed\|SIGTERM\|SIGKILL\|OOM\|out of memory" "$LATEST_CYCLE" 2>/dev/null; then
        echo "  [ABNORMAL] Process was killed (OOM/SIGTERM?)" >> "$DIAG_FILE"
        ISSUES=$((ISSUES + 1))
        NEEDS_SISYPHUS=$((NEEDS_SISYPHUS + 1))
    fi

    # Log size check
    LOG_SIZE=$(stat -c%s "$LATEST_CYCLE" 2>/dev/null || echo 0)
    if [[ "$LOG_SIZE" -gt $((50 * 1024 * 1024)) ]]; then
        echo "  [WARN] Cycle log is large ($((LOG_SIZE / 1024 / 1024)) MB)" >> "$DIAG_FILE"
    fi

    echo "  [INFO] Latest cycle: $(basename "$LATEST_CYCLE")" >> "$DIAG_FILE"
    echo "  [INFO] Errors: $ERROR_COUNT, Warnings: $WARN_COUNT" >> "$DIAG_FILE"
else
    echo "  [INFO] No cycle logs found" >> "$DIAG_FILE"
fi
echo "" >> "$DIAG_FILE"

# ── 1c. Script integrity ──────────────────────────────────────────────────
echo "── 1c. Script Integrity ──" >> "$DIAG_FILE"

# Check all .sh files for syntax errors
SH_FILES=0
SH_ERRORS=0
while IFS= read -r -d '' shfile; do
    SH_FILES=$((SH_FILES + 1))
    if ! bash -n "$shfile" 2>/dev/null; then
        echo "  [ERROR] Syntax error: $shfile" >> "$DIAG_FILE"
        SH_ERRORS=$((SH_ERRORS + 1))
        ISSUES=$((ISSUES + 1))
        NEEDS_SISYPHUS=$((NEEDS_SISYPHUS + 1))
    fi
done < <(find "$SCRIPT_DIR" -name "*.sh" -print0 2>/dev/null)

if [[ "$SH_ERRORS" -eq 0 ]]; then
    echo "  [OK]  All $SH_FILES .sh files have valid syntax" >> "$DIAG_FILE"
fi

# Check executable bits
NOT_EXEC=0
while IFS= read -r -d '' shfile; do
    [[ -x "$shfile" ]] || NOT_EXEC=$((NOT_EXEC + 1))
done < <(find "$SCRIPT_DIR" -name "*.sh" -print0 2>/dev/null)
if [[ "$NOT_EXEC" -gt 0 ]]; then
    echo "  [FIX] $NOT_EXEC script(s) missing executable bit" >> "$DIAG_FILE"
    AUTO_FIXABLE=$((AUTO_FIXABLE + 1))
    # Auto-fix
    find "$SCRIPT_DIR" -name "*.sh" ! -executable -exec chmod +x {} \; 2>/dev/null
    echo "  → Fixed: chmod +x applied" >> "$DIAG_FILE"
fi

# Check required files exist
MISSING_FILES=0
for req in loop.sh run.sh preflight.sh status.sh config.sh; do
    if [[ ! -f "$SCRIPT_DIR/$req" ]] && [[ ! -f "$SCRIPT_DIR/../$req" ]] && [[ ! -f "$SCRIPT_DIR/../bin/$req" ]]; then
        # Check all possible locations
        if [[ ! -f "$SCRIPT_DIR/../$req" ]] && [[ ! -f "$SCRIPT_DIR/$req" ]]; then
            echo "  [CRITICAL] Missing required file: $req" >> "$DIAG_FILE"
            MISSING_FILES=$((MISSING_FILES + 1))
            CRITICAL=$((CRITICAL + 1))
        fi
    fi
done
if [[ "$MISSING_FILES" -eq 0 ]]; then
    echo "  [OK]  All required files present" >> "$DIAG_FILE"
fi

echo "" >> "$DIAG_FILE"

# ── 1d. State consistency ──────────────────────────────────────────────────
echo "── 1d. State Consistency ──" >> "$DIAG_FILE"

if [[ -f "$BOULDER_FILE" ]]; then
    BOULDER_STATUS=$(python3 -c "import json; print(json.load(open('$BOULDER_FILE')).get('works',{}).get('integration-refactor',{}).get('status','unknown'))" 2>/dev/null || echo "parse-error")
    
    if [[ "$BOULDER_STATUS" == "active" ]]; then
        if [[ -z "$LOOP_PID" ]] && [[ "$REMAINING" -gt 0 ]]; then
            echo "  [ABNORMAL] Boulder says 'active' but no loop process running" >> "$DIAG_FILE"
            ISSUES=$((ISSUES + 1))
            NEEDS_SISYPHUS=$((NEEDS_SISYPHUS + 1))
        else
            echo "  [OK]  Boulder state consistent with reality" >> "$DIAG_FILE"
        fi
    elif [[ "$BOULDER_STATUS" == "completed" ]]; then
        echo "  [OK]  Boulder reports 'completed'" >> "$DIAG_FILE"
    else
        echo "  [INFO] Boulder status: $BOULDER_STATUS" >> "$DIAG_FILE"
    fi
else
    echo "  [INFO] No boulder file (fresh start)" >> "$DIAG_FILE"
fi

# Check for stale continuation files (older than 7 days)
STALE_SESSIONS=0
for f in "$CONTINUATION_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if [[ $(find "$f" -mtime +7 -print 2>/dev/null) ]]; then
        STALE_SESSIONS=$((STALE_SESSIONS + 1))
    fi
done
if [[ "$STALE_SESSIONS" -gt 5 ]]; then
    echo "  [WARN] $STALE_SESSIONS stale session files (>7 days old)" >> "$DIAG_FILE"
fi
echo "" >> "$DIAG_FILE"

# ── 1e. Resource health ────────────────────────────────────────────────────
echo "── 1e. Resource Health ──" >> "$DIAG_FILE"

# Disk
DISK_PCT=$(df "$PROJECT_DIR" | tail -1 | awk '{print $5}' | sed 's/%//')
DISK_AVAIL=$(df -h "$PROJECT_DIR" | tail -1 | awk '{print $4}')
if [[ "$DISK_PCT" -gt 90 ]]; then
    echo "  [CRITICAL] Disk ${DISK_PCT}% full (${DISK_AVAIL} free)" >> "$DIAG_FILE"
    CRITICAL=$((CRITICAL + 1))
elif [[ "$DISK_PCT" -gt 80 ]]; then
    echo "  [WARN] Disk ${DISK_PCT}% full (${DISK_AVAIL} free)" >> "$DIAG_FILE"
else
    echo "  [OK]  Disk ${DISK_PCT}% used (${DISK_AVAIL} free)" >> "$DIAG_FILE"
fi

# Memory
MEM_PCT=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
MEM_AVAIL=$(free -h | grep Mem | awk '{print $7}')
if [[ "$MEM_PCT" -gt 90 ]]; then
    echo "  [CRITICAL] Memory ${MEM_PCT}% used (${MEM_AVAIL} available)" >> "$DIAG_FILE"
    CRITICAL=$((CRITICAL + 1))
elif [[ "$MEM_PCT" -gt 80 ]]; then
    echo "  [WARN] Memory ${MEM_PCT}% used (${MEM_AVAIL} available)" >> "$DIAG_FILE"
else
    echo "  [OK]  Memory ${MEM_PCT}% used (${MEM_AVAIL} available)" >> "$DIAG_FILE"
fi

# Log directory size
LOG_DIR_SIZE=$(du -sh "$LOG_DIR" 2>/dev/null | awk '{print $1}')
echo "  [INFO] Log directory: $LOG_DIR_SIZE" >> "$DIAG_FILE"
echo "" >> "$DIAG_FILE"

# ── Summary counts ─────────────────────────────────────────────────────────
{
    echo "── Summary ──"
    echo "  Total issues: $ISSUES"
    echo "  Auto-fixable: $AUTO_FIXABLE"
    echo "  Needs Sisyphus: $NEEDS_SISYPHUS"
    echo "  Critical: $CRITICAL"
    echo ""
    echo "HEALTH_ISSUES=$ISSUES"
    echo "AUTO_FIXABLE=$AUTO_FIXABLE"
    echo "NEEDS_SISYPHUS=$NEEDS_SISYPHUS"
    echo "CRITICAL=$CRITICAL"
} >> "$DIAG_FILE"

cp "$DIAG_FILE" "$HEALTH_LOG"
cat "$DIAG_FILE"

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE 2 — Auto-fix (bash, for known simple issues)
# ═══════════════════════════════════════════════════════════════════════════

if ! $DIAGNOSE_ONLY && [[ "$AUTO_FIXABLE" -gt 0 || "$FORCE_ANALYZE" == false ]]; then
    # Auto-fixes already applied inline above (chmod +x)
    # Future: add log rotation, stale session cleanup
    info "Auto-fixes applied during diagnostics."
fi

if $DIAGNOSE_ONLY || $FIX_ONLY; then
    echo ""
    if [[ "$ISSUES" -eq 0 ]]; then
        ok "Self-heal: healthy — no issues found."
        exit 0
    elif [[ "$AUTO_FIXABLE" -gt 0 ]]; then
        ok "Self-heal: $AUTO_FIXABLE issue(s) auto-fixed."
        info "Remaining issues needing Sisyphus: $NEEDS_SISYPHUS"
        info "Run without --fix-only to engage Sisyphus analysis."
        exit 1
    else
        warn "Self-heal: $ISSUES issue(s) found, $NEEDS_SISYPHUS need Sisyphus analysis."
        exit 2
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
#  PHASE 3 — Sisyphus analysis + fix + commit (only if needed)
# ═══════════════════════════════════════════════════════════════════════════

if [[ "$ISSUES" -eq 0 ]] && ! $FORCE_ANALYZE; then
    ok "Self-heal: healthy."
    exit 0
fi

if [[ "$CRITICAL" -gt 0 ]]; then
    err "$CRITICAL critical issue(s) — cannot auto-recover. Manual intervention needed."
    err "See: $HEALTH_LOG"
    exit 3
fi

# Only proceed to Sisyphus if there are issues it needs to handle
if [[ "$NEEDS_SISYPHUS" -eq 0 ]] && ! $FORCE_ANALYZE; then
    ok "Self-heal: all issues auto-fixed."
    exit 0
fi

header "SELF-HEAL: Sisyphus Analysis + Fix"

SISYPHUS_PROMPT=$(cat << PROMPT
You are Sisyphus, the autopilot maintainer. Your job is to DIAGNOSE and FIX issues in the autopilot scripts.

## CONSTRAINTS
- You MAY read and edit files in the opencode-autopilot project directory.
- You MAY run bash commands to test fixes.
- You MUST NOT explore or modify other projects.
- Your scope is LIMITED to the autopilot infrastructure scripts.

## DIAGNOSIS REPORT
$(cat "$DIAG_FILE")

## TASKS (in order)
1. Analyze each issue in the diagnosis report.
2. For each issue:
   a. Determine root cause
   b. Fix the script or configuration
   c. Verify the fix (bash -n for syntax, test with --status flag)
3. After all fixes:
   a. Run ./bin/self-heal.sh --diagnose to verify fixes resolved the issues
   b. Run git status to see changed files
   c. Commit with a descriptive message
   d. Push to origin

## WORKFLOW REQUIREMENTS
- Every fix must be verified before committing.
- Write clear commit messages explaining WHAT was broken and HOW it was fixed.
- If you cannot fix an issue, explain why and what information is needed.

Begin diagnosis.
PROMPT
)

opencode run \
    --agent "$AGENT_NAME" \
    --dangerously-skip-permissions \
    --file "$HEALTH_LOG" \
    --format json \
    --dir "$SCRIPT_DIR/.." \
    --print-logs \
    --log-level WARN \
    "$SISYPHUS_PROMPT"

EXIT_CODE=$?
echo ""
if [[ "$EXIT_CODE" -eq 0 ]]; then
    ok "Self-heal: Sisyphus completed fixes successfully."
else
    warn "Self-heal: Sisyphus exited with code $EXIT_CODE — review logs."
fi

exit $EXIT_CODE
