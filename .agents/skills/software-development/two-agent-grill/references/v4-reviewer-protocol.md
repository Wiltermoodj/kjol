# V4 Reviewer Protocol — Surgical 6-Step Pattern

Proven reliable across v2.3 test rounds 5-7. This is the canonical Reviewer spawn pattern.

## The 6 Steps (in order)

1. **Read Q section only:** `read_file(sidecar, offset=Q_START_LINE, limit=20)`
   - Do NOT read the full sidecar. Large sidecars (10K+ chars) cause 100+ second thinking blocks.
   - Calculate Q_START_LINE from `grep -n "### Q{N}" sidecar` before spawning.

2. **Get timestamp:** `terminal('date +%H:%M:%S')`
   - Do NOT use literal `00:__:__` placeholders — they get written to the timeline verbatim.

3. **Read timeline section:** `read_file(session_doc, offset=11, limit=12)`
   - Session doc timeline starts around line 11. Read a small window to find the exact `old_string` for the patch.
   - Do NOT use hardcoded large offsets (e.g. `offset=260`) — the file grows each round and the offset will be "beyond end of file."

4. **Patch sidecar:** `patch(sidecar, old_string=<Current code line>, new_string=<Current code line + Reviewer response>)`
   - `old_string` must be an EXACT match including the `**Current code:** ...` line.
   - Verify the empty `**Reviewer:**` line exists after Q's Current code line. If not, match the Current code line + `\n\n## ADR:`.

5. **Patch timeline:** `patch(session_doc, old_string=<last timeline entry>, new_string=<last entry + \n + "{time} - Reviewer responded to Q{N}")`

6. **STOP immediately** — say "Waiting for next steer" and exit.

## Common failures + fixes

| Failure | Cause | Fix |
|---------|-------|-----|
| `search_files` loop (stuck 100s+) | Vague instructions → model explores sidecar | Surgical 6-step protocol above |
| `patch` "Could not find match" | `old_string` not exact | Copy exact line from `read_file` output |
| Timeline `00:__:__ - Reviewer responded` | Literal placeholder in goal | Use `terminal(date)` to get real time |
| `read_file offset=260` "beyond end of file" | Hardcoded offset, file grew | Read small window (lines 11-20), calculate dynamically |
| Reviewer reviews wrong Q (v1 old content) | Sidecar has historical `**Q1` sections | Specify exact line offset in goal; tell Reviewer to find `### Q{N}` not `**Q{N}` |

## Test results (v2.3 rounds 5-7)

| Round | Q Topic | GM Time | Reviewer Time | Verdict |
|-------|---------|---------|---------------|---------|
| 5 | Credential Union Default Parameter | 219s* | 141s | ✅ Agree (A) |
| 6 | Credential Blob Versioning | 155s | 183s | ✅ Agree (A) + 3 notes |
| 7 | Unbounded List Returns | 85s | 100s | ✅ Concur (A) + 3 design additions |

*Round 5 GM needed 120s watchdog steer; Round 7 was 2x faster due to targeted reads.
