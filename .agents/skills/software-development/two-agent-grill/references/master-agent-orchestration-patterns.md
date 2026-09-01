# Master Agent Orchestration Patterns

## v2.5.2 — Trail-tune-new Test Results

### What Actually Works (Proven)

**Master Agent spawns Reviewers via `hermes chat` CLI**, NOT `delegate_task`:
```bash
hermes chat --query-file /tmp/reviewer-dN.txt -m stepfun/step-3.7-flash:free -t file -Q --max-turns 12
```

**Why:** `delegate_task` is not available inside subagent context. The Master Agent can spawn Reviewers via `hermes` CLI as real subprocesses with genuine model separation.

### Execution Pattern (421.9s total, all 4 domains)

```
Master Agent (strong model)
  ├── Generate 4 session tokens (8-char hex each)
  ├── Pre-write Q1 for all 4 domains (read code, write Q + <!--TOKEN_GM_Q1_DONE-->)
  ├── Spawn 4 Reviewer subprocesses in PARALLEL via hermes CLI
  ├── Wait for all 4 completions
  ├── Write Q2 for all 4 domains
  ├── Spawn 4 Reviewer subprocesses in PARALLEL via hermes CLI
  ├── All hash markers verified (2 GM + 2 R each = 4 per domain, 16 total)
  └── Write session doc
```

### Hash Markers

All 4 sidecars show the correct pattern:
```
<!--TOKEN_GM_Q1_DONE-->
<!--TOKEN_GM_Q2_DONE-->
<!--TOKEN_R_Q1_DONE-->
<!--TOKEN_R_Q2_DONE-->
```

### Reviewer Verdicts

| Domain | Q1 Verdict | Q2 Verdict |
|--------|-----------|-----------|
| firestore-tune-adapter | Partially agree | Agree |
| firestore-catalog-adapter | Partially agree | Disagree |
| bike-assembler | Agree | Partially agree |
| ingestion-pipeline | Partially agree | Partially agree |

### Key Finding: Parallel Reviewer Spawns

Spawning all 4 Reviewers simultaneously reduced wall time from sequential ~4min to 7min total (vs 4×36s = 12min sequential). Each Reviewer is independent — no coordination conflicts via hash polling.

### Bug Found and Fixed

Round 1 Reviewer (domain 1) accidentally dropped GM hash lines. Master restored them via `patch` and hardened the Reviewer prompt for rounds 2-4 with: "DO NOT modify GM hash lines, only append R hash markers."

### ADR Ownership Rule (v2.5.2)

- Proposed ADRs go in sidecar `## Proposed ADR` section (NOT `## ADR`)
- Verifier writes to `proposed-decisions.md` (NOT `decisions.md`)
- Human review required before any ADR becomes final

### Preflight Usage

```bash
python3 ~/.hermes/skills/software-development/two-agent-grill/scripts/preflight.py \
  --code src/services/firestore-tune-adapter.ts \
  --sidecar src/services/firestore-tune-adapter.ts.md \
  --session knowledge/planning/grill-session-v2.md
```

Output: `QCOUNT=2 ADRLINE=68`
