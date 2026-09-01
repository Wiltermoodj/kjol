# Test Round 2 — webhook-shopify route.ts — Results

## Protocol: v2.5.2 (Master Agent pre-writes Q, Reviewer polls + patches)

### Test Setup
- **Code:** `apps/integration/src/app/api/webhooks/shopify/route.ts` (282 lines, security-critical HMAC validation)
- **Session token:** `28b99bbd`
- **Q1 topic:** HMAC secret resolution fallback chain (`||` vs `??`)
- **Sidecar:** Pre-written with Q1 + `<!--28b99bbd_GM_Q1_DONE-->` at line 28

### Timeline

| Time | Event | Duration |
|------|-------|----------|
| 09:51:09 | Reviewer spawned | — |
| 09:51:15 | Reviewer polled line 28 → found hash instantly | 6s |
| 09:51:20 | Reviewer read full sidecar (1667 chars) | 5s |
| 09:52:44 | Reviewer read Q1 section (1015 chars) | 84s thinking |
| 09:52:44 - 09:55:10+ | Reviewer thinking block | 146s+ |
| 09:55:10 | Stopped | — |

### Findings

1. **Hash polling:** ✅ Works perfectly. Reviewer found hash on first poll (6s after spawn).

2. **Reviewer thinking blocks:** ❌ Even with small context (1667 chars total sidecar, 1015 chars Q1 section), the Reviewer spent 146s+ in thinking block after reading Q1.

3. **Same model behavior as Round 1:** `step-3.7-flash:free` enters deep reasoning chains regardless of input size. The 120s output-delivery watchdog fires but the steer text queues — it doesn't interrupt the thinking block.

4. **Pre-written Q (v2.5.2 approach):** ✅ Works as designed. The Master Agent can reliably write Q1 — the GM submodel is NOT needed for question formulation.

### Conclusion

The model-profile issue is the bottleneck, not the protocol. Hash polling + single-Q-per-cycle solves coordination. The `step-3.7-flash:free` Reviewer model simply cannot compose responses within reasonable time limits without hard-stop intervention.

### v2.5.3 Recommendation

- **GM subagent:** Eliminated. Master Agent pre-writes all Qs (proven reliable in Round 1 + Round 2).
- **Reviewer model:** The `step-3.7-flash:free` model is too slow for this use case. Consider a stronger model (e.g. `gpt-4o-mini` or `claude-3.5-haiku`) for the Reviewer role, OR reduce Reviewer task to a 1-sentence verdict with no reasoning (faster composition).
- **Hash polling:** ✅ Keep. Works perfectly.
- **Output-delivery watchdog:** Keep at 120s, but the steer must interrupt the thinking block — current implementation queues and doesn't break the block.
