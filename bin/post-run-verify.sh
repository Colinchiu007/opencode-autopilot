#!/bin/bash
# ============================================================================
# opencode-autopilot — Post-Run Verification
#
# After an opencode cycle completes, this script verifies that the work
# actually happened: tests pass, git state is clean, evidence files exist.
#
# Returns:
#   0 — all checks pass
#   1 — at least one check failed (details printed to stderr)
#
# Usage:
#   ./bin/post-run-verify.sh <plan-file.md>
#
# The plan file is optional; if omitted, only project-level checks run.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

PLAN_FILE="${1:-}"
HAS_ERRORS=0

ORANGE='\033[0;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Post-Run Verification"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ── 1. Plan file check ──────────────────────────────────────────────────────
echo "--- [1/5] Plan completion check ---"

if [[ -n "$PLAN_FILE" && -f "$PLAN_FILE" ]]; then
    REMAINING=$(count_remaining "$PLAN_FILE")
    COMPLETED=$(count_completed "$PLAN_FILE")
    TOTAL=$((REMAINING + COMPLETED))

    if [[ "$REMAINING" -eq 0 && "$TOTAL" -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} All $TOTAL tasks complete"
    elif [[ "$TOTAL" -eq 0 ]]; then
        echo -e "  ${ORANGE}⚠${NC} No tasks found in plan (empty file?)"
    else
        echo -e "  ${RED}✗${NC} $REMAINING / $TOTAL tasks still pending"
        HAS_ERRORS=1
    fi
else
    echo -e "  ${ORANGE}⚠${NC} No plan file specified or file not found — skipping"
fi

# ── 2. Git state check ──────────────────────────────────────────────────────
echo ""
echo "--- [2/5] Git state check ---"

if git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null; then
    UNTRACKED=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | wc -l)
    if [[ "$UNTRACKED" -eq 0 ]]; then
        echo -e "  ${GREEN}✓${NC} Working tree clean"
    else
        echo -e "  ${ORANGE}⚠${NC} $UNTRACKED uncommitted changes (may be expected)"
        # Not a hard error — worktrees and intermediate states are normal
    fi
else
    echo -e "  ${ORANGE}⚠${NC} Not a git repository — skipping"
fi

# ── 3. Test check ────────────────────────────────────────────────────────────
echo ""
echo "--- [3/5] Test check ---"

# Scan for test directories under PROJECT_DIR (not node_modules, .omo, .git)
TEST_DIRS=$(find "$PROJECT_DIR" -maxdepth 3 -type d -name "tests" 2>/dev/null \
    | grep -v -E '(node_modules|\.omo|\.git|__pycache__)' || true)

if [[ -n "$TEST_DIRS" ]]; then
    ALL_TESTS_PASSED=true
    for td in $TEST_DIRS; do
        # Look for pytest markers
        if [[ -f "$td/../pyproject.toml" ]] || ls "$td"/*.py &>/dev/null 2>&1; then
            test_dir_short="${td#$PROJECT_DIR/}"
            echo "  Running tests in $test_dir_short ..."
            if "$PYTHON_CMD" -m pytest "$td" -x -q --tb=short 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} $test_dir_short passed"
            else
                echo -e "  ${RED}✗${NC} $test_dir_short FAILED"
                ALL_TESTS_PASSED=false
                HAS_ERRORS=1
            fi
        fi
    done

    if [[ "$ALL_TESTS_PASSED" == "true" ]]; then
        echo -e "  ${GREEN}✓${NC} All tests passed"
    fi
else
    echo -e "  ${ORANGE}⚠${NC} No test directories found under $PROJECT_DIR — skipping"
fi

# ── 4. Evidence check ────────────────────────────────────────────────────────
echo ""
echo "--- [4/5] Evidence check ---"

EVIDENCE_DIR="$PROJECT_DIR/.omo/evidence"
if [[ -d "$EVIDENCE_DIR" ]]; then
    EVIDENCE_COUNT=$(find "$EVIDENCE_DIR" -type f 2>/dev/null | wc -l)
    if [[ "$EVIDENCE_COUNT" -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} $EVIDENCE_COUNT evidence files found"
    else
        echo -e "  ${ORANGE}⚠${NC} Evidence directory is empty"
    fi
else
    echo -e "  ${ORANGE}⚠${NC} No .omo/evidence directory — skipping"
fi

# ── 5. Boulder state check ───────────────────────────────────────────────────
echo ""
echo "--- [5/5] Boulder state check ---"

BOULDER_FILE="$PROJECT_DIR/.omo/boulder.json"
if [[ -f "$BOULDER_FILE" ]]; then
    if "$PYTHON_CMD" -c "
import json, sys
with open('$BOULDER_FILE') as f:
    b = json.load(f)
status = b.get('status', 'unknown')
if status == 'completed':
    sys.exit(0)
else:
    print(f'Status: {status}')
    sys.exit(1)
" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Boulder status: completed"
    else
        echo -e "  ${ORANGE}⚠${NC} Boulder status is not 'completed'"
    fi
else
    echo -e "  ${ORANGE}⚠${NC} No .omo/boulder.json — skipping"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
if [[ "$HAS_ERRORS" -eq 0 ]]; then
    echo -e "  ${GREEN}═══ All checks passed ═══${NC}"
else
    echo -e "  ${RED}═══ Some checks FAILED ═══${NC}"
fi
echo ""

exit "$HAS_ERRORS"
