---
name: two-agent-grill
description: Hash-polling single-Q-per-cycle grill with model separation and Verifier finalization.
version: 2.5.5
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [stubs, grilling, design-review, subagent, code-quality, orchestration, polling, feature-expansion, doc-gap-analysis, infrastructure-extension, feature-inference]
    related_skills: [stubs-sidecar-workflow, shopify-pos-integration]
---

# Two-Agent Grill v2.5

> **WHEN TO USE:** A module has non-obvious design tradeoffs that need debate. Two subagents with different model profiles coordinate via completion hashes — one question per cycle.

---

## Architecture

```
Master Agent (strong model, e.g. gpt-4o)
  ├── Generate SESSION_TOKEN (8-char hex)
  ├── Create: sidecar + session doc + planning dir
  ├── Read code → pre-write Q{N} + <!--TOKEN_GM_Q{N}_DONE--> at line (ADRLINE-1)
  ├── Spawn Reviewer (step-3.7-flash:free) via `hermes chat -q` CLI
  │   → polls for hash → reviews Q{N} → writes <!--TOKEN_R_Q{N}_DONE-->
  ├── Repeat Q cycle (Q2, Q3, …) — Reviewers can spawn in PARALLEL
  ├── Extract qa-bundle → spawn Verifier → writes proposed-decisions.md
```

> **MODEL SEPARATION:** GM (Master Agent) = strong model (gpt-4o). Reviewer = `stepfun/step-3.7-flash:free`.
> Different profiles = natural disagreement.

> **REVIEWER SPAWN METHOD (v2.5.2):** Use `hermes chat -q "$(cat <prompt.txt>)"` to spawn Reviewer as a real subprocess — the `--query-file` flag does NOT exist in the Hermes CLI. The query content must be passed via `-q` with shell expansion of `cat`:
>
> ```bash
> hermes chat -q "$(cat /tmp/reviewer-{TOKEN}-q{N}.txt)" \
>   -m stepfun/step-3.7-flash:free -t file -Q --max-turns 12
> ```
>
> Do NOT use `delegate_task` inside subagent context — it is unavailable. Multiple Reviewers can run in parallel (one per domain) for a 4× wall-time speedup. See `references/master-agent-orchestration-patterns.md`.

> **COMPLETION HASHES:** At line (ADR_LINE - 1), format: `<!--{TOKEN}_GM_Q{N}_DONE-->` / `<!--{TOKEN}_R_Q{N}_DONE-->`

---

## Step 1 — Setup

```bash
SESSION_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(4))")
# Run preflight to get ADR_LINE
python3 ~/.hermes/skills/software-development/two-agent-grill/scripts/preflight.py --code <code> --sidecar <sidecar> --session <session>
# Output: QCOUNT=NN ADRLINE=NN
```

> **GM subagent NOT spawned (v2.5.2):** The Master Agent pre-writes Qs directly. In Rounds 1-2 of the trail-tune test, GM subagents via `delegate_task` stalled 183-245s without producing output. The Master Agent pre-writing Qs is reliable and faster.

---

## Step 2 — Q-N Cycle (repeat per question)

### Pre-write Q{N} (Master Agent writes directly)

Read the code, formulate a focused question with A/B/C options + recommendation + code reference. Insert before `## Proposed ADR` at line `{ADR_LINE}`. Write `<!--{TOKEN}_GM_Q{N}_DONE-->` at line `{ADR_LINE} - 1`.

### Spawn Reviewer (via hermes CLI, polls for hash)

```bash
# Write Reviewer prompt to a temp file, then spawn via CLI
cat > /tmp/reviewer-{TOKEN}-q{N}.txt << 'EOF'
Design Reviewer for <MODULE>.

Read line {ADR_LINE-1} of <sidecar> for <!--{TOKEN}_GM_Q{N}_DONE-->.
When found, review Q{N} only:
1. read_file(sidecar, offset=<Q{N}_line>, limit=15)
2. patch() after Q{N}'s Current code line:
   **Reviewer:** <1 sentence>
   **Verdict:** Agree / Partially agree / Disagree
   **Reasoning:** <1-3 sentences>
   **Risk:** <1 sentence>
3. Write <!--{TOKEN}_R_Q{N}_DONE--> at line {ADR_LINE-1}. STOP.
EOF

# Spawn Reviewer subprocess — runs parallel-safe
hermes chat -q "$(cat /tmp/reviewer-{TOKEN}-q{N}.txt)" \
  -m stepfun/step-3.7-flash:free -t file -Q --max-turns 12
```

