# v2.4 Test Results — Hash Protocol vs Thinking-Block Limitation

## What v2.4 Proved

### ✅ Hash Polling Works
- Reviewer found `<!--e174f8a8_GM_Q8_DONE-->` at line 203 on **first poll** (instant)
- No manual timing coordination needed
- Session token (8-char hex) prevents cross-domain hash collision
- Reviewer read ONLY Q8 (2758 chars at offset=186, limit=15) — not the full 45K sidecar

### ❌ Thinking-Block Problem NOT Solved by Single-Q Protocol

| Protocol | Q Context | Reviewer Time | Thinking Block? |
|----------|-----------|---------------|-----------------|
| v2.4 all-8 (V5) | 8 Qs (~30K chars) | 304s | YES (hard-stop) |
| v2.4 batch-2 (V6) | Q1+Q2 (5241 chars) | 197s | YES (hard-stop) |
| v2.4 single-Q (V7) | Q8 (2758 chars) | 120s+ | YES (hard-stop) |
| v2.3 V4 single-Q | Specific line range | 51s | NO |

**Root cause:** The `step-3.7-flash:free` model enters 60-180s thinking blocks regardless of input size. Even 2758 chars (1 Q) triggered a 120s+ stall. The model's reasoning profile doesn't match its supposed speed advantage.

### ✅ What DID Work: Surgical Reviewer Protocol (v2.3)

The V4/V5 Reviewer protocol from v2.3 was the only approach that reliably avoided thinking-block stalls:

1. `read_file(sidecar, offset=Q_START, limit=15)` — read Q section only
2. `terminal(date +%H:%M:%S)` — get timestamp
3. `read_file(session_doc, offset=11, limit=12)` — timeline
4. `patch(sidecar, old_string=<Current code line + \n\n## ADR>, new_string=<Current code + response + \n\n## ADR>)`
5. `patch(session_doc, old_string=<last timeline entry>, new_string=<entry + time>)`
6. STOP

**Why it worked:** The 6-step protocol gives the Reviewer an explicit `old_string` that includes `\n\n## ADR`, making the patch deterministic. The Reviewer doesn't need to "find" the insertion point — it's hardcoded in the goal.

### Key Insight: Hash + Surgical Patch = Best Combo

The v2.4 hash protocol solves **coordination** (when to wake up). The v2.3 surgical protocol solves **execution** (how to patch without stalling). The v2.4.1 skill combines both:

1. **Hash polling** for timing coordination (no manual steers)
2. **Surgical 6-step patch** for reliable execution (no thinking blocks)
3. **Explicit old_string** with `\n\n## ADR` boundary for deterministic insertion

## Verdict

v2.4's hash protocol is sound for coordination. The thinking-block issue is a model behavior problem, not a protocol problem. The v2.4.1 skill addresses both by pairing hash-based polling with the surgical Reviewer protocol from v2.3.
