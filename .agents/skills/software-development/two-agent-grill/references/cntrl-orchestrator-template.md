# CNTRL Orchestrator Template

How to adapt the two-agent grill event-driven orchestrator from one repo to another.

## File Structure

```
~/.hermes/scripts/
├── grill-{repo}-orchestrator.py    # Main orchestrator (no_agent=true)
├── grill-{repo}-monitor.sh         # Event-driven monitor (git sync + domain detection)
├── grill-{repo}-fe-completeor.py   # FE completer (optional, runs after standard)
├── grill-{repo}-fe-monitor.sh      # FE monitor (detects completion of standard grill)
└── grill-{repo}-fe-trigger.sh      # FE trigger (fires FE completer when ready)
```

## Adapting the Orchestrator

### 1. Repository Paths
```python
REPO = "/path/to/your/repo"
WORKSPACE = f"{REPO}/src"  # adjust if source is in a different dir
PLAN_FILE = f"{REPO}/knowledge/planning/grill-{repo}-plan.md"
HERMES_CLI = "/Users/lappier/.hermes/hermes-agent/venv/bin/hermes"
```

### 2. Code Pattern Analysis
Customize `analyze_code(ts_file)` for the new repo's patterns:
- Detect imports specific to the repo (e.g., Firestore, OAuth, Redis)
- Detect framework-specific patterns (e.g., Next.js route handlers, API routes)
- Count meaningful lines, detect interfaces/classes/export patterns

### 3. Question Templates
Customize `generate_q1(patterns)` and `generate_q2(patterns)` for the new repo:
- Map code patterns to domain-specific design questions
- Include A/B/C/D options for each template
- Reference actual file paths in questions for grounding

### 4. Feature Expansion Templates
Customize `determine_archetype(patterns)` for the new repo:
- Map existing patterns to FE archetypes (doc_gap, infrastructure_pattern, architecture_layer)
- Include repo-specific proposal text referencing real sibling files

### 5. Domain Discovery
Update `find_ungrilled_domains()`:
```python
# Adjust glob pattern for the repo's structure
for ts_file in sorted(glob.glob(f"{WORKSPACE}/**/*.ts", recursive=True)):
    # Skip patterns specific to this repo
    if any(s in basename_lower for s in REPO_SKIP_PATTERNS):
        continue
```

## Adapting the Monitor

### Standard Monitor (`grill-{repo}-monitor.sh`)
- Update `REPO` and `WORKSPACE` paths
- Adjust test/spec file filtering (`*.test`, `*.spec`, `*-test`, etc.)
- Adjust sidecar spec detection (skip hand-authored specs)
- Adjust minimum line count threshold (default: 100)

### FE Monitor (`grill-{repo}-fe-monitor.sh`)
- Same structure as standard monitor
- Looks for domains with `_R_Q1_DONE-->` but no `## Feature Expansion` section
- Returns `STATUS=ALL_GRILLED` when no FE-needed domains found
- Returns `STATUS=IN_PROGRESS` with count when FE work remains

## Cronjob Setup

```bash
# Standard grill cronjob
cronjob create \
  --name "grill-{repo}-standard" \
  --schedule "every 2m" \
  --monitor_script "grill-{repo}-monitor.sh" \
  --script "grill-{repo}-orchestrator.py" \
  --deliver "telegram:<target_chat_id>"

# FE completer cronjob (auto-triggers after standard is done)
cronjob create \
  --name "grill-{repo}-fe-completer" \
  --schedule "every 2m" \
  --monitor_script "grill-{repo}-fe-monitor.sh" \
  --script "grill-{repo}-fe-completer.py" \
  --deliver "telegram:<target_chat_id>"
```

## Key Constants to Customize

| Constant | Default | Description |
|----------|---------|-------------|
| `REPO` | `/path/to/repo` | Repository root path |
| `WORKSPACE` | `{REPO}/src` | Source code directory |
| `GM_MODEL` | `poolside/laguna-s-2.1:free` | Master Agent model |
| `REVIEWER_MODEL` | `stepfun/step-3.7-flash:free` | Reviewer model |
| `MIN_LINES` | 100 | Minimum file size to process |
| `SKIP_NAMES` | see script | Hardcoded skip set |

## Verification

After setup, run:
```bash
# Check monitor detects ungrilled domains
bash ~/.hermes/scripts/grill-{repo}-monitor.sh

# Test single domain manually
python3 ~/.hermes/scripts/grill-{repo}-orchestrator.py

# Verify sidecar format
grep "_GM_Q\|_R_Q\|sessionToken" src/path/to/file.ts.md
```