### Master Agent waits for R_Q{N}_DONE hash, then writes Q{N+1}

---

## Step 3 — Phase 2 Optimizations

Steer GM (fresh spawn):
> "Write 3-5 obvious improvements to session doc. Then write <!--{TOKEN}_GM_OPT_DONE-->."

Spawn Reviewer:
> Poll for `<!--{TOKEN}_GM_OPT_DONE-->`, review optimizations, write `<!--{TOKEN}_R_OPT_DONE-->`.

---

## Step 4 — Verifier

```python
delegate_task(
    goal="""Verifier for <MODULE>.

1. Read: <knowledge/planning/<domain>/docs/qa-bundle.md>
2. Rate each Q&A 1-5. Write PROPOSED decisions to separate review doc.
3. STOP.""",
    context="QA bundle: .../qa-bundle.md. Output: .../proposed-decisions.md.",
    role='leaf'
)
```

> **ADR ownership rule (v2.5.2):** The Verifier writes proposed decisions to a review document
> (e.g. `knowledge/planning/<domain>/proposed-decisions.md`), NOT into the live application's
> ADR files. Sidecar `## ADR` sections should be labeled `## Proposed ADR` instead.
> Human review is required before any ADR becomes a real decision.
>
> **Path note (v2.5.5):** The original template used `/Users/lappier/code/projects/...`. Use the actual working directory (`pwd`) — on this environment, repos live at `~/code/projects/<repo>`. The Verifier's `context` and `goal` must reference real paths.

---

## Event-Driven Orchestrator Pattern (v2.5.3 — Trail-tune-new)

**Problem:** Running all domains in one Master Agent causes context accumulation → 180-300s thinking blocks.

**Solution:** Event-driven cronjob that processes ONE domain per tick with fresh context:
- **Monitor script** (`grill-pipeline-monitor.sh`) checks for ungrilled domains + git sync state
- **Orchestrator script** (`grill-orchestrator-v3.py`, `no_agent=true`) runs per tick:
  1. Analyzes code structure (extracts patterns: legacy, firestore, batch_writes, null, etc.)
  2. Generates Q1+Q2 via **templates** (no LLM needed for GM role — eliminates thinking blocks)
  3. Writes sidecar with GM hashes
  4. Spawns Reviewer subprocess via `hermes chat` CLI (step-3.7-flash:free)
  5. Waits for R hashes, reports verdicts
- **Each tick = one domain = fresh context** → no context carryover

**Key files:**
- `~/.hermes/scripts/grill-orchestrator-v3.py` — orchestrator (no_agent=true)
- `~/.hermes/scripts/grill-pipeline-monitor.sh` — monitor (git sync + ungrilled detection)

**Cronjob setup:**
```bash
cronjob create --name "two-agent-grill-trail-tune-orchestrator-v3" \
  --schedule "every 2m" \
  --monitor_script "grill-pipeline-monitor.sh" \
  --script "grill-orchestrator-v3.py" \
  --deliver "telegram:8951222762"
```

**Git sync enforcement:** Monitor checks `git rev-list --count @{u}..HEAD`. If > 0 (local ahead), output is STABLE (suppresses trigger) AND orchestrator exits code 3. User must push or stash before continuing.

**Verified:** First domain (`advanced-search-service.ts`) completed in ~410s with Agree/Agree verdicts. R hashes written correctly.

---

## Watchdog

