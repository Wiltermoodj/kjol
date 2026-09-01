# b2b Repo Grill — Verified Findings (2026-08-31)

Repo: `/Users/lappier/code/projects/b2b` (Bicycle Butler B2B — Firebase/Firestore multi-tenant B2B).
Upstream: `https://github.com/Wiltermoodj/b2b.git`. Confirmed clean (`git status` empty, main matches origin/main).
Grill cronjob: `b2b-grill-standard` (every 2m, telegram:8951222762).
Scripts: `~/.hermes/scripts/grill-b2b-orchestrator.py`, `grill-b2b-monitor.sh`.

## Verified Reality — Tenant Isolation Split

Client-side is MOCKED; server-side is REAL.

**Mock auth (client):** `src/context/auth-context.tsx` lines 39-88 use `localStorage.getItem("MOCK_AUTH")` and hardcode `mock-uid` / `mock-uid-123`, `mock-company`, `mock-company-123`. Role is read directly from the localStorage string. `auth.ts` is a pure library wrapper with no enforcement.

**Real enforcement (server):** `firestore.rules` lines 41-46 (`belongsToCompany`), 82-90 (`verificationDocuments` subcollection isolation), 119-143 (`orders` collection with frozen line-item snapshots, `resource.data.companyId == resource.data.companyId` guard). `src/lib/auth.ts.md` notes: browser-only module; server-side auth handled by service accounts.

**Cloud Function bridge (`src/lib/order-operations.ts`):** 23-line thin wrapper calling `createOrderV1`. The CF (`src/services/order-service.ts`, lines 132-237) performs the real authorization checks: validates `userData.isActive`, rejects `salesRep` if `assignedRepId !== actorId`, verifies `targetUserData.companyId !== companyId` for impersonation, and enforces `retailer` must match `companyId`. Order creation runs inside a Firestore transaction (`db.runTransaction`) that locks inventory pools atomically.

## Design Verdict
- Pattern is correct: client thin → CF enforces. The mock auth is a local-dev shortcut only; the rules ignore any client-claimed identity and read from `request.auth.uid` + `/users/{uid}`.
- Risk: if `MOCK_AUTH` leaks into a production build, it is useless (rules read real UID) but could confuse debugging. Not a security hole.
- Recommendation (A from Q1 template): keep mock for local/dev, verify build-time guard strips `MOCK_AUTH` reference in production.

## Template Additions Added to Orchestrator
Four b2b-specific Q templates were added to `grill-b2b-orchestrator.py`:
1. `auth`/`impersonation`/`context` or `MOCK_AUTH` pattern → "Tenant isolation — mocked on client, enforced server-side" (references auth-context.tsx 39-88, firestore.rules 41-46/119-143, order-service.ts 132-237).
2. `order`/`operations` → "Order creation — client bridge to secure Cloud Function".
3. `tax`/`exemption` → "Tax exemption lifecycle — document upload → approval → expiration" (references firestore.rules 82-90, expiration-service).
4. `inventory`/`atp`/`pricing` → "Inventory ATP & pricing — committed vs onHand, dynamic rollover" (references inventory-atp-service.ts pool model, order-service.ts 396-493 pool updates).

## Common Pitfalls Confirmed for b2b
- `.replace(".ts", "")` on `.ts.md` → `file.md` (already in skill pitfall list). Used `.replace(".ts.md", "")` in new orchestrator.
- Bash subshell variable scoping in monitor: variables set inside `while` loop with pipe input are lost. Monitor uses Python (`echo`) for counting — safe.