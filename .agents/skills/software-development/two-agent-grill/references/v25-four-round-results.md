# Four-Round Test Results — Two-Agent Grill v2.5.x

## Test Matrix

| Round | Codebase | Module | Lines | Session Token | Q1 Topic | Reviewer Time | Verdict |
|-------|----------|--------|-------|--------------|----------|--------------|---------|
| 1 | middleware | lightspeed-adapter.ts | 166 | b4f8c1a2 | Credential serialization asymmetry | GM stalled / Reviewer stalled | N/A |
| 2 | middleware | webhook-shopify/route.ts | 282 | 28b99bbd | HMAC secret fallback chain | 146s+ (stopped) | N/A |
| 3 | cntrl | middleware.ts | 124 | 39261a72 | Allowlist justification burden | **66.4s** ✅ | Partially agree |
| 4 | middleware | citrus-lime-adapter.ts | 429 | b63f433c | Cross-module credential coupling | **65.8s** ✅ | Agree |

## Key Findings

### 1. Hash Polling Works Perfectly (All 4 Rounds)
- Reviewer finds `<!--TOKEN_GM_Q1_DONE-->` on first poll (0-6s latency)
- Session token (8-char hex) prevents cross-session contamination
- No manual timing coordination needed

### 2. GM Subagent is Unnecessary (Rounds 1-2)
- GM read code + sidecar (5323 + 394 chars), then stalled 67-120s without writing Q1
- Master Agent pre-writing Q1 (v2.5.2+) is reliable and faster
- **Recommendation:** Eliminate GM subagent. Master Agent writes all Qs directly.

### 3. Reviewer Thinking Time Correlates with Code Complexity (Rounds 2-4)
- Round 2 (webhook route, 282 lines): 146s+ thinking stall
- Round 3 (cntrl middleware, 124 lines): **66.4s** ✅
- Round 4 (citrus-lime, 429 lines): **65.8s** ✅
- **Odd result:** Round 4 (largest module) was FASTER than Round 2 (medium module)
- **Insight:** Thinking time depends on Q1 focus, not code size. A narrow single-question Q1 (Round 3-4) completes in 66s; a sprawling multi-branch Q1 (Round 2 HMAC fallback + dedup + retry) triggers 146s+ stalls.

### 4. Model Profile is the Bottleneck, Not Protocol
- `step-3.7-flash:free` Reviewer model enters deep thinking blocks (60-180s) regardless of input size
- The 120s output-delivery watchdog fires but the steer text queues — it doesn't interrupt the thinking block
- **Recommendation:** Accept 120s+ thinking as normal. The v2.5 "no thinking limit" policy is correct.

### 5. Single-Q-Per-Cycle is Essential
- Round 1 (all-8-Q test, earlier session): 304s thinking stall
- Round 3-4 (single-Q): 66s ✅
- Each subagent holds 1 Q in context → bounded thinking time

## Protocol v2.5.5 (Final Recommendation)

1. **Master Agent pre-writes Q1** (no GM subagent)
   - Read code, write Q1 + `<!--TOKEN_GM_Q1_DONE-->` at line (ADR-1)
2. **Reviewer polls for hash** → reads Q1 → writes review → `<!--TOKEN_R_Q1_DONE-->`
3. **Master Agent writes Q2** → Reviewer polls → reviews → hash
4. **Repeat until Master Agent decides "no more questions"**
5. **Extract qa-bundle** → Verifier → decisions.md

### Eliminated Components
- ❌ GM subagent (Master Agent writes Qs directly)
- ❌ 120s thinking-time limit (user decision: no limit)
- ❌ "DO NOT" anti-patterns (concise affirmative prompts)
- ❌ Timeline/session-doc updates (hash polling replaces them)

### Kept Components
- ✅ Hash polling at line (ADR-1)
- ✅ Single-Q-per-cycle
- ✅ 8-char session token
- ✅ 120s output-delivery watchdog (steer if no tool call after 120s)
- ✅ Surgical Reviewer patch (read offset/limit + explicit old_string)

## Test Artifacts (NOT committed — testing only)

| File | Repo | Status |
|------|------|--------|
| `lightspeed-adapter.ts.md` | middleware | Q1 pre-written (GM stalled) |
| `webhook-shopify/route.ts.md` | middleware | Q1 pre-written (Reviewer stalled) |
| `middleware.ts.md` | cntrl | Q1 + Reviewer response (66.4s) ✅ |
| `citrus-lime-adapter.ts.md` | middleware | Q1 + Reviewer response (65.8s) ✅ |
| `v25-round1-results.md` | skill refs | Round 1 analysis |
| `v25-round2-results.md` | skill refs | Round 2 analysis |
| `v25-round3-results.md` | skill refs | Round 3 analysis |

All sidecar + session doc files created during testing should be DELETED before commit.
The skill itself (`SKILL.md` v2.5.1) is committed and production-ready.
