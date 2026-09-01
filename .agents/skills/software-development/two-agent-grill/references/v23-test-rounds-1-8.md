# v2.3 Test Results — Rounds 1-8

## Protocol Evolution Timeline

| Version | Key Change | Test Rounds | Avg Reviewer Time |
|---------|-----------|-------------|-------------------|
| V3 | offset/limit + explicit patch | R5 | 141s |
| V4 | Pending Reviewer: line replacement | R6, R7 | 146s |
| V5 | Explicit `## ADR` anchor in patch | R8 | 100s |
| Watchdog | 120s → steer → 15s → stop → respawn | R3, R4, R5 | — |

## All 8 Q&As

| Round | Q Topic | GM Time | Reviewer Time | Verdict | Key Learning |
|-------|---------|---------|---------------|---------|-------------|
| 1 | Pagination & Incremental Sync Cursors | 92s | 32s | ✅ Agree (B) | Abs paths + offset/limit |
| 2 | SKU Uniqueness & Lookup Contract | 93s | 82s | ✅ Agree (B) | Auto-bump Q via grep -c |
| 3 | Idempotency & createSale | 258s* | 136s | 🟡 Partially agree (A) | Watchdog steer works |
| 4 | Directional Asymmetry on pushInventoryToShopify | 91s | 332s* | ✅ Agree (A) | Respawn per round |
| 5 | Credential Union Default Parameter | 219s* | 141s | ✅ Agree (A) | Steer → stop → respawn |
| 6 | Credential Blob Versioning | 155s | 183s | ✅ Agree (A) + 3 notes | V5 anchor pattern |
| 7 | Unbounded List Returns | 85s | 100s | ✅ Concur (A) + 3 additions | GM context overload fix |
| 8 | Credential Union Type Safety Leak | 91s | 51s* | ✅ Agree (A) | V5 = 64% faster than V3 |

* = Watchdog intervention required
*GM Round 3: 258s (120s steer); GM Round 5: 219s (stuck reading 6K char section)
*Reviewer Round 4 v1: got stuck → respawned → 332s total; Reviewer V5: 51s

## GM context overload — the evolution

### Round 3 (failure: 258s)
- GM read the **full sidecar** (17K+ chars) before writing Q3
- Stuck in thinking block for 144s
- 120s watchdog steer: "TIMEOUT — produce your output now. Do not continue working."
- Woke up → wrote Q3 in ~138s

### Fix (applied Round 7+): targeted reads only
- GM runs `grep -n "### Q" <sidecar> | tail -1` → gets latest Q line number
- GM reads ONLY that Q section: `read_file(offset=line, limit=20)`
- **Round 7:** GM completed in 85s (no steer needed)
- **Round 8:** GM completed in 91s (no steer needed)

### Root cause
The GM kept reading large sidecar sections for context, causing 100+ second thinking blocks. The fix: GM reads code first, then greps for Q count + reads only the latest Q's section (20 lines max).

## Reviewer V5 protocol — the surgical pattern

### Round 4 Reviewer v1 failure
- Got vague goal: "find the LATEST ### Q heading"
- Started `search_files` on the full 10K+ sidecar
- Stuck in thinking/search loop for 208s
- Watchdog steer + stop + respawn required
- V2 respawn (surgical) completed in 82s

### V5 protocol (Round 5-8)
1. `read_file(sidecar, offset=Q_LINE, limit=20)` — Q only
2. `terminal(date +%H:%M:%S)` — real timestamp
3. `read_file(session_doc, offset=11, limit=12)` — timeline window
4. `patch(sidecar, old_string=Current_code_line + "\n\n## ADR:...", new_string=... + Reviewer_response + "\n\n## ADR:...")`
5. `patch(session_doc, old_string=<last_entry>, new_string=<entry + new_entry>)`
6. STOP

### V5 performance
- Round 8: 51.25s (fastest ever)
- Both patches succeed on first attempt when old_string matches exactly
