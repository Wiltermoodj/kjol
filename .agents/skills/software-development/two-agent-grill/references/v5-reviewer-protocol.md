# V5 Reviewer Protocol — Round 8 Refinement

## What changed from V4

Round 8 revealed that the V4 `patch()` old_string strategy matters. The Reviewer in Round 7
successfully replaced a pending `**Reviewer:**` placeholder line (GM wrote one). But Round 8's
GM did NOT leave a placeholder — the Q's Current code line was directly followed by `\n\n## ADR:`.

The V5 protocol handles BOTH cases by using a multi-line old_string that spans:
```
**Current code:** `...` (line ~N)\n\n## ADR: ...
```

This works whether there's a pending `**Reviewer:**` line or not, because the patch inserts the Reviewer
response at the `\n\n## ADR:` boundary.

## The 6 Steps (V5 — exact)

1. **Read Q section only:** `read_file(sidecar, offset=Q_LINE, limit=20)`
   - Q_LINE from `grep -n "### Q8" <sidecar>`

2. **Get timestamp:** `terminal('date +%H:%M:%S')`

3. **Read timeline section:** `read_file(session_doc, offset=11, limit=12)`
   - Timeline starts around line 11. Find the LAST entry to anchor the append.

4. **Patch sidecar:**
   ```python
   patch(
     path=sidecar,
     old_string="**Current code:** `...exact current code line...`\n\n## ADR: No Silent Fallback...",
     new_string="**Current code:** `...exact current code line...`\n\n**Reviewer:** <your response>\n\n## ADR: No Silent Fallback..."
   )
   ```
   - Match the `## ADR` heading that follows Q8 — it's the universal anchor.
   - Do NOT match a pending `**Reviewer:**` placeholder — V5 inserts before ADR unconditionally.

5. **Patch timeline:** `patch(session_doc, old_string=<last timeline entry>, new_string=<entry + new entry>)`

6. **STOP immediately.**

## Round 8 results

| Subagent | Duration | Patch result |
|----------|----------|-------------|
| GM Round 8 | 91.41s | Q8 written, timeline updated |
| Reviewer V1 | stuck → stopped | Got into search_files loop |
| Reviewer V2 (respawn) | 51.25s | Both patches on first attempt |

V5 Reviewer (51.25s) is the fastest ever — 64% faster than Round 5 V3 (141s) and 51% faster
than Round 6 V3 (183s). The explicit old_string pattern with `## ADR` as anchor is reliable.

## GM context overload fix (applied Round 8)

Round 3 GM took 258s because it read the full 17K+ sidecar. The fix:
- GM runs `grep -n "### Q" sidecar | tail -1` to find the LATEST Q line number
- GM reads only that Q section: `read_file(sidecar, offset=that_line, limit=20)`
- GM does NOT read the full sidecar for any round N≥2

Round 8 GM used this pattern and completed in 91.41s (no watchdog steer needed).
