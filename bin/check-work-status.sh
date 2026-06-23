#!/bin/bash
# ============================================================================
# opencode-autopilot — Daily Work Status Check & Auto-Planning
#
# Token-efficient architecture:
#   Phase 1: Shell gathers ALL data → writes briefing file (ZERO agent tokens)
#   Phase 2: Sisyphus reads briefing → analyzes → makes ALL decisions
#
# Principle:
#   Shell does mechanical data gathering (free).
#   Sisyphus does thinking & decision-making (token spend = quality investment).
#   Never skip Sisyphus — its judgment is the quality gate.
#
# Usage:
#   ./bin/check-work-status.sh              # now
#   ./bin/check-work-status.sh --in 10      # schedule via at in 10 minutes
#   ./bin/check-work-status.sh --daily 08:00 # install cron job
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

BRIEFING_DIR="$OMO_DIR/briefing"
COMPLETION_DIR="$OMO_DIR/completion"
SAVEIFS=$IFS
IFS=$(echo -en "\n\b")
TIMESTAMP=$(ts_slug)
TODAY=$(date '+%Y%m%d')

# ── Parse flags ──────────────────────────────────────────────────────────────
ACTION="now"
for arg in "$@"; do
    case "$arg" in
        --in) ACTION="schedule"; shift; IN_MINUTES="${1:-10}"; shift ;;
        --daily) ACTION="cron"; shift; DAILY_TIME="${1:-08:00}"; shift ;;
        --help|-h)
            echo "Usage: $0 [--in MINUTES] [--daily HH:MM]"
            echo ""
            echo "Phase 1: Shell gathers data → briefing file (0 agent tokens)"
            echo "Phase 2: Sisyphus reads briefing → analyzes → decides (quality gate)"
            echo ""
            echo "  (no flag)       Run immediately"
            echo "  --in 10         Schedule via 'at' in 10 minutes"
            echo "  --daily 08:00   Install daily cron job"
            exit 0
            ;;
    esac
done

mkdir -p "$BRIEFING_DIR" "$COMPLETION_DIR"

# ── Schedule if requested ────────────────────────────────────────────────────
if [[ "$ACTION" == "schedule" ]]; then
    if ! command -v at &>/dev/null; then
        err "'at' command not found. Install: apt-get install at"
        exit 1
    fi
    echo "cd $PROJECT_DIR && bash $PROJECT_DIR/opencode-autopilot/bin/check-work-status.sh" | at now + "${IN_MINUTES}" minutes 2>/dev/null
    ok "Scheduled check in ${IN_MINUTES} minutes (at $(date -d "+${IN_MINUTES} minutes" '+%H:%M'))"
    exit 0
fi

if [[ "$ACTION" == "cron" ]]; then
    HOUR="${DAILY_TIME%%:*}"
    MINUTE="${DAILY_TIME##*:}"
    CRON_LINE="$MINUTE $HOUR * * * cd $PROJECT_DIR && bash $PROJECT_DIR/opencode-autopilot/bin/check-work-status.sh >> $OMO_DIR/check-work-status.log 2>&1"
    if crontab -l 2>/dev/null | grep -q "check-work-status.sh"; then
        warn "Cron exists. Replacing..."
        crontab -l 2>/dev/null | grep -v "check-work-status.sh" | crontab -
    fi
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    ok "Daily cron: $DAILY_TIME"
    exit 0
fi

# ===========================================================================
# PHASE 1 — SHELL GATHERS ALL DATA (0 agent tokens)
# ===========================================================================
header "PHASE 1 — Gathering Data — $(timestamp)"

BRIEFING_FILE="$BRIEFING_DIR/briefing-${TIMESTAMP}.md"