- **Hash polling timeout:** 300s. If GM never writes hash → report timeout, Master Agent retries.
- **No thinking-time limit:** Per user decision (2026-08-30), subagents may think for 200s+ as long as they produce output. The 120s threshold applies to **output delivery** — if a subagent produces zero tool calls / patches / responses after 120s, steer: `TIMEOUT — produce your output now.`
- **Polling timeout:** Reviewer polls for 300s. If no GM hash → report timeout, Master Agent retries.
- **Steer retry protocol:** If steer text does not land after 15s (subagent still in deep thinking block), escalate to `delegate_task(action='stop')` and re-dispatch with reduced scope. A stopped and re-dispatched subagent gets a fresh context window.

---

# Pitfalls (v2.5.4)
## Pitfalls (v2.5.5)
- **CLI `--query-file` flag does not exist (v2.5.5):** The skill documentation references `hermes chat --query-file <prompt.txt>`, but the Hermes CLI does not support this flag. Use `hermes chat -q "$(cat <prompt.txt>)"` instead — the query content is passed via shell expansion of `cat` into the `-q` (query) parameter. Attempting `--query-file` produces `hermes: error: unrecognized arguments`.
- **Model name discovery across providers (v2.5.5):** When spawning subagents with `hermes chat -m <model>`, the model name must match what the configured provider's API accepts. On the Nous provider, `gpt-4o` returns `HTTP 404: Model 'gpt-4o' not found`. Use `hermes config` to check the active provider and model, and `grep default ~/.hermes/config.yaml` for the configured model. A fallback chain (`fallback_providers: []`) in config.yaml has no entries set, so model failures are fatal. Fix: use the provider's native model name (e.g., `poolside/laguna-s-2.1:free` on Nous, `stepfun/step-3.7-flash:free` for reviewers) or check available models via `hermes model`.
- **GM subagent stalling (v2.5.2):** GM subagents spawned via `delegate_task` stall 180-250s reading code + formulating Q without producing output. The 120s output-delivery watchdog steer arrives too late. **Fix:** Master Agent pre-writes Qs directly — no GM subagent.
- **8-domain context overload (v2.5.4):** A single Master Agent processing many domains simultaneously accumulates context across files → 300s+ thinking blocks with no output. **Fix:** Use per-domain dispatch — one Master Agent (or no_agent cronjob) per domain, fresh context each time. See "Event-Driven Orchestrator Pattern" below.
- **no_agent=true scope bug (v2.5.4):** Orchestrator scripts run under `no_agent=true` execute as bare Python/bash — any variable defined in a `def` function is NOT available at module scope. **Fix:** Define skip lists, constants, and helper functions at module level, not inside functions that are never called.
- **Reviewer omits R hashes (v2.5.4):** Reviewers follow instructions literally. "DO NOT modify GM hash lines" is insufficient — if the prompt doesn't explicitly say "write the R hash marker on its own line after your review," the Reviewer will omit it. **Fix:** Reviewer prompt MUST include an explicit numbered step: "After the review block, write `<!--{TOKEN}_R_Q{N}_DONE-->` on its own line."
- **CWD mismatch** — `/Users/lappier` default. Use absolute paths in all scripts.
- **Timing coordination** — eliminated by hash polling at fixed line.
- **Q-number tracking** — eliminated. Reviewer polls for Q{N}_DONE, reviews that specific Q.
- **Multi-Q thinking stalls** — eliminated by single-Q-per-cycle. Each subagent holds 1 Q.
- **Cross-session hashes** — eliminated by 8-char random SESSION_TOKEN.
- **Full sidecar reads** — eliminated. Reviewer reads Q section with offset/limit only. Extra research (search_files, session_search) is acceptable per v2.5 protocol.
- **ADR ownership** — ADRs require human review. The Verifier writes PROPOSED decisions to a separate review document, NOT into the live application's ADR sections. Sidecars may include an "## Proposed ADR" section, but these do not become decisions until approved by a human.
| **Verdict extraction race + regex (v2.5.5):** The Reviewer model (`step-3.7-flash:free`) writes its review content (including Verdict, Reasoning, Risk) BEFORE the R hash marker. The R hash is a completion flag inserted at the end of the review block. **Fix:** (1) After detecting R hashes, poll 15-30s for verdict text. (2) Use regex `Verdict[^:]*:\s*(Agree|Partially agree|Disagree)` to match both `**Verdict:** Agree` and `Verdict: Agree` formats. (3) Scan the 1000 chars BEFORE the R hash marker for Q1, or between R hash and GM hash for Q2. (4) Apply regex to the split section (Q1 vs Q2) — never the whole file at once to avoid cross-contamination.
- **Verdict regex gaps found in production (v2.5.5/v2.5.6):** Running `grill-middlewarez-orchestrator.py` on `cron/cleanup/route.ts` exposed two real extraction failures. (1) The verdict alternation `(Agree | Partially agree | Disagree)` does NOT match the Reviewer's `Partially disagree` verdict — `extract_verdict` silently returned `Unknown` while the review text and rating (2) were correct in the sidecar. (2) The simplified line regex also fails on the `**Verdict:** <value>` format when the colon sits INSIDE the markdown bold — it latches onto the colon between `Verdict` and the closing `**` and then cannot align on the verdict value. **Fix applied** to `~/.hermes/scripts/grill-middlewarez-orchestrator.py`: find the Verdict line with a MULTILINE match on the word Verdict, strip all bold asterisks, strip the `Verdict` label plus surrounding colons/whitespace, then canonicalize case-insensitively against an expanded alias set (adds `Partially disagree`, `Strongly agree`, `Strongly disagree`). Verified on the live sidecar: Q1 = Partially agree (3), Q2 = Partially disagree (2). Always re-extract after patching — the sidecar review text is authoritative; never trust the plan-file verdict until extraction is verified.
- **Filename extension handling (v2.5.4):** `os.path.basename(f).replace(".ts", "")` on `file.ts.md` produces `file.md` — the `.ts` match inside `.ts.md` is stripped first. **Fix:** Always use `.replace(".ts.md", "")` to strip the full extension. This bug caused 0 domains to be found in orchestrators processing nested repo structures.
- **Regex backslash escaping in Python raw strings (v2.5.7):** Writing `r"Verdict.*?\\s*(Agree...)"` in a Python raw string produces the regex pattern `Verdict.*?\\s*` where `\\s` is a literal backslash-s, NOT the regex `\s` whitespace wildcard. This silently matches zero characters, causing `extract_verdict` to return "Unknown" even when the verdict text exists in the sidecar. **Fix:** Use single backslash in raw strings: `r"Verdict[^:]*:\s*(Agree|Partially agree|Disagree)"`. In a raw string, `\s` is the regex whitespace class. Verified: the existing v2.5.5 pitfall regex `Verdict[^:]*:\\s*` was wrong — the `\\s` must be `\s` in the actual regex string.
- **poll_for_verdict function pattern (v2.5.7):** After detecting R hashes via `poll_for_hash()`, call `poll_for_verdict()` BEFORE `extract_verdict()`. This function reads the sidecar every 2s for 30s looking for "Verdict" in the post-hash region. Without this, 30% of verdicts return "Unknown" because the Reviewer subprocess writes the R hash marker in its patch() call BEFORE writing the review text — the hash appears in the diff first, the verdict text comes 5-15s later. Implementation:
```python
def poll_for_verdict(sidecar_path, token, q_num, timeout_s=30):
    hash_marker = f"<!--{token}_R_Q{q_num}_DONE-->"
    elapsed = 0
    while elapsed < timeout_s:
        content = Path(sidecar_path).read_text()
        idx = content.find(hash_marker)
        if idx >= 0:
            if "Verdict" in content[idx:idx + 2000]:
                return True
        time.sleep(2)
        elapsed += 2
    return False
```

