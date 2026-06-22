# opencode-autopilot

> Autonomous execution loop for opencode — run multi-step plans overnight, retry on timeout, track progress, never get stuck.

**opencode-autopilot** is a set of shell scripts that wrap opencode's `run --continue` into a resilient, multi-cycle execution engine. It is designed for long-running autonomous agent tasks where a single opencode session may timeout (30-60 min) and needs to resume from where it left off.

## Why this exists

Opencode sessions have a practical timeout limit (~30-60 min). For complex multi-task plans (e.g., refactoring 7 projects with 25+ tasks), this is not enough. Manually restarting sessions with `--continue` is tedious.

This project automates the retry loop:

1. Run opencode for up to N minutes
2. If timeout → extract session ID → restart with `--continue`
3. Repeat until all tasks are done or max cycles reached
4. Optional: stuck detection, pre-flight checks, status monitoring

## Quick Start

```bash
# 1. Run a plan (foreground, 1 hour per cycle)
./bin/loop.sh .omo/plans/my-plan.md

# 2. Run in background (detached, survive terminal close)
./bin/loop.sh --detach .omo/plans/my-plan.md

# 3. Check status
./bin/status.sh
./bin/status.sh --watch    # live-updating dashboard
./bin/status.sh --tail     # follow latest cycle log

# 4. Single shot (one cycle, no loop)
./bin/run.sh .omo/plans/my-plan.md

# 5. Pre-flight check
./bin/preflight.sh .omo/plans/my-plan.md
```

## Script Reference

| Script | Purpose |
|--------|---------|
| `bin/loop.sh` | **Main loop** — runs opencode in cycles, continues session across timeouts |
| `bin/run.sh` | **Single shot** — one opencode execution, no loop |
| `bin/preflight.sh` | **Pre-flight check** — validates environment before running |
| `bin/status.sh` | **Status dashboard** — show running processes, progress, logs |
| `config.sh` | **Shared config** — sourced by all scripts, override via env vars |

### bin/loop.sh

```
Usage: ./bin/loop.sh [--detach] <plan-file.md>

Arguments:
  --detach      Run in background (nohup), log to .omo/autopilot-daemon.log

Environment variables:
  PROJECT_DIR       Project root directory (default: cwd)
  CYCLE_TIMEOUT     Seconds per cycle (default: 3600 = 1 hour)
  AGENT_NAME        opencode agent name (default: sisyphus)
  SKIP_STUCK        Skip tasks stalled for N cycles (default: false)
  STUCK_THRESHOLD   Cycles without progress before warning (default: 3)
  MAX_ITERATIONS    Max retry cycles (default: 60)
```

Exit codes:
- `0` — all tasks complete
- `1` — max iterations reached with remaining tasks

### bin/run.sh

```
Usage: ./bin/run.sh <plan-file.md> [session-id]

Environment:
  TIMEOUT     Max seconds (default: 28800 = 8 hours)
```

### bin/preflight.sh

Checks:
1. Plan file exists and is readable
2. `opencode` CLI installed
3. Agent configuration file (`~/.config/opencode/oh-my-openagent.jsonc`)
4. Python 3 available
5. Node.js available
6. Disk space (> 20% free)
7. Memory (> 10% free)
8. No conflicting opencode processes

### bin/status.sh

```
Usage: ./bin/status.sh           # single snapshot
       ./bin/status.sh --watch   # refresh every 10s
       ./bin/status.sh --tail    # tail latest cycle log
```

## Configuration

All settings are in `config.sh`. Override any value via environment variable:

```bash
PROJECT_DIR=/srv/projects CYCLE_TIMEOUT=7200 ./bin/loop.sh plan.md
```

Key defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `PROJECT_DIR` | `$(pwd)` | Root project directory |
| `CYCLE_TIMEOUT` | `3600` | Seconds per cycle (1 hour) |
| `AGENT_NAME` | `sisyphus` | Agent for `--agent` flag |
| `MAX_ITERATIONS` | `60` | Max cycles before giving up |
| `SKIP_STUCK` | `false` | Auto-skip stalled tasks |
| `STUCK_THRESHOLD` | `3` | Cycles before marking stuck |

## Plan File Format

The autopilot works with markdown checklist plans:

```markdown
# My Plan

## Wave 1
- [ ] Task 1.1 — description
- [ ] Task 1.2 — description

## Wave 2
- [x] Task 2.1 — already done
```

- `- [ ]` = pending (counted as remaining)
- `- [x]` = completed
- `- [x] **STUCK-SKIPPED**` = skipped by stuck detection (counts as done)

## Architecture

```
opencode-autopilot/
├── README.md
├── config.sh                  # Shared configuration
├── bin/
│   ├── loop.sh                # Multi-cycle loop
│   ├── run.sh                 # Single shot
│   ├── preflight.sh           # Environment validation
│   └── status.sh              # Runtime dashboard
└── examples/
    └── opencode-agent.jsonc   # Agent config template
```

Runtime state (auto-created):

```
.omo/
├── autonomous-logs/            # Cycle logs (loop_TIMESTAMP.log, cycle_TIMESTAMP_N.log)
├── evidence/                   # Task evidence from execution
├── run-continuation/           # Session continuation metadata
├── boulder.json                # Work state (sessions, progress)
└── autopilot-daemon.log        # Detached loop output
```

## Optimizations over Basic `--continue`

| Issue | Basic Approach | autopilot |
|-------|---------------|-----------|
| Timeout handling | Session dies, manual restart | Auto-restart with `--continue` |
| Session ID extraction | Manual grep | Automatic (3 fallback strategies) |
| Stuck detection | None | Warns after N cycles, optional skip |
| Progress visibility | None | Per-cycle summary + status dashboard |
| Pre-flight checks | None | 8-point validation before run |
| Boulder state | None | Persists sessions + progress to JSON |
| Detach mode | Manual nohup | Built-in `--detach` |
| Exit code handling | All errors fatal | Graceful: timeout→continue, error→retry |

## Known Limitations

- **Session TTL**: opencode sessions have an inactivity timeout. If a cycle crashes before completing any steps, the session may expire and the next cycle starts fresh.
- **Model availability**: The agent config may reference models (`deepseek-v4-pro`, `kimi-k2.6`, etc.) that are provider-specific. Adjust `examples/opencode-agent.jsonc` for your model provider.
- **JSON log parsing**: Session extraction relies on grep patterns against JSON-lines log output. The format may change with opencode CLI versions.
