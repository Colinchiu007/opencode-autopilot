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
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
PLAN_FILE=".omo/plans/${TODAY}-finish-refactor.md"
PLAN_ABS="$PROJECT_DIR/$PLAN_FILE"
COMPLETION_DIR="$OMO_DIR/completion"

mkdir -p "$OMO_DIR/completion" "$OMO_DIR/plans"

# ── Get goal ────────────────────────────────────────────────────────────────
if [[ $# -ge 1 ]]; then
    if [[ "$1" == "--finish-refactor" ]]; then
        GOAL="完成 integration-refactor 收尾工作：提交所有未提交代码、修复测试、生成证据"
        PLAN_FILE=".omo/plans/2026-06-22-finish-refactor.md"
        PLAN_ABS="$PROJECT_DIR/$PLAN_FILE"
        shift
    else
        GOAL="$*"
    fi
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

# ── Step 1: Verify prerequisites ────────────────────────────────────────────
info "Step 1: Pre-flight checks..."

# Python check (using PYTHON_CMD from config)
if command -v "$PYTHON_CMD" &>/dev/null; then
    ok "$PYTHON_CMD: $("$PYTHON_CMD" --version)"
else
    err "$PYTHON_CMD not found! Required for tests."
    exit 1
fi

# opencode check
if command -v opencode &>/dev/null; then
    ok "opencode: available"
else
    err "opencode CLI not found!"
    exit 1
fi

if [[ ! -f "$PLAN_ABS" ]]; then
    warn "Plan file not found: $PLAN_ABS"
    info "Creating skeleton plan..."
    cat > "$PLAN_ABS" << EOF
# ${TODAY} — Autonomous Development

## Goal
${GOAL}

## Plan
<!-- The agent will convert this goal into detailed tasks below -->
EOF
fi

# ── Step 2: Let sisyphus plan (if skeleton) or directly execute ─────────────
if grep -q "The agent will convert" "$PLAN_ABS" 2>/dev/null; then
    info "Step 2: Generating detailed plan from goal..."
    opencode run \
        --dangerously-skip-permissions \
        --file "$PLAN_ABS" \
        --dir "$PROJECT_DIR" \
        --print-logs \
        --log-level WARN \
        "分析项目代码库和上述目标。将目标分解为具体的、可执行的任务。使用测试驱动开发方式实现所有代码任务。在 Plan 部分用 '- [ ] Task' 格式写入每个任务。任务需要具体——每个任务应在 1-2 小时内完成。然后开始执行第一个任务。"
else
    info "Step 2: Plan already exists — using existing plan."
fi

# Count tasks
REMAINING=$(count_remaining "$PLAN_ABS")
COMPLETED=$(count_completed "$PLAN_ABS")

info "Plan ready: $COMPLETED done, $REMAINING remaining"
echo ""

# ── Step 3: Start auto-loop (detached) ─────────────────────────────────────
info "Step 3: Starting autonomous execution loop..."
echo ""

# Safety: kill existing loop if any
EXISTING=$(pgrep -f "loop.sh.*$PLAN_FILE" 2>/dev/null || true)
if [[ -n "$EXISTING" ]]; then
    warn "Existing loop found (PID: $EXISTING). Killing..."
    kill "$EXISTING" 2>/dev/null || true
    sleep 2
fi

# Launch loop in background
nohup "$SCRIPT_DIR/loop.sh" "$PLAN_FILE" >> "$OMO_DIR/autopilot-daemon.log" 2>&1 &
LOOP_PID=$!

echo ""
echo "┌──────────────────────────────────────────────────────────┐"
echo "│  DAY STARTED                                            │"
echo "│                                                         │"
echo "│  Plan:     $PLAN_FILE"
echo "│  Tasks:    $REMAINING tasks to do"
echo "│  Loop PID: $LOOP_PID"
echo "│                                                         │"
echo "│  Monitor:  ./opencode-autopilot/bin/status.sh --watch   │"
echo "│  Logs:     tail -f .omo/autopilot-daemon.log            │"
echo "│  Briefing: ./opencode-autopilot/bin/check-work-status.sh│"
echo "└──────────────────────────────────────────────────────────┘"

# Notify day started
notify "start" "Development Day Started" \
    "Goal: ${GOAL:0:100}\\nPlan: $PLAN_FILE\\nTasks: $REMAINING remaining\\nLoop PID: $LOOP_PID"