## Concurrent Multi-Repo Sessions (v2.5.4)

> **WHEN TO USE:** Running two-agent-grill on multiple repositories simultaneously with separate orchestrator sessions.

### Architecture
Each repository gets its OWN independent cronjob pair:
- **Standard grill cronjob** (`no_agent=true`, every 2m) — processes one domain per tick
- **FE completer cronjob** (`no_agent=true`, every 2m) — fires only when standard grill completes

```text
Repo A: cntrl-grill-standard ───> cntrl-grill-fe-completer
Repo B: cntnr-grill-standard ───> cntnr-grill-fe-completer
```

### Key Patterns
1. **Per-repo orchestrator scripts** — each repo gets its own orchestrator (`grill-{repo}-orchestrator.py`) with repo-specific code pattern detection and Q1/Q2 templates matched on file paths and content keywords
2. **Per-repo monitor scripts** — each repo gets its own monitor (`grill-{repo}-monitor.sh`) that finds ungrilled domains in that repo's directory structure
3. **FE chain trigger** — the FE completer's monitor (`grill-{repo}-fe-monitor.sh`) checks if ALL domains have R hashes. Only when complete does it return `STATUS=ALL_GRILLED`, triggering the FE completer cronjob. Until then, it returns `STATUS=STANDARD_GRILLED_IN_PROGRESS` (stable output → suppressed)
4. **Git sync enforcement** — each monitor independently checks `git rev-list --count @{u}..HEAD` and suppresses if local is ahead
5. **Fresh context per tick** — each cronjob invocation is `no_agent=true`, so no context accumulates across domains or repos

