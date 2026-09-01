# Sidecar Format v2.5.1

## Header
```
---
okfVersion: "2.5.1"
grill: two-agent-grill
module: src/services/<domain>.ts
sessionToken: <8-char-hex>
lines: <line-count>
---
```

## Standard Sections (v2.5.1)

1. `## Grilling & Discussion` — contains Q1, Q2 (and optionally Q3+)
2. `## Proposed ADR` — proposed decisions (requires human review)
3. `## Obvious Optimizations` — GM-authored optimizations

## Feature Expansion Section (v2.5.4)

### `## Feature Expansion` — appended after `## Obvious Optimizations`

```
### Feature Proposal
**Inferred from:** <doc_gap | infrastructure_pattern | architecture_layer>

**Proposed enhancement:** <description of new feature>

**Current gap:** <what's missing in code/docs>

**Implementation path:**
1. <step 1>
2. <step 2>
3. <step 3>

**Dependencies:** <existing infra this builds on>

**Effort estimate:** <S/M/L>

**Reviewer:** <review>
**Verdict:** Agree / Partially agree / Disagree
**Reasoning:** <reviewer reasoning>
**Risk:** <risk assessment>

<!--{token}_R_FE_DONE-->
```

## Hash Markers

| Marker | Placement | Purpose |
|--------|-----------|---------|
| `<!--{token}_GM_Q{N}_DONE-->` | Before `## Proposed ADR` | GM finished question N |
| `<!--{token}_R_Q{N}_DONE-->` | Before corresponding GM hash | Reviewer finished review |
| `<!--{token}_FE_Q_DONE-->` | Before `## Feature Expansion` | GM finished FE proposal |
| `<!--{token}_R_FE_DONE-->` | After FE review | Reviewer finished FE review |

## ADR Ownership

- `## Proposed ADR` = design decisions (refinement) — requires human review
- `## Feature Expansion` = feature proposals (NEW functionality) — requires human review
- Neither becomes a real decision until approved by a human
