# trail-tune-new Two-Agent Grill v2.5 — Actual Decisions Made

## Overview

The two-agent grill ran on 4 domains in `/Users/lappier/code/projects/trail-tune-new`. The Master Agent pre-wrote questions (GM role), then spawned Reviewer subprocesses via `hermes chat` CLI (model `step-3.7-flash:free`). 

The ADR sections in each sidecar were written by the **Master Agent** (not a Verifier), so the decisions below reflect the **GM's recommendation** and the **Reviewer's verdict** — the actual design tensions that emerged.

---

## Domain 1: firestore-tune-adapter.ts (283 lines)

### Q1 — Duplicated mock backend branch across 8 methods
- **GM Question:** The `if (NEXT_PUBLIC_MOCK_AUTH === 'true')` conditional is replicated in 8/11 methods. Should we extract it?
- **GM Recommendation:** B — Extract `MockTuneAdapter` implementing `TuneStoragePort`, selected by env flag at composition root.
- **Reviewer Verdict:** Partially agree
- **Reviewer Concern:** Risk of over-abstraction for dev-only scaffolding that may drift from real semantics.
- **ADR-1 Decision:** Adopt Strategy-style extraction (`MockTuneAdapter` behind `TuneStoragePort`). ⚠️ **Not yet implemented.**

### Q2 — Inconsistent failure policy across read methods
- **GM Question:** `getTunesForBike` returns `[]` on error, `getGlobalTunes` throws, `getTuneTable` returns `null`. Standardize?
- **GM Recommendation:** B — Reads should throw (surface errors); writes may degrade gracefully.
- **Reviewer Verdict:** Agree
- **Reviewer Concern:** `getTuneTable` returning `null` is treated as "empty state" by UI code — changing to throw requires caller audit.
- **ADR-2 Decision:** Standardize read-path failures on throwing. **Requires caller audit** for UI paths treating `[]` as non-error.

---

## Domain 2: firestore-catalog-adapter.ts (24 lines)

### Q1 — Is the thin pass-through adapter justified?
- **GM Question:** Every method is a 1-line delegation to static DB services. Delete or keep?
- **GM Recommendation:** A — Keep as `CatalogPort` boundary; interface cost is negligible.
- **Reviewer Verdict:** Partially agree
- **Reviewer Concern:** No concrete swap scenario yet; seam risks fossilizing into mandatory indirection.
- **ADR-1 Decision:** Keep `FirestoreCatalogAdapter` as `CatalogPort` implementation.

### Q2 — Should the adapter guard against a falsy `kit`?
- **GM Question:** `resolveBuildKitComponents` forwards `kit` with no null handling. Defensive guard?
- **GM Recommendation:** A — Keep raw passthrough; validation belongs in `ComponentDatabaseService`.
- **Reviewer Verdict:** Disagree
- **Reviewer Concern:** Boundary guarding isn't duplication — converts deep stack exceptions into local contract failures.
- **ADR-2 Decision:** Adapter stays passthrough (optional falsy-`kit` guard is non-blocking).

---

## Domain 3: bike-assembler.ts (18 lines)

### Q1 — Dependency-injection boundary for CatalogPort
- **GM Question:** Should `assembleFromKit` encode its `CatalogPort` dependency in the interface, or inject via constructor?
- **GM Recommendation:** A — Keep interface behavior-only; concrete class takes `CatalogPort` in constructor.
- **Reviewer Verdict:** Agree
- **Reviewer Concern:** Minimal — only risk is DI-container wiring mismatch.
- **ADR-1 Decision:** `BikeAssemblerInterface` stays behavior-only. Concrete `BikeAssembler` receives `CatalogPort` via constructor injection.

### Q2 — Fixed 4-component shape vs. generalization
- **GM Question:** `resolveBuildKitComponents` returns `{fork, shock, frontTire, rearTire}`. Generalize?
- **GM Recommendation:** A — YAGNI; wait for a 5th component role.
- **Reviewer Verdict:** Partially agree
- **Reviewer Concern:** Cost asymmetry — generalizing now is cheaper than migrating later under time pressure.
- **ADR-2 Decision:** Keep fixed 4-field shape; revisit when a new component role appears.

---

## Domain 4: ingestion-pipeline.ts (22 lines)

### Q1 — Empty ValidatedBatch extension
- **GM Question:** `ValidatedBatch extends PreparedBatch` adds no fields; comment defers clean/dirty separation. Model it now?
- **GM Recommendation:** B — Add `clean`/`dirty` arrays now; makes `validateBatch` meaningful.
- **Reviewer Verdict:** Partially agree
- **Reviewer Concern:** Premature specialization before validation flavor is locked in creates another migration later.
- **ADR-1 Decision:** Add `clean`/`dirty` to `ValidatedBatch` (or defer explicitly as typed marker).

### Q2 — `upsertIds: Set<string>` serialization
- **GM Question:** `Set<string>` doesn't JSON-serialize. Keep Set, switch to array, or hybrid?
- **GM Recommendation:** B — Use `string[]` for JSON-safe persistence.
- **Reviewer Verdict:** Partially agree
- **Reviewer Concern:** Discarding Set at in-memory layer costs dedup guarantees; pipeline likely needs Set semantics.
- **ADR-2 Decision:** Use `string[]` for `upsertIds` (or hybrid: Set internally, array on wire).

---

## Decision Summary Table

| Domain | Q | GM Rec | Reviewer | ADR Decision | Risk |
|--------|---|--------|----------|-------------|------|
| firestore-tune-adapter | Q1 | B (extract MockTuneAdapter) | Partially agree | Extract strategy, not yet implemented | Mock drift |
| firestore-tune-adapter | Q2 | B (throw on read errors) | Agree | Standardize reads on throwing | Requires caller audit |
| firestore-catalog-adapter | Q1 | A (keep adapter) | Partially agree | Keep as CatalogPort | Future indirection |
| firestore-catalog-adapter | Q2 | A (keep passthrough) | Disagree | Keep passthrough (optional guard) | Deep stack exceptions |
| bike-assembler | Q1 | A (ctor injection) | Agree | Interface behavior-only | Low (DI wiring) |
| bike-assembler | Q2 | A (YAGNI) | Partially agree | Keep fixed 4-field shape | Future migration churn |
| ingestion-pipeline | Q1 | B (clean/dirty arrays) | Partially agree | Add arrays (or defer) | Premature specialization |
| ingestion-pipeline | Q2 | B (string[] not Set) | Partially agree | string[] or hybrid | Duplicate uniqueness logic |

## Key Observations for Intent Alignment

1. **Master Agent (GM) bias toward action:** All 4 GM recommendations are "implement now" (B options) except bike-assembler Q1/Q2. Reviewer consistently provides cost/benefit pushback.

2. **Reviewer adds critical nuance:** 
   - firestore-tune Q2: GM says "just throw" → Reviewer: "but getTuneTable's null is UI contract, audit needed"
   - ingestion Q2: GM says "just use string[]" → Reviewer: "but you'll duplicate uniqueness logic"
   - bike-assembler Q2: GM says "YAGNI" → Reviewer: "but future migration will be under time pressure"

3. **Unanimous agreements (no pushback):** bike-assembler Q1 (DI boundary) — only place Reviewer fully agreed, because it's a clear best practice with minimal tradeoffs.

4. **Decisions are conservative:** Every ADR lands on the GM's recommendation with the Reviewer's caveats folded in as risk items or hybrid options ("or defer explicitly", "or hybrid: Set internally, array on wire").