### Adaptation Template
To add a new repo:
1. Copy `grill-{existing}-orchestrator.py` → `grill-{new}-orchestrator.py`
2. Change `REPO`, `WORKSPACE`, `PLAN_FILE`, `COMPLETION_FILE` paths
3. Update `find_ungrilled_domains()` to match the repo's directory structure (e.g., `src/services/*.ts` vs `lib/**/*.ts` vs `app/api/**/route.ts`)
4. Update `analyze_code()` pattern detection for repo-specific keywords
5. Update `generate_q1()` / `generate_q2()` archetype templates for the repo's domain
6. Create corresponding monitor scripts (`grill-{new}-monitor.sh`, `grill-{new}-fe-monitor.sh`, `grill-{new}-fe-trigger.sh`)
7. Register two cronjobs: standard + FE completer

### Verified Concurrent Run
- **CNTRL repo** (236 domains): `cntrl-grill-standard` + `cntrl-grill-fe-completer` running
- **CNTNR repo** (18 domains): `cntnr-grill-standard` + `cntnr-grill-fe-completer` running
- Both run every 2m, each processing ONE domain per tick in parallel
- No resource contention (separate Reviewer subprocesses, separate files, separate plan files)
- Git sync enforced independently per repo

### Pitfall: Reviewer timing in concurrent mode (v2.5.4)
When Reviewers are spawned via `subprocess.Popen` (non-blocking), they run in parallel. The orchestrator must poll for BOTH:
1. R hash presence (hash-polling pattern)
2. Verdict text (after hash appears, Reviewer may still be writing)

**Fix:** Poll 60× at 5s intervals (up to 300s) after hashes detected, with regex `Verdict[^:]*:\s*(Agree|Partially agree|Disagree)` to match both `**Verdict:** Agree` and `Verdict: Agree` formats. Also check the region BEFORE the R hash (reviewers write verdict text before the hash, not after).

### Pitfall: Orchestrator timeout in cronjob context (v2.5.4)
The `no_agent=true` cronjob script runs as a bare Python process. If Reviewers take 250-400s each and the orchestrator polls for 420s, the total execution can exceed the cronjob's 2-minute tick interval. **This is safe** — the event-driven monitor only triggers a new tick when its output changes (ungrilled domain count changes), so no overlapping executions occur.

---

## Event-Driven Orchestrator Pattern (v2.5.4 — Trail-tune-new Full Run)

**Problem:** Running all domains in one Master Agent causes context accumulation → 180-300s thinking blocks. Even 2-domain Master Agents stall 60-90s formulating Q1+Q2.

