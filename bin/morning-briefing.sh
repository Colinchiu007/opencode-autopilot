#!/bin/bash
# ============================================================================
# opencode-autopilot — Morning Briefing
#
# Scans project state and produces one of two outcomes:
#   A) A plan file with pending work → ready for start-day.sh
#   B) A completion report (nothing pending)
#
# Token-efficient design:
#   Phase 1 = pure bash (zero token cost) — scans plans, boulder, git, metadata
#   Phase 2 = structured summary passed to sisyphus with strict scope bounds
#             (NO codebase exploration, NO task execution — analysis only)
#
# Usage:
#   ./bin/morning-briefing.sh                          # runs and produces output
#   ./bin/morning-briefing.sh --status                 # just show status, skip analysis
#   PROJECT_DIR=/srv/projects ./bin/morning-briefing.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

ONLY_STATUS=false
for arg in "$@"; do
    [[ "$arg" == "--status" || "$arg" == "-s" ]] && ONLY_STATUS=true
done

TODAY=$(date '+%Y%m%d')
SUMMARY_FILE="$OMO_DIR/briefing/summary-${TODAY}.txt"
PLAN_OUT="$OMO_DIR/plans/${TODAY}.md"
REPORT_DIR="$OMO_DIR/completion"
mkdir -p "$OMO_DIR/briefing" "$OMO_DIR/plans" "$REPORT_DIR"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  PHASE 1 — Bash scan (zero tokens)                                      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

header "PHASE 1: Scanning project state"

# ── 1a. Boulder state ──────────────────────────────────────────────────────
BOULDER_SUMMARY="(no boulder.json)"
if [[ -f "$BOULDER_FILE" ]]; then
    BOULDER_SUMMARY=$(python3 -c "
import json
with open('$BOULDER_FILE') as f: b = json.load(f)
out = []
for wid, w in b.get('works', {}).items():
    out.append(f'  Work: {wid}')
    out.append(f'  Status: {w.get(\"status\", \"?\")}')
    out.append(f'  Sessions: {len(w.get(\"session_ids\", []))}')
    out.append(f'  Progress: {w.get(\"completed\", \"?\")} done, {w.get(\"remaining\", \"?\")} remaining')
    out.append(f'  Last cycle: {w.get(\"last_cycle\", \"?\")}')
    out.append(f'  Updated: {w.get(\"updated_at\", \"?\")}')
print('\n'.join(out))
" 2>/dev/null || echo "  (parse error)")
fi

# ── 1b. Plan checkboxes (all .omo/plans/*.md) ──────────────────────────────
PLANS_SUMMARY=""
PLANS_FOUND=0
PENDING_TOTAL=0
DONE_TOTAL=0
for pf in "$OMO_DIR/plans"/*.md; do
    [[ -f "$pf" ]] || continue
    NAME=$(basename "$pf")
    REM=$(count_remaining "$pf")
    DONE=$(count_completed "$pf")
    TOTAL=$((REM + DONE))
    PLANS_FOUND=$((PLANS_FOUND + 1))
    PENDING_TOTAL=$((PENDING_TOTAL + REM))
    DONE_TOTAL=$((DONE_TOTAL + DONE))

    # Get first line of the plan (title)
    TITLE=$(head -1 "$pf" | sed 's/^# //' | sed 's/^#//')
    PLANS_SUMMARY+="  • $NAME — $DONE/$TOTAL done${TITLE:+ ($TITLE)}
"
    # List pending tasks if any
    if [[ "$REM" -gt 0 ]]; then
        PENDING_TASKS=$(grep -n '^- \[ \]' "$pf" | head -5 | sed 's/^/      /')
        PLANS_SUMMARY+="$PENDING_TASKS
"
        if [[ "$REM" -gt 5 ]]; then
            PLANS_SUMMARY+="      ... and $((REM - 5)) more pending
"
        fi
    fi
done

# ── 1c. Project metadata ──────────────────────────────────────────────────
PROJECTS_SUMMARY=""
for pm in "$PROJECT_DIR"/*/.project-meta.json; do
    [[ -f "$pm" ]] || continue
    PROJ=$(basename "$(dirname "$pm")")
    CRIT=$(python3 -c "import json; print(', '.join(json.load(open('$pm')).get('critical_paths', [])))" 2>/dev/null)
    PROJECTS_SUMMARY+="  • $PROJ → $CRIT
"
done

# ── 1d. Git state ─────────────────────────────────────────────────────────
GIT_SUMMARY=""
cd "$PROJECT_DIR"
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "(not a git repo)")
GIT_DIRTY=$(git status --short 2>/dev/null | wc -l)
GIT_AHEAD=$(git log --oneline @{u}.. 2>/dev/null | wc -l || echo 0)
GIT_LOG=$(git log --oneline -10 2>/dev/null || echo "(no commits)")

