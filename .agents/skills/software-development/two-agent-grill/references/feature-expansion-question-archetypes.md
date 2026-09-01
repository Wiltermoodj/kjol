# Feature Expansion Question Archetypes — Design Rationale

## Context

After running two-agent grill v2.5.4 across 60 domains in the trail-tune-new codebase, 100% of decisions were refinements of existing code. No new feature proposals emerged.

## Assessment

| Category | Q1 Topics | % | New Features |
|----------|-----------|---|--------------|
| Code organization | 22 | 37% | 0 |
| Interface design | 18 | 30% | 0 |
| Batch strategy | 12 | 20% | 0 |
| Mock data extraction | 4 | 7% | 0 |
| Unclassified | 4 | 7% | 0 |
| **Total** | **60** | **100%** | **0%** |

**Option A (Keep current):** 54/60 domains (90%)
**Option B (Refactor):** 43/60 domains (72%)
**Option C (New functionality):** 11/60 domains (18%) — all "extract/reduce/modify," none "add new feature"

## Problem

Workers only refined existing code — no new feature decisions were proposed.
The question templates systematically bias toward conservative refactoring choices:

- **A (Keep):** 90% of domains
- **B (Extract):** 72% of domains
- Only 11 domains had an "add new" option, and all were minor (retry/backoff, chunking)

## Solution: Three New Question Archetypes

### 1. Doc-Gap Discovery

**Template:**
```
### Q: Documentation Gap Analysis
**GM:** Existing documentation (CONTEXT.md, API.md, README.md, ADR-*) describes [feature X] 
but the code only implements [feature Y]. What's missing and what should be added?

Options:
- **A:** Documentation is ahead of code — add TODO stub matching the documented interface
- **B:** Documentation is aspirational — implement the full described feature
- **C:** Documentation is outdated — update docs to match current code
```

**Example from ai-orchestration-service.ts:**
Documentation mentions a fallback strategy for AI provider failures, but code has none.
The Q asks: implement the documented fallback (B), stub it (A), or update docs (C).

### 2. Infrastructure Extension

**Template:**
```
### Q: Pattern-Inferred Extension
**GM:** [existing-pattern] is used in [sibling-file]. This domain has similar requirements 
but hasn't adopted the pattern. Should it use the same infrastructure?

Options:
- **A:** Keep current approach — the use case is different enough
- **B:** Adopt the existing pattern (copy/adapt infrastructure)
- **C:** Build a generalized wrapper (new shared abstraction)
```

**Example from duplicate-service.ts:**
Hash-based deduplication is used here. Other services (audit, data-health) could reuse 
this pattern for data integrity. Q asks whether to generalize it.

### 3. Feature Inference

**Template:**
```
### Q: Architecture-Inferred Feature
**GM:** [layer] has [capability-A] and [capability-B]. The natural extension is 
[feature-X]. Should this be implemented?

Options:
- **A:** Current scope is correct — don't extend the layer's responsibility
- **B:** Add the inferred capability (minimal extension)
- **C:** Refactor to support multiple inferred capabilities (maximal extension)
```

**Example from tune-engine-impl.ts:**
Physics calculation layers exist. Natural next step: suspension dynamics modeling.
Q asks: keep physics-only (A), add suspension (B), or build a general dynamics engine (C).

## ADR Ownership

These question archetypes generate **feature proposals**, not design approvals:
- Output to `knowledge/planning/{domain}/feature-proposals.md`
- Sidecar section: `## Feature Expansion` (after `## Proposed ADR`)
- **Never implement** — only propose for human review
