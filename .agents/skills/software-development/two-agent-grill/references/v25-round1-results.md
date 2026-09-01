# Test Round 1 — lightspeed-adapter.ts — Results

## Protocol: v2.5.1 (Hash Polling + Single-Q-per-Cycle)

### Test Setup
- **Code:** `apps/integration/src/lib/lightspeed-adapter.ts` (166 lines, 3 Q design surface)
- **Session token:** `b4f8c1a2`
- **Q1 topic:** serializeCreds/deserializeCreds asymmetry (3 fields serialize vs 9 fields deserialize)

### Timeline

| Time | Event | Duration |
|------|-------|----------|
| 09:47:43 | GM spawned | — |
| 09:47:48 | GM read code + sidecar (5323 + 394 chars) | 5s |
| 09:47:48 - 09:48:55 | GM thinking block | 67s |
| 09:48:55 | Reviewer spawned (token b4f8c1a2) | — |
| 09:49:03 | Reviewer polled line 30 → found hash instantly | 8s |
| 09:49:04 | Reviewer read Q1 (2034 chars) | 1s |
| 09:49:04 - 09:52:15+ | Reviewer thinking block | 191s+ |
| 09:52:15 | Stopped (output-delivery watchdog) | — |

### Findings

1. **Hash polling:** ✅ Works perfectly. Reviewer found hash on first poll (0s delay).

2. **GM thinking blocks:** ❌ GM read files at 09:47:48, then thought for 67s without producing Q1. Even with unlimited thinking time, the GM stalled.

3. **Master Agent pre-wrote Q1:** After GM stalled, Master Agent wrote Q1 manually to the sidecar (16 lines of content). This proves the GM submodel cannot reliably complete the GM task.

4. **Reviewer thinking blocks:** ❌ Reviewer found hash instantly, read Q1 (2034 chars) in 1s, then thought for 191s+ composing the response. Even 30s+ after 120s output-delivery watchdog steer, the thinking block didn't yield. Hard-stop required.

5. **Model profile issue:** `step-3.7-flash:free` enters deep thinking blocks even with small context. This is a model behavior, not a protocol problem.

### Root Cause

The subagent models (both GM default + Reviewer step-3.7-flash) have a high tendency to enter deep reasoning chains before producing output. The 120s output-delivery watchdog fires but the steer text queues — it doesn't interrupt the thinking block.

### v2.5.2 Fix

- **Master Agent pre-writes Q1:** Don't rely on the GM subagent for question formulation. The Master Agent (claude-3.5-sonnet) can write Q1 directly from reading the code.
- **Reviewer pre-filled patch:** Give the Reviewer the exact old_string + new_string to patch. Eliminates the need for the Reviewer to "find" the Current code line.
- **Hash polling still handles coordination:** Reviewer polls → finds hash → executes pre-filled patch → writes completion hash.

### Protocol v2.5.2

1. Master Agent reads code, writes Q1 + hash directly (no GM subagent)
2. Reviewer polls for hash → executes pre-filled `patch()` → writes Reviewer hash
3. Master Agent reads the review, decides if iteration needed
4. Master Agent writes Q2 + hash → Reviewer polls → patch → hash