GIT_SUM+="  Branch: $GIT_BRANCH
  Uncommitted: $GIT_DIRTY file(s)
  Ahead of remote: $GIT_AHEAD commit(s)
  Recent commits:
"
while IFS= read -r line; do
    GIT_SUM+="    $line
"
done <<< "$GIT_LOG"

# ── 1e. Gather evidence files ──────────────────────────────────────────────
EVIDENCE_COUNT=0
if [[ -d "$EVIDENCE_DIR" ]]; then
    EVIDENCE_COUNT=$(find "$EVIDENCE_DIR" -name "*.log" 2>/dev/null | wc -l)
fi

# ── 1f. OpenSpec changes ──────────────────────────────────────────────────
OPENSPEC_SUMMARY=""
if command -v openspec &>/dev/null; then
    OPENSPEC_OUTPUT=$(openspec list --json 2>/dev/null || echo '{"changes":[]}')
    OPENSPEC_COUNT=$(echo "$OPENSPEC_OUTPUT" | python3 -c "import sys,json; data=json.load(sys.stdin); print(len(data.get('changes',[])))" 2>/dev/null || echo 0)
    if [[ "$OPENSPEC_COUNT" -gt 0 ]]; then
        OPENSPEC_DETAIL=$(echo "$OPENSPEC_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('changes', []):
    name = c.get('name', '?')
    stat = c.get('status', '?')
    print(f'  • {name} ({stat})')
" 2>/dev/null)
        OPENSPEC_SUMMARY+="  Active changes: $OPENSPEC_COUNT
$OPENSPEC_DETAIL"
    else
        OPENSPEC_SUMMARY="  No active OpenSpec changes.
"
    fi
else
    OPENSPEC_SUMMARY="  openspec CLI not found.
"
fi

# ── Write summary file ────────────────────────────────────────────────────
{
    echo "=========================================="
    echo "  PROJECT BRIEFING — $(date '+%Y-%m-%d %H:%M')"
    echo "=========================================="
    echo ""
    echo "── Boulder State ──"
    echo "$BOULDER_SUMMARY"
    echo ""
    echo "── Plans ($PLANS_FOUND found, $PENDING_TOTAL pending) ──"
    echo "$PLANS_SUMMARY"
    echo "  Total: $DONE_TOTAL done, $PENDING_TOTAL pending across $PLANS_FOUND plan(s)"
    echo ""
    echo "── Projects ──"
    echo "$PROJECTS_SUMMARY"
    echo ""
    echo "── Git ──"
    echo "$GIT_SUM"
    echo ""
    echo "── Evidence Logs ──"
    echo "  $EVIDENCE_COUNT evidence file(s)"
    echo ""
    echo "── OpenSpec ──"
    echo "$OPENSPEC_SUMMARY"
    echo ""
    echo "── Raw Counts (for scripting) ──"
    echo "PLANS_FOUND=$PLANS_FOUND"
    echo "PENDING_TOTAL=$PENDING_TOTAL"
    echo "DONE_TOTAL=$DONE_TOTAL"
    echo "GIT_DIRTY=$GIT_DIRTY"
    echo "EVIDENCE_COUNT=$EVIDENCE_COUNT"
} > "$SUMMARY_FILE"

info "Summary written: $SUMMARY_FILE"
info "Pending tasks:   $PENDING_TOTAL"
info "Completed tasks: $DONE_TOTAL"

# If --status only, print and exit
if $ONLY_STATUS; then
    echo ""
    if [[ "$PENDING_TOTAL" -eq 0 ]] && [[ "$PLANS_FOUND" -eq 0 ]]; then
        ok "No pending plans found. Everything appears complete."
    elif [[ "$PENDING_TOTAL" -eq 0 ]] && [[ "$PLANS_FOUND" -gt 0 ]]; then
        ok "All $DONE_TOTAL tasks complete across $PLANS_FOUND plan(s)."
    else
        warn "$PENDING_TOTAL task(s) pending across $PLANS_FOUND plan(s)."
    fi
    cat "$SUMMARY_FILE"
    exit 0
fi

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  PHASE 2 — Sisyphus analysis (constrained, token-efficient)             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

if [[ "$PENDING_TOTAL" -eq 0 ]] && [[ "$PLANS_FOUND" -eq 0 ]]; then
    header "PHASE 2: No pending work found — generating completion report"

    cat > "$PLAN_OUT" << EOF
# ${TODAY} — Completion Report

## Status: ✅ All Project Work Complete

$(cat "$SUMMARY_FILE")

## Summary
As of $(date '+%Y-%m-%d %H:%M'), no pending plans or tasks were found.
No outstanding development work identified.
EOF

    cp "$PLAN_OUT" "$REPORT_DIR/report-${TODAY}.md"
    ok "Completion report: $REPORT_DIR/report-${TODAY}.md"
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ NO PENDING WORK                                    ║"
    echo "║  Completion report saved to:                           ║"
    echo "║  $REPORT_DIR/report-${TODAY}.md"
    echo "╚══════════════════════════════════════════════════════════╝"
    exit 0
fi

header "PHASE 2: Analyzing pending work with Sisyphus"

info "Pending tasks found. Preparing constrained analysis..."

# Build a tight prompt for sisyphus — strictly analysis only
SYS_PROMPT=$(cat << PROMPT
You are Sisyphus, the orchestrator. Your task is to ANALYZE project status and PRODUCE A PLAN.

## CONSTRAINTS (MUST FOLLOW)
- DO NOT explore the codebase. DO NOT run any tools that read project files.
- DO NOT execute any tasks. DO NOT make any code changes.
- You are in ANALYSIS mode only.
- Base your analysis SOLELY on the briefing summary below.
- If the briefing is unclear, state what's missing — don't guess.

## CONTEXT
This project manages 5+ sub-products (content-aggregator, Story2Video, prompt-engine, smart-sentence-splitter, Multi-Publish, content-aggregator-shared, platform-orchestrator) under a thin-shell integration at platform-orchestrator.

## WORKFLOW REQUIREMENTS
When producing the plan, every task must include:
1. "使用测试驱动开发方式实现" (TDD — write tests first)
2. "openspec propose" before implementation (create proposal + design + tasks via openspec CLI)
3. Then "openspec apply" to implement the tasks

## OUTPUT
Write your plan to: $PLAN_OUT

Format: Markdown with checkboxes.

## INPUT: Briefing Summary

$(cat "$SUMMARY_FILE")

Begin analysis. Output ONLY the plan file content.
PROMPT
)

# Launch sisyphus with the tight prompt
opencode run \
    --agent sisyphus \
    --dangerously-skip-permissions \
    --file "$PLAN_OUT" \
    --format json \
    --dir "$PROJECT_DIR" \
    --print-logs \
    --log-level WARN \
    "$SYS_PROMPT"

EXIT_CODE=$?

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  PHASE 3 — Result                                                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

echo ""
if [[ -f "$PLAN_OUT" ]]; then
    REMAINING=$(count_remaining "$PLAN_OUT")
    COMPLETED=$(count_completed "$PLAN_OUT")
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  🌅 MORNING BRIEFING COMPLETE                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Plan: $PLAN_OUT"
    echo "  Tasks: $COMPLETED done, $REMAINING remaining"
    echo ""
    if [[ "$REMAINING" -gt 0 ]]; then
        echo "  To execute: ./bin/start-day.sh"
        echo "  Or: ./bin/loop.sh --detach .omo/plans/${TODAY}.md"
    fi
else
    warn "Plan file was not created (sisyphus exit code: $EXIT_CODE)"
    warn "Summary available at: $SUMMARY_FILE"
fi

exit $EXIT_CODE
