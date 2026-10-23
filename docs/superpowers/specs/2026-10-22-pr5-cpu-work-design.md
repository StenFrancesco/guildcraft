# PR5: Bound CPU preparation and reuse operation validation

## Scope and baseline

Issue #94 PR5 in the existing test0-01 worktree, based on 2444228 (PRs 1–4 and profession compression). Preserve SavedVariables, P5 / GC_PROF5, the selected baseline's gear protocol 6, codec bounds, ChatThrottleLib, public synchronous data APIs and atomic save/ACK behavior. No remote actions. Produce one local implementation commit.

## Design

Use one cooperative OnUpdate driver for main-addon preparation with a shared 0.65 ms clock deadline (headroom toward the approximately 1 ms target), round-robin admission and hard operation-count limits. Remove the handler when the queue empties. Sorting uses resumable merge passes, hashing checks bounded byte units, and traversal/validation/filter loops checkpoint. Synchronous callers of the same functions keep complete synchronous returns.

Browser views prepare complete catalogs and filters before replacing their visible models. Keep the prior completed model while preparing the next revision. Hidden/inactive, superseded, database-replaced and revised jobs cancel without publication or indefinite retries. Local profession UI/events prepare capture, digest and validation before calling the existing synchronous save API.

Protocol operations prepare manifests/digests before query/claim/announcement or record-request work. Session/guild/database/revision/deadline guards discard obsolete preparation. Preparation does not extend response/operation/session deadlines; ACKs remain after complete validation and storage. Coalesced consumers must each receive completion rather than silently losing callbacks.

Validation tokens are opaque, weakly retained, identity-bound and single-use. A read-only preparation performs full index validation. Consumption checks the same database revision and all relevant table identities, then permits only ordinary unchanged-identity or new-GUID saves. The synchronous save rechecks its expected controlled invalidation sequence before membership mutation. Forged, stale, reused or replaced-input tokens fall back to ordinary validation. Rename, collision and repair paths retain full validation. Load/recovery validation remains mandatory.

Roster processing distinguishes presence metadata from registry membership, active-state and identity changes. Presence refreshes must update recipient availability without invalidating the unchanged profession cache or catalog. Full validation remains available and is prepared cooperatively on event-driven roster work.

## Alternatives

Changing synchronous builders to return partially built results would break consumers and was rejected. A persistent boolean that marks a database as validated would miss mutations and was rejected. Keeping every cold call synchronous preserves correctness but leaves measured frame hitches; cooperative preparation with operation-scoped proof is selected.

## Verification

Run failing focused regressions before implementation, then the complete Lua 5.1 suite and all TOC syntax checks. Cover shared budgets/idle removal, exact hashes and models, stale/superseded/hidden/database/guild/session cancellation, deadlines, malformed input, forged/reused proofs and ordinary ownership/freshness/repair behavior. Record comparable synchronous cold/warm and cooperative combined-frame probes with normal GC. Report timer resolution, GC/atomic callback outliers and retained synchronous costs honestly. In-game frame-time and memory stabilization checks remain separate validation.