**Solution:** Event-driven cronjob with **template-based Q generation** — no LLM needed for the GM role at all:
- **Monitor script** (`grill-pipeline-monitor.sh`) checks git sync + ungrilled domains. Output is hashed; unchanged = suppress trigger. If `git_ahead > 0`, output is STABLE (suppresses run) AND orchestrator exits code 3.
- **Orchestrator script** (`grill-orchestrator-v3.py`, `no_agent=true`) runs per tick:
  1. Analyzes code structure (pattern detection: `legacy`, `firestore`, `batch_writes`, `null`, `has_interface`, `mock`, etc.)
  2. Generates Q1+Q2 via **fixed templates** matched on code patterns — zero LLM reasoning for GM role
  3. Writes sidecar with `okfVersion 2.5.1` header + `## Grilling & Discussion` + `## Proposed ADR` + `## Obvious Optimizations`
  4. Spawns Reviewer subprocess via `hermes chat -q "$(cat <prompt>)"` CLI (step-3.7-flash:free, file toolset)
  5. Polls for R hashes at 5s intervals (up to 300s)
  6. Appends results to plan file (de-duplicates by domain name)
- **Each tick = one domain = fresh context** → no context accumulation, no thinking-block stalls

**Key files:**
- `~/.hermes/scripts/grill-orchestrator-v3.py` — orchestrator (no_agent=true, template-based)
- `~/.hermes/scripts/grill-pipeline-monitor.sh` — monitor (git sync + ungrilled domain detection)

**Cronjob setup:**
```bash
cronjob create --name "two-agent-grill-trail-tune-orchestrator-v3" \
  --schedule "every 2m" \
  --monitor_script "grill-pipeline-monitor.sh" \
  --script "grill-orchestrator-v3.py" \
  --deliver "telegram:<target_chat_id>"
```

**Verified:** 64 domains completed across trail-tune-new codebase with real Reviewer verdicts (44 Agree / 16 Partially agree / 0 Disagree on Q1). No thinking-block stalls. Git sync enforcement active.

**Cross-repo reuse (v2.5.4):** The same pattern was applied successfully to the CNTRL repo (`grill-cntrl-orchestrator.py` / `grill-cntrl-monitor.sh`). Key adaptation: the orchestrator's `analyze_code()` and `generate_q1/q2()` functions use different code patterns (security, resilience, oauth, streaming, git, pty, kanban, cli) matched on file paths and content keywords. The core hash-poll + Reviewer subprocess pattern is unchanged.

**FE completion notification pattern (v2.5.4):** For multi-phase pipelines (standard grill → FE), use a **two-cronjob chain**: the FE monitor (`grill-cntrl-fe-monitor.sh`) checks if all domains have R hashes — when complete, it returns `STATUS=ALL_GRILLED` which triggers the FE completer cronjob. The FE completer's monitor (`grill-cntrl-fe-trigger.sh` or `grill-cntrl-fe-monitor.sh`) suppresses when no domains need FE, providing natural termination.

> **CRITICAL — Verdict extraction timing (v2.5.4):** After detecting R hashes, poll an additional 15-30s (5s intervals) for `**Verdict:**` text to appear. The Reviewer model (`step-3.7-flash:free`) writes the R hash marker in its `patch()` call BEFORE writing the review text — the hash appears first in the diff, the verdict comes after. Failing to wait produces "Unknown" verdicts. Fix: poll for verdict count, not just hash presence.

> **Feature Expansion tested on 4 domains** — 3 Agree, 1 Partially agree (genuine pushback on premature abstraction). Feature proposals are NOT ADRs — they require human review before implementation.

---

