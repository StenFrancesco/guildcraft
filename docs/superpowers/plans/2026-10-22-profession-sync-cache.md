# Profession synchronization cache implementation plan

**Goal:** Implement PR2 of issue #94 on test0-01, preserving P5 serialization and the profession compression baseline.

**Approved design:** Keep caches outside SavedVariables, scoped by database. Cache character/profession content hashes, coherent manifest rows and aggregate digests. Invalidate on content, freshness, eligibility, identity, membership, purge, repair and database changes. Separate guild-filtered and unfiltered results. Query responses derive their digest from the existing manifest; login/background announcement hints do no unused local digest work. Keep full read validation; validation reuse belongs to PR5.

## Tasks

- [x] Preserve the original sync data implementation in tests/fixtures/profession_sync_data_uncached.lua as the compatibility oracle.
- [x] Add regression coverage that fails before caching: warm calls skip capture reconstruction and recipe hashing, and all listed mutations agree with the oracle. Run the failing tests.
- [x] Implement private runtime caches and mutation invalidation in ProfessionSyncData, ProfessionIndex and Storage. Reuse query rows and remove unused hint digest calls in ProfessionSync. Rerun focused regressions.
- [x] Add a reproducible benchmark for cold/warm digest and manifest-plus-digest probes, codec encode/decode, and compressed end-to-end sync. Compare the frozen oracle with cached behavior under the same fixture.
- [x] Review implementation independently and address material findings.
- [x] Run full Lua regressions, compile all TOC-listed Lua sources, inspect diff whitespace and document measurements and limitations.
- [x] Commit only PR2 files locally; preserve the pre-existing bank edits. Do not push or open a remote PR.

## Verification

Use Lua 5.1 at E:/Razz Addon/tools/lua/lua.exe. Timing uses five samples and os.clock CPU milliseconds, a full GC before each sample outside the timer, and normal collection during each operation. Synthetic dense-overlap sizes match the issue's first three cases. End-to-end probes use actual compressed transport with deterministic mocked guild APIs, and distinguish cold and prewarmed equal-cache comparisons from a divergent record transfer. Assert convergence and report frames and bytes. Standalone timings do not establish in-game FPS effects.
