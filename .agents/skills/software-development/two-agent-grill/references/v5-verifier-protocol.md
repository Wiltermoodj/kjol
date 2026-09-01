# V5 Verifier Protocol — Strict Scope (proven after v2.3 test failure)

The Verifier is the highest-risk subagent for scope-creep. This protocol is mandatory.

## The 3-step rule

1. **Read ONLY** `knowledge/planning/<domain>/docs/qa-bundle.md` — once.
2. **Rate** each Q&A 1-5 and **write** `knowledge/planning/<domain>/decisions.md`.
3. **STOP.**

No `search_files`. No `session_search`. No reading the sidecar, session doc, code, or runbooks.

## Why this is strict (from the v2.3 test)

Verifier v1 in the v2.3 test run:
- Ran `search_files(pos-adapter)` → 0 results
- Ran `session_search` twice on historical sessions
- Read the full 45K sidecar (`pos-adapter.ts.md`)
- Read `test-runner.py` for "expected output format"
- Stalled 120s+ in thinking, needed hard-stop + respawn

Verifier v2 (with "NO RESEARCH" in the goal) still drifted to `session_search` and a full sidecar read, but the steer "re-read qa-bundle.md once, then WRITE decisions.md" recovered it. Final cost: 236s vs the ~30-50s a focused Verifier needs.

## Goal template (copy verbatim, fill `<domain>` and paths)

```
Verifier for <MODULE>. NO RESEARCH. Write decisions.md directly.

You already read the QA bundle earlier (or will read it once now). SKIP all other reads.

CRITICAL — DO EXACTLY:
1. Read ONLY: /Users/lappier/code/projects/middlewarez/knowledge/planning/<domain>/docs/qa-bundle.md
2. Rate each Q&A 1-5 (1=poor, 5=excellent) on: question quality, option divergence, recommendation soundness, reviewer verdict substance.
3. write_file("/Users/lappier/code/projects/middlewarez/knowledge/planning/<domain>/decisions.md", content=decisions)
   Format per Q:
     ## Q{N} — {Topic}
     **Rating:** {score}/5
     **GM Question:** <1 sentence>
     **GM Recommendation:** {letter} — <1 sentence>
     **Reviewer Verdict:** <verdict>
     **Decision:** <final decision + key caveats>
     **Confidence:** High/Medium/Low
   End with:
     ## Summary
     - Total Q&As: N
     - Average rating: X/5
     - All decisions: [bulleted list]
4. STOP immediately after writing.

DO NOT use search_files. DO NOT use session_search. DO NOT read the sidecar or any other file.
If you did not already read the bundle, read it ONCE via read_file, then write — nothing else.
```

## Failure table

| Symptom | Cause | Fix |
|---------|-------|-----|
| `search_files` / `session_search` calls | Goal too permissive ("Read qa-bundle + session doc") | Rewrite goal with explicit "NO RESEARCH" + forbidden-tool list |
| Reads full 45K sidecar | Looking for "full Q&A content" | Bundle already has Q+recommendation+verdict. That is enough. |
| 120s+ thinking loop | Drifting into tangential research | Fire 120s watchdog steer: "re-read qa-bundle.md once, then WRITE decisions.md. Stop." |
| decisions.md never written | Stuck before write_file | Hard-stop + respawn with strict goal above |

## Result from v2.3 test

After applying this protocol, the Verifier produced `decisions.md` (8007 bytes, 8 Q&As) with an average rating of **4.75/5**. All 8 decisions were actionable.