## References
- `references/v25-round{1,2,3,4}-results.md` — Round results from cross-codebase tests
- `references/v25-trail-tune-decisions-report.md` — Compiled decisions report (4 domains)
- `references/v254-event-driven-test-results.md` — v2.5.4 event-driven pipeline test results (60 domains)
- `references/concurrent-multi-repo-grill.md` — Concurrent multi-repo setup (CNTRL + CNTNR), monitor hash caching bug, race condition fix, git_ahead advisory pattern
- `references/feature-expansion-question-archetypes.md` — Design rationale for new category
- `references/sidecar-format-v2.md` — Sidecar format specification
- `references/session-log-kjol-grill.md` — Session log: two-agent grill on kjol KjolHelper daemon (CLI patterns, model discovery, timing observations)
- `references/event-driven-orchestrator-kjol-pattern.md` — Full orchestrator pattern with kjol/middlewarez adaptations, verdict extraction timing, and template-based Q generation
- `scripts/verify-sidecars.py` — Post-run verification script for verdict extraction
- `scripts/grill-manual-runner.py` — Orchestrator script for manual (non-cron) grill sessions: spawns parallel Reviewers via CLI, polls for R hashes, extracts verdicts
- `scripts/grill-kjol-orchestrator.py` — kjol-specific orchestrator with Swift pattern detection and hash-polling verdict extraction (event-driven, one domain per tick)
- `references/cntrl-orchestrator-template.md` — Template for adapting the orchestrator to new repos
- `references/adapting-to-new-repo.md` — Quick-start guide for extending the pipeline to a new repository (file structure, cronjob registration, common pitfalls)

---

## Feature Expansion Grill (v2.5.4)

> **WHEN TO USE:** The workers only refined existing code — no new feature decisions emerged from any grill session. This category adds the missing layer: grill sessions that infer new functionality from documentation gaps and existing infrastructure patterns.

### Problem
Standard two-agent grill questions are **maintenance-oriented**: "Should we extract this mock?" rather than "What should we build next?" The 60-domain run confirmed 100% of decisions were refinements (73% Agree, 27% Partially agree, 0% new-feature proposals).

### Solution: Three New Question Archetypes

1. **Doc-Gap Discovery**
   - Template base: `## Documentation Gap Analysis`
   - Question: "Existing documentation describes feature X but code only implements Y. What's missing?"
   - GM generates from: reading `docs/`, `README.md`, `ARCHITECTURE.md`, inline JSDoc comments
   - Reviewer evaluates: does the gap warrant implementation? What's the minimal viable extension?

2. **Infrastructure Extension**
   - Template base: `## Pattern-Inferred Extension`
   - Question: "Based on existing infrastructure patterns (retry, auth middleware, connection pooling), what additional services/endpoints could be built?"
   - GM generates from: analyzing existing patterns in sibling files
   - Reviewer evaluates: feasibility, alignment with architecture, effort estimate

3. **Feature Inference**
   - Template base: `## Architecture-Inferred Feature`
   - Question: "Given this module's current architecture, what would the natural next steps be?"
   - GM generates from: layer analysis, dependency graph, ADR history
   - Reviewer evaluates: does this match the project's stated roadmap?

### Integration

#### Sidecar Template Extension
Add `## Feature Expansion` section AFTER `## Proposed ADR`:
```
## Feature Expansion

### Feature Proposal
**Inferred from:** <doc_gap | infrastructure_pattern | architecture_layer>

**Proposed enhancement:** <description>

**Current gap:** <what's missing in code vs docs>

**Implementation path:**
1. <step 1>
2. <step 2>
3. <step 3>

**Dependencies:** <existing infra this builds on>

**Effort estimate:** <rough T-shirt size: S/M/L>

**Reviewer's assessment:** <Agree / Partially agree / Disagree>

**Reviewer's reasoning:** <why or why not>
```

#### Orchestrator Template Addition
Add `generate_expansion_q(domain_file, analysis)` function to `grill-orchestrator-v3.py`:
- Runs AFTER standard Q1+Q2 if `--feature-expansion` flag is passed
- Uses the same hash-poll pattern: `<!--{token}_FE_Q_DONE-->`
- Spawns a **third** Reviewer for the feature proposal

#### CLI Usage
```bash
# Standard grill (Q1+Q2 refinement only)
grill-orchestrator-v3.py --domain src/services/foo.ts

# With feature expansion
grill-orchestrator-v3.py --domain src/services/foo.ts --feature-expansion

# Full domain sweep with feature expansion
grill-orchestrator-v3.py --all --feature-expansion
```

#### Output Location
Feature proposals written to: `knowledge/planning/{domain}/feature-proposals.md` (not sidecars).
These are **explicitly NOT ADRs** — they're feature proposals requiring human review.

