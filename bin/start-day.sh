#!/bin/bash
# ============================================================================
# opencode-autopilot — Start a day of autonomous development
#
# Usage:
#   ./bin/start-day.sh "High-level goal for today"
#   ./bin/start-day.sh "Implement user authentication module"
#   ./bin/start-day.sh                              # interactive input
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

TODAY=$(date '+%Y%m%d')
PLAN_FILE=".omo/plans/${TODAY}.md"
PLAN_ABS="$PROJECT_DIR/$PLAN_FILE"

mkdir -p "$(dirname "$PLAN_ABS")"

# ── Get goal ────────────────────────────────────────────────────────────────
if [[ $# -ge 1 ]]; then
    GOAL="$*"
else
    echo "Enter today's development goal (Ctrl+D to finish):"
    GOAL=$(cat)
fi

if [[ -z "$GOAL" ]]; then
    err "No goal provided."
    exit 1
fi

header "STARTING DAY — $TODAY"
echo "  Goal: $GOAL"
echo "  Plan: $PLAN_ABS"
echo ""

# ── Step 1: Let sisyphus generate the plan ─────────────────────────────────
info "Step 1: Generating plan from goal..."
echo ""

# Create a temporary instruction for the plan agent
cat > "$PLAN_ABS" << EOF
# ${TODAY} — Autonomous Development

## Goal
${GOAL}

## Plan
<!-- The agent will convert this goal into detailed tasks below -->
EOF

opencode run \
    --agent sisyphus \
    --dangerously-skip-permissions \
    --file "$PLAN_ABS" \
    --format json \
    --dir "$PROJECT_DIR" \
    --print-logs \
    --log-level WARN \
    "Analyze the project codebase and the goal above. Break the goal into concrete, actionable tasks. Write each task as '- [ ] Task description' in the Plan section. Be specific — each task should take 1-2 hours max. After writing the plan, start executing the first task."

EXIT_CODE=$?

# ── Step 2: Count generated tasks ──────────────────────────────────────────
REMAINING=$(count_remaining "$PLAN_ABS")
COMPLETED=$(count_completed "$PLAN_ABS")

if [[ "$REMAINING" -eq 0 ]]; then
    warn "Plan generation didn't create any tasks. Starting loop anyway..."
fi

info "Plan generated: $COMPLETED done, $REMAINING remaining"
echo ""

# ── Step 3: Start auto-loop (detached) ─────────────────────────────────────
info "Step 2: Starting autonomous execution loop..."
echo ""

# Launch loop in background
nohup "$SCRIPT_DIR/loop.sh" "$PLAN_FILE" >> "$OMO_DIR/autopilot-daemon.log" 2>&1 &
LOOP_PID=$!

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  DAY STARTED                                           ║"
echo "║                                                        ║"
echo "║  Plan:     $PLAN_FILE"
echo "║  Tasks:    $REMAINING tasks to do"
echo "║  Loop PID: $LOOP_PID"
echo "║                                                        ║"
echo "║  Monitor:  ./bin/status.sh --watch                     ║"
echo "║  Logs:     tail -f $OMO_DIR/autopilot-daemon.log       ║"
echo "╚══════════════════════════════════════════════════════════╝"
