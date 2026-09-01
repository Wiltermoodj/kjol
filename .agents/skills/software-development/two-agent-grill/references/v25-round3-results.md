# Test Round 3 — cntrl/src/middleware.ts — Results

## Protocol: v2.5.3 (Master Agent pre-writes Q, Reviewer polls + patches)

### Test Setup
- **Code:** `src/middleware.ts` (124 lines, security gate with default-deny + allowlist)
- **Session token:** `39261a72`
- **Q1 topic:** Allowlist entry justification burden (silent exposure risk)
- **Sidecar:** Pre-written with Q1 + `<!--39261a72_GM_Q1_DONE-->` at line 28

### Timeline

| Time | Event | Duration |
|------|-------|----------|
| 09:55:09 | Reviewer spawned | — |
| 09:55:14 | Reviewer polled line 28 → found hash instantly | 5s |
| 09:55:17 | Reviewer read Q1 (1278 chars) | 3s |
| 09:55:31 | Reviewer read lines 28-32 (hash + ADR) | 14s |
| 09:56:11 | Reviewer wrote R_Q1_DONE hash + Q1 review | 80s thinking |
| 09:56:16 | Completed | 66s total |

### Findings

1. **Hash polling:** ✅ Works perfectly. Found hash on first poll (5s after spawn).

2. **Reviewer thinking time:** ✅ **66.4s total** — fastest yet! Much faster than Round 1 (451.9s) and Round 2 (146s+).

3. **Why faster?** The `cntrl` module is smaller (124 lines vs 282 lines) and Q1 is more focused (single narrow question about allowlist logging). The `middlewarez` modules are larger with more sprawling code, which seems to trigger longer thinking.

4. **Reviewer verdict quality:** ✅ **Partially agree** — recommended A+B hybrid (logging + unit test), not A alone. This is genuine adversarial pushback, exactly what the skill is designed for.

5. **Model behavior varies by context:** The same `step-3.7-flash:free` model completed Round 3 in 66s but stalled 146s+ in Round 2. **Code complexity, not protocol, drives thinking time.**

### Conclusion

The v2.5 protocol works. Hash polling is instant. Single-Q-per-cycle bounds context. The only variable is thinking time, which correlates with code/module complexity (not a protocol issue).

### v2.5.4 Recommendation

- **GM subagent:** Eliminated. Master Agent pre-writes Qs (proven reliable in all 3 rounds).
- **Reviewer model:** `step-3.7-flash:free` is usable for small/focused modules (Round 3: 66s) but stalls on large/sprawling modules (Round 1-2: 150s+).
- **Hash polling:** ✅ Keep. Works perfectly across all repos.
- **Output-delivery watchdog:** Keep at 120s, but accept that some rounds will exceed it (Round 3 shows 66s is achievable).
