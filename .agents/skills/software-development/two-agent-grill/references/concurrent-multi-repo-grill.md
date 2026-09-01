# Concurrent Multi-Repo Grill Sessions

Created: 2026-08-31 (from session: two-agent-grill running on CNTRL and CNTNR repos)

## Problem
When running two-agent-grill on multiple repositories (CNTRL + CNTNR), the event-driven cronjob architecture requires independent sessions per repo. The key challenge is that the standard grill monitor suppresses when `git rev-list --count @{u}..HEAD` > 0 (local ahead of upstream) — but when the FE completer commits results, this naturally creates a commit ahead. The fix: treat `git_ahead` as advisory (report in output) but don't suppress the trigger.

## Setup Pattern
Per repo:
1. Create `grill-{repo}-monitor.sh` (finds ungrilled domains, reports git_ahead, outputs READY/ALL_GRILLED — but the orchestrator only suppresses on `git_ahead` check, not the monitor)
2. Create `grill-{repo}-orchestrator.py` (no_agent=true, one domain per tick, template-based Q generation)
3. Create `grill-{repo}-fe-completer.py` (runs when standard grill complete, generates feature proposals)
4. Register two cronjobs: standard (every 2m) + FE (every 2m)

## Critical Bug Fixes

### Monitor Hash Suppression
The cronjob's `monitor_script` output is hashed in `monitor_state` (`last_output_hash`). Clearing `monitor_state` (via editing `/Users/lappier/.hermes/cron/jobs.json`) forces the next tick to fire. After clearing, the next tick will trigger correctly.

### Race Condition in Monitor Check
The monitor's `is_grilled()` must check the FULL sidecar content (not first 500 chars), because the Reviewer's review text pushes `GM_Q1_DONE` markers beyond the 500-char window. Fix: `if "_GM_Q1_DONE-->" in content: return True` using `content = open(sidecar).read()`.

### Git Ahead Not Blocking
The monitor must output `STATUS=READY` regardless of `git_ahead` value (the orchestrator handles suppression). The previous version suppressed the trigger when `git_ahead > 0`, which blocked the pipeline when the FE completer committed results.

### Verdict Extraction Timing
After detecting R hashes (`_R_Q1_DONE-->` and `_R_Q2_DONE-->`), the Reviewer's `patch()` writes the hash BEFORE the review text. The verdict (`**Verdict:** Agree`) appears after the hash. The orchestrator must poll an additional 15-30s (5s intervals) for `Verdict.*?\s*(Agree|Partially agree|Disagree)` before extracting verdicts. Without this, `q1_verdicts` and `q2_verdicts` arrays are empty, producing `TIMEOUT` results.

### Filename Extension Bug
When processing `.ts.md` files (sidecars), `os.path.basename(f).replace(".ts", "")` produces `.md` suffix instead of the original basename. Fix: `os.path.basename(f).replace(".ts.md", "")`.

## Verified Concurrent Run Results
- CNTRL (e4739e97792d): Standard grill processes 1 domain per tick (~5 min/domain at 30s Reviewer + 30s polling + overhead). FE completer fires only when `STATUS=READY` + `count=0` (all grilled).
- CNTNR (35bcbcce4f59): Monitor detects ungrilled domain (`lib/agents/agent-cmdline-glob.ts`) with `git_ahead=0`. Orchestrator fires correctly after clearing `monitor_state`.
- Both repos' monitors now return `READY` independently. The event-driven trigger fires correctly on each tick when the output changes.