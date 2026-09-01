# Adapting the Two-Agent Grill to a New Repository

A quick-start guide for extending the two-agent grill pipeline to a new codebase.

## Required Files (per repo)

### 1. Orchestrator Script
**Path:** `~/.hermes/scripts/grill-{repo}-orchestrator.py`

Key variables to change:
- `REPO = "/path/to/repo"`
- `WORKSPACE` / work directories (e.g., `src/services`, `lib`, `app/api`)
- `PLAN_FILE` / `COMPLETION_FILE` paths
- `analyze_code()` — update pattern detection for repo-specific keywords
- `generate_q1()` / `generate_q2()` — update Q templates for repo domain
- `find_ungrilled_domains()` — update directory search paths and skip patterns

### 2. Monitor Scripts
**Standard grill monitor:** `grill-{repo}-monitor.sh`
- Checks git sync (`git rev-list --count @{u}..HEAD`)
- Finds first ungrilled domain (Python subshell for reliable glob handling)
- Returns `STATUS=READY` or `STATUS=ALL_GRILLED`

**FE trigger monitor:** `grill-{repo}-fe-monitor.sh`
- Counts total domains vs grilled domains
- Returns `STATUS=STANDARD_GRILLED_IN_PROGRESS (N/M)` until all grilled
- Returns `STATUS=READY_FE` + `fe_needed=<domain>` when FE can start

### 3. FE Completer Script
**Path:** `~/.hermes/scripts/grill-{repo}-fe-completer.py`
- Finds sidecars with R hashes but no `## Feature Expansion` section
- Generates FE proposal via templates (same pattern detection as orchestrator)
- Spawns Reviewer, waits for verdict, appends to plan file

## Cronjob Registration

Two cronjobs per repo:

```python
# Standard grill
cronjob(action='create', schedule='every 2m',
    name=f'{repo}-grill-standard',
    monitor_script=f'grill-{repo}-monitor.sh',
    script=f'grill-{repo}-orchestrator.py',
    deliver='telegram:8951222762')

# FE completer (triggers only after standard complete)
cronjob(action='create', schedule='every 2m',
    name=f'{repo}-grill-fe-completer',
    monitor_script=f'grill-{repo}-fe-monitor.sh',
    script=f'grill-{repo}-fe-completer.py',
    deliver='telegram:8951222762')
```

## Directory Structure Examples

| Repo | Source Dir | File Pattern | Line Threshold |
|------|-----------|-------------|----------------|
| trail-tune-new | `src/services/` | `*.ts` | 100 lines |
| cntrl | `src/` recursive | `*.ts` | 100 lines |
| cntnr | `lib/` + `app/` recursive | `*.ts` (not `.test/.spec`) | 100 lines |

## Code Inspection Before Template Creation (v2.5.5)

**Before writing Q templates for a new repo, always inspect first:**

1. **Git sync check** — `git fetch origin && git rev-list --count '@{u}..HEAD'`. If > 0, abort (local is ahead).
2. **Repo structure** — read `AGENTS.md`, `README.md`, and inspect `src/` directory layout.
3. **Security model** — read Firestore rules (if Firebase/FaaS repo). Look at who enforces tenant isolation: client or server.
4. **Existing sidecars** — check `src/**/*.ts.md` files for prior grill session notes (user_notes, decisions, open questions).
5. **Key modules** — read the actual auth context, order/transaction service, and any security-critical paths.

**b2b reality check (v2.5.5):** The B2B repo (`Wiltermoodj/b2b`) uses mock auth on the client (`MOCK_AUTH` localStorage, mock-uid/mock-company in auth-context.tsx) but enforces real tenant isolation server-side via Firestore rules (`belongsToCompany`/`isAssignedRep`/`companyId`) and the `createOrderV1` Cloud Function. The client bridge (`order-operations.ts`) is a 23-line thin wrapper — no tenant checks, just delegates to CF. Q templates must reference actual file/line numbers (`auth-context.tsx` 39-88, `firestore.rules` 41-46/119-143, `order-service.ts` actor validation).
2. **Bash subshell variable scoping:** Variables set inside `while` loops with pipe input are lost. Use Python for counting logic.
3. **Reviewer timeout:** Reviewers can take 250-400s. Poll for 420s for hashes, then 24×5s for verdict text.
4. **Git ahead stale ref:** After `git pull`, run `git update-ref refs/remotes/origin/main HEAD` if `@{u}..HEAD` reports wrong counts.
5. **Bracket in path:** Files like `[id]/route.ts` can cause issues with bash globbing. Use Python `glob.glob(recursive=True)`.