### ADR Ownership Rule
- `## Proposed ADR` in sidecars = design decisions (refinement)
- `## Feature Expansion` in sidecar = feature proposals (NEW functionality)
- Both require human review — agents propose, humans decide

---

## Concurrent Multi-Repo Sessions (v2.5.4)

> **WHEN TO USE:** Running two-agent grill on multiple repositories simultaneously with separate orchestrator sessions.

### Architecture
Each repository gets its OWN independent cronjob pair:
- **Standard grill cronjob** (`no_agent=true`, every 2m) — processes one domain per tick
- **FE completer cronjob** (`no_agent=true`, every 2m) — fires only when standard grill completes

```
Repo A: cntrl-grill-standard ───> cntrl-grill-fe-completer
Repo B: cntnr-grill-standard ───> cntnr-grill-fe-completer
```

### Key Patterns
1. **Per-repo orchestrator scripts** — each repo gets its own orchestrator (`grill-{repo}-orchestrator.py`) with repo-specific code pattern detection and Q1/Q2 templates matched on file paths and content keywords
2. **Per-repo monitor scripts** — each repo gets its own monitor (`grill-{repo}-monitor.sh`) that finds ungrilled domains in that repo's directory structure
3. **FE chain trigger** — the FE completer's monitor (`grill-{repo}-fe-monitor.sh`) checks if ALL domains have R hashes. Only when complete does it return `STATUS=ALL_GRILLED`, triggering the FE completer cronjob. Until then, it returns `STATUS=STANDARD_GRILLED_IN_PROGRESS` (stable output → suppressed)
4. **Git sync enforcement** — each monitor independently checks `git rev-list --count @{u}..HEAD` and suppresses if local is ahead
5. **Fresh context per tick** — each cronjob invocation is `no_agent=true`, so no context accumulates across domains or repos

### Adaptation Template
To add a new repo:
1. Copy `grill-{existing}-orchestrator.py` → `grill-{new}-orchestrator.py`
2. Change `REPO`, `WORKSPACE`, `PLAN_FILE`, `COMPLETION_FILE` paths
3. Update `find_ungrilled_domains()` to match the repo's directory structure (e.g., `src/services/*.ts` vs `lib/**/*.ts` vs `app/api/**/route.ts`)
4. Update `analyze_code()` pattern detection for repo-specific keywords
5. Update `generate_q1()` / `generate_q2()` archetype templates for the repo's domain
6. Create corresponding monitor scripts (`grill-{new}-monitor.sh`, `grill-{new}-fe-monitor.sh`, `grill-{new}-fe-trigger.sh`)
7. Register two cronjobs: standard + FE completer

### Verified Concurrent Run
- **CNTRL repo** (236 domains): `cntrl-grill-standard` + `cntrl-grill-fe-completer` running
- **CNTNR repo** (18 domains): `cntnr-grill-standard` + `cntnr-grill-fe-completer` running
- Both run every 2m, each processing ONE domain per tick in parallel
- No resource contention (separate Reviewer subprocesses, separate files, separate plan files)
- Git sync enforced independently per repo

### Pitfall: Reviewer timing in concurrent mode (v2.5.4)
When Reviewers are spawned via `subprocess.Popen` (non-blocking), they run in parallel. The orchestrator must poll for BOTH:
1. R hash presence (hash-polling pattern)
2. Verdict text (after hash appears, Reviewer may still be writing)

**Fix:** Poll 60× at 5s intervals (up to 300s) after hashes detected, with regex `Verdict[^:]*:\s*(Agree|Partially agree|Disagree)` to match both `**Verdict:** Agree` and `Verdict: Agree` formats. Also check the region BEFORE the R hash (reviewers write verdict text before the hash, not after).

### Pitfall: Orchestrator timeout in cronjob context (v2.5.4)
The `no_agent=true` cronjob script runs as a bare Python process. If Reviewers take 250-400s each and the orchestrator polls for 420s, the total execution can exceed the cronjob's 2-minute tick interval. **This is safe** — the event-driven monitor only triggers a new tick when its output changes (ungrilled domain count changes), so no overlapping executions occur.