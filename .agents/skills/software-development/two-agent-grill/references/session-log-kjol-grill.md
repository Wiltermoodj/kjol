# Session Log: Two-Agent Grill on kjol KjolHelper Daemon

## Environment
- **Platform:** Linux (6.17.0-1016-oracle) — NOT macOS
- **Hermes:** v0.20.4, git install at `~/.hermes/hermes-agent`
- **Provider:** Nous (`poolside/laguna-s-2.1:free`)
- **Reviewer model:** `stepfun/step-3.7-flash:free`
- **Repo:** `Wiltermoodj/kjol` at `~/code/projects/kjol`

## Session Token
`2f163eba`

## Modules Reviewed
1. `KjolHelper/main.swift` — privileged helper daemon (XPC server, SMC fan control, battery management, power assertions)
2. `XpcClient.swift` — resilient XPC client (backoff reconnection, sync/async split)

## What Actually Happened

### Q1: Ftst unlock busy-wait (setManual)
- **GM pre-wrote Q1** directly (no GM subagent spawned — per v2.5.2 guidance)
- **Reviewer spawned** via fixed CLI: `hermes chat -q "$(cat /tmp/reviewer-...txt)" -m stepfun/step-3.7-flash:free -t file -Q --max-turns 12`
- Reviewer took ~45s to read sidecar, find hash, write verdict
- **Verdict:** Partially agree — agree retry is hardware-necessary but blocking XPC reply for 6s is a flaw

### Q2: State cache vs disk reads
- Same pattern, parallel Reviewer spawn
- Reviewer found hash in ~60s, wrote verdict
- **Verdict:** Partially agree — cache is fine for singleton daemon but stale-cache risk exists

### Verifier
- First attempt failed: `gpt-4o` model not found on Nous provider → `HTTP 404: Model 'gpt-4o' not found`
- Fix: Use `poolside/laguna-s-2.1:free` (the configured default model)
- Verifier wrote `proposed-decisions.md` in ~60s

## Key Learnings for Future Sessions
1. **CLI flag `--query-file` does NOT exist** — use `-q "$(cat file)"`
2. **`gpt-4o` is NOT available on Nous provider** — always use `poolside/laguna-s-2.1:free` or check `hermes config`
3. **Reviewers complete in 45-60s** for focused 1-question reviews
4. **Verifier completes in 60s** with a valid model
5. **Both Reviewers can run in parallel** — no resource contention (separate subprocesses, separate file writes)
6. **Git sync enforcement:** The kjol repo was already at latest `main`, no git_ahead issues

## File Layout Produced
```
~/code/projects/kjol/knowledge/planning/kjol-helper-xpc/
├── sidecar.md          # Grill sidecar with Q1/Q2 + hashes + verdicts
├── qa-bundle.md        # Consolidated QA for Verifier
└── proposed-decisions.md  # Verifier's synthesized decisions
```

## Reviewer Spawn Pattern (reproducible)
```bash
# Write prompt to temp file
cat > /tmp/reviewer-{TOKEN}-q1.txt << 'EOF'
Design Reviewer for ...
EOF

# Spawn Reviewer subprocess (parallel-safe)
hermes chat -q "$(cat /tmp/reviewer-{TOKEN}-q1.txt)" \
  -m stepfun/step-3.7-flash:free -t file -Q --max-turns 12

# Poll for hash: grep -n "TOKEN_R_Q1_DONE" sidecar.md
```