# ── 1.1: Boulder state ───────────────────────────────────────────────────────
if [[ -f "$BOULDER_FILE" ]]; then
    BOULDER_JSON=$(python3 -c "
import json
with open('$BOULDER_FILE') as f:
    d = json.load(f)
active_id = d.get('active_work_id', 'none')
works = d.get('works', {})
lines = ['| work_id | status | plan | completed_at |', '|---|---|---|---|']
for wid, w in works.items():
    marker = ' ← active' if wid == active_id else ''
    lines.append(f'| {wid} | {w.get(\"status\",\"?\")} | {w.get(\"active_plan\",\"\")} | {w.get(\"completed_at\",\"\")} |{marker}')
print('\n'.join(lines))
" 2>/dev/null)
else
    BOULDER_JSON="**No boulder.json found** — No tracked work."
fi

# ── 1.2: Plan files ──────────────────────────────────────────────────────────
PLAN_SUMMARY=""
for plan in "$OMO_DIR/plans/"*.md; do
    if [[ -f "$plan" ]]; then
        name=$(basename "$plan")
        remaining=$(count_remaining "$plan")
        completed=$(count_completed "$plan")
        stuck=$(grep -c 'STUCK-SKIPPED' "$plan" 2>/dev/null || echo 0)
        PLAN_SUMMARY+="- **$name**: $completed done, $remaining remaining, $stuck stuck-skipped"$'\n'
    fi
done
[[ -z "$PLAN_SUMMARY" ]] && PLAN_SUMMARY="No plan files found."

# ── 1.3: Evidence files ──────────────────────────────────────────────────────
EVIDENCE_LIST=$(find "$EVIDENCE_DIR" -type f -printf '%f\n' 2>/dev/null | sort | head -30 | sed 's/^/- /')
EVIDENCE_COUNT=$(find "$EVIDENCE_DIR" -type f 2>/dev/null | wc -l)
[[ -z "$EVIDENCE_LIST" ]] && EVIDENCE_LIST="(none)"

# ── 1.4: Git status across all projects ──────────────────────────────────────
GIT_SUMMARY=""
for proj_dir in "$PROJECT_DIR"/*/; do
    if [[ -d "$proj_dir/.git" ]]; then
        proj_name=$(basename "$proj_dir")
        cd "$proj_dir"
        unpushed=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo 0)
        uncommitted=$(git status --short 2>/dev/null | wc -l)
        if [[ "$unpushed" -gt 0 || "$uncommitted" -gt 0 ]]; then
            GIT_SUMMARY+="- **$proj_name**: $uncommitted uncommitted, $unpushed unpushed"$'\n'
        fi
    fi
done
cd "$PROJECT_DIR"
[[ -z "$GIT_SUMMARY" ]] && GIT_SUMMARY="All projects clean — no uncommitted or unpushed changes."

# ── 1.5: Recent autonomous logs ──────────────────────────────────────────────
RECENT_LOGS=$(find "$LOG_DIR" -type f -name "*.log" -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -5 | awk '{print "- "$2" ("strftime("%Y-%m-%d %H:%M",$1)")"}')
[[ -z "$RECENT_LOGS" ]] && RECENT_LOGS="(none)"

# ── 1.6: AGENTS.md summary ───────────────────────────────────────────────────
AGENTS_SUMMARY=$(head -20 "$PROJECT_DIR/AGENTS.md" 2>/dev/null | grep -E '^\|' | head -8 || echo "N/A")

# ── 1.7: Memory state (what's in the memory export files) ────────────────────
MEMORY_DIR="$PROJECT_DIR/memory-20260622"
if [[ -d "$MEMORY_DIR" ]]; then
    MEMORY_FILES=$(ls -la "$MEMORY_DIR/"*.json "$MEMORY_DIR/"*.jsonl "$MEMORY_DIR/"*.md 2>/dev/null | awk '{print "- "$NF" ("$5" bytes)"}')
    [[ -z "$MEMORY_FILES" ]] && MEMORY_FILES="(memory directory exists but no matching files)"
else
    MEMORY_FILES="(memory-20260622 directory not found)"
fi

# ── 1.8: Sisyphus's own conversation context: last discussion topics ─────────
# (what the user has been talking about recently)
RECENT_TOPICS=""
if [[ -f "$PROJECT_DIR/AGENTS.md" ]]; then
    RECENT_TOPICS=$(grep -E '整合决定|整合阶段|Work Status|start-day|openspec|TDD|测试驱动' "$PROJECT_DIR/AGENTS.md" 2>/dev/null | head -5 | sed 's/^/- /')
fi
[[ -z "$RECENT_TOPICS" ]] && RECENT_TOPICS="(extracted from AGENTS.md context)"

# ===========================================================================
# WRITE BRIEFING FILE — all data pre-digested for Sisyphus
# ===========================================================================
cat > "$BRIEFING_FILE" << BRIEFINGEOF
# Work Status Briefing — $(date '+%Y-%m-%d %H:%M')

> **This file is auto-generated by Phase 1 (Shell data gathering).**
> **Read it, then make ALL decisions — Shell does NOT decide anything.**

## 1. Boulder State (active work tracking)

$BOULDER_JSON

## 2. Plan Files (task progress)

$PLAN_SUMMARY

## 3. Evidence Files ($EVIDENCE_COUNT total)

$EVIDENCE_LIST

## 4. Git Status (only non-clean projects shown)

$GIT_SUMMARY

## 5. Recent Logs (last 5)

$RECENT_LOGS

## 6. Project List (from AGENTS.md)

$AGENTS_SUMMARY

## 7. Memory Exports

$MEMORY_FILES

## 8. Recent Discussion Context

$RECENT_TOPICS

---

## ═══ YOUR JOB (Sisyphus) ═══

Based on ALL the data above, you must:

### A. Assess current state
- Is the work **truly complete** or are there gaps?
- Are there hidden issues? (Evidence missing for some tasks? Stale boulder? Drifted git?)
- What's the REAL status — not just what boulder.json claims?

### B. Decide next action

**If work IS truly complete:**
- Write a comprehensive completion report to \`$COMPLETION_DIR/status-\${TODAY}-\${TIMESTAMP}.md\`
- Include: what was done, evidence, git status, any observations
- Be honest — if $EVIDENCE_COUNT evidence files vs 29 completed tasks looks suspicious, SAY SO

**If work is NOT complete (or uncertain):**
- Analyze each remaining task
- For each: does it need design first? → use \`openspec propose\`
- For each: code task? → prompt must include "请使用测试驱动开发方式实现"
- Write new \`opencode-autopilot/bin/start-day.sh\` with complete work breakdown
- Plan file format: \`.omo/plans/\${TODAY}.md\` with \`- [ ] Task\` checkboxes

### C. Key constraints (ALWAYS)
- Use TDD for all code — "请使用测试驱动开发方式实现" in prompt
- Design first: use \`openspec propose\` for feature/architecture work
- No Docker/K8s/microservices
- 4G memory budget
- Never skip quality for token savings
BRIEFINGEOF

ok "Briefing: $BRIEFING_FILE ($(wc -l < "$BRIEFING_FILE") lines)"

# ===========================================================================
# PHASE 2 — SISYPHUS MAKES ALL DECISIONS
# ===========================================================================
header "PHASE 2 — Sisyphus Analyzes & Decides"

info "Handing briefing to sisyphus agent..." 
echo ""

opencode run \
    --agent sisyphus \
    --dangerously-skip-permissions \
    --file "$BRIEFING_FILE" \
    --dir "$PROJECT_DIR" \
    --print-logs \
    --log-level WARN \
    "你收到了一个项目工作状态简报（已附在 briefing 文件中）。

**你的任务：**

1. 阅读简报中的所有数据
2. 判断当前工作是否**真正完成**（不要只看 boulder.json 的表面状态，要交叉验证证据）
3. 根据判断结果：

**如果工作已完成** → 写一份完成报告到 .omo/completion/ 目录，诚实记录情况
**如果工作未完成或存疑** → 分析剩余任务，写新的 start-day.sh，启动工作

**关键要求：**
- 所有代码任务必须用 TDD（提示词中写"请使用测试驱动开发方式实现"）
- 新功能/设计任务先用 openspec propose
- 不重写现有模块核心逻辑
- 不引入 Docker/K8s/微服务
- 请用中文回复"

EXIT_CODE=$?
RETURN_IFS=$SAVEIFS
IFS=$RETURN_IFS

if [[ $EXIT_CODE -eq 0 ]]; then
    ok "Sisyphus decision complete"
    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│  CHECK COMPLETE                                            │"
    echo "│                                                             │"
    echo "│  Briefing: $BRIEFING_FILE"
    echo "│  Completion:  $COMPLETION_DIR/                             │"
    echo "│  Next check: ./opencode-autopilot/bin/check-work-status.sh │"
    echo "└─────────────────────────────────────────────────────────────┘"
else
    err "Sisyphus exited with code $EXIT_CODE"
    exit $EXIT_CODE
fi
