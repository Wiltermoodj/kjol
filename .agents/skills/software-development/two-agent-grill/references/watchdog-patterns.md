# Steer Timeout Watchdog — Known Patterns

## What "stuck" looks like (from pilot transcripts)

### Pattern 1: Thinking block after file read
```
Subagent reads pos-adapter.ts (181 lines, 6.8K chars) at T+22s
→ Log shows `thinks` at T+25s
→ Log stagnant for 144s (T+25s to T+169s)
→ No `tool` or `result` entries during thinking block
→ Steer queued at T+170s arrives as `missed_steer`
→ Total stall: 169s before subagent finally produces Q1
```

**Trigger:** Large context payload causes the model to deliberate all 10 questions simultaneously before writing Q1.

**Fix:** Pass the code file path in the goal (absolute path) and tell the subagent to read ONLY the code file — NOT the sidecar or session doc. Strip sidecar content from context.

### Pattern 2: CWD mismatch → read_file fails
```
Subagent starts at /Users/lappier (home dir, NOT project dir)
→ read_file('apps/integration/src/lib/pos-adapter.ts') → "File not found"
→ Path resolves to /Users/lappier/apps/integration/src/lib/pos-adapter.ts
→ search_files returns 0 results (wrong CWD) → 60s timeout
→ Falls back to terminal `find` → another 60s timeout
→ Eventually finds files, reads them
```

**Fix:** Use **absolute paths** in the goal text. The `workdir` parameter on `delegate_task` does NOT change the subagent's CWD — confirmed in test. Always pass full paths like:
```
/Users/lappier/code/projects/middlewarez/apps/integration/src/lib/pos-adapter.ts
```

### Pattern 3: Reviewer reads entire 12K+ sidecar
```
Reviewer reads full sidecar (12452 chars)
→ Log shows `thinks` — no further tool calls for 104s
→ Steer queued → arrives as `missed_steer`
→ Reviewer writes response but to WRONG Q1 (v1 Q1 at line 72, not v2 Q1 at line 89)
```

**Fix:** Use `read_file(path, offset=N, limit=M)` to read only the relevant section. Find the Q line first with `grep -n "### Q{N}" <path>`, then tell subagent the exact line number. Result: 31.62s vs 161s+ for full-file read.

### Pattern 4: patch() fails with "match not found"
```
Reviewer tries patch() → "Could not find a match for old_string"
→ Reviewer doesn't know how to proceed — gets stuck
```

**Fix:** Tell subagent to read exact lines first, then copy `old_string` from what it read.

### Pattern 5: Steer arrives as missed_steer
```
Watchdog fires → queues steer → subagent in thinking block
→ Steer text appended to subagent's NEXT tool result
→ Subagent sees steer AFTER producing output
→ "steer did not land" reported
```

**Fix:** After queueing steer, wait 15s. If no log activity → `stop` the subagent → restart with simpler prompt.

## Watchdog timing recommendations

| Context size | Timeout threshold | Rationale |
|---|---|---|
| Code only (~7K chars) | 90-120s | Subagent needs time to read + think through 3 options |
| Code + sidecar (15K+ chars) | DO NOT pass sidecar | Causes 100+ second thinking blocks |
| Restart (reduced context) | 45s | Subagent already read the file, force output |

## Steer message template (keep it short!)

Good (≤15 words):
```
TIMEOUT. Write Q1 NOW. No planning. Stop after Q1.
```

Bad (>100 words):
```
TIMEOUT — produce your output now. Do not continue working. Write your first design question (Q1) to the sidecar at /Users/lappier/code/projects/middlewarez/...
```

**Rule:** Steer messages ≤ 15 words.

## Subagent persistence pattern

**Leaf subagents exit after completing their task.** They do NOT stay alive waiting for steers. When a subagent finishes its generation, it exits with `status=completed`. A subsequent `steer` to that `subagent_id` will fail with "No live subagent".

**To run multiple rounds:** Spawn a NEW subagent per round. Accept ~5-10s spawn overhead per round. Do NOT tell subagents to "wait for next steer."

## Absolute paths reference

```python
delegate_task(
    goal="1. Read /Users/lappier/code/projects/middlewarez/apps/integration/src/lib/pos-adapter.ts\n2. Write to /Users/lappier/code/projects/middlewarez/apps/integration/src/lib/pos-adapter.ts.md",
    context="Absolute paths only. No workdir param.",
    role='leaf'
)
```

**DO NOT** pass `workdir='...'` — it's silently ignored.