# Profession synchronization cache measurements

Measured 22 October 2026 for issue #94, PR2.

## Implementation and compatibility

Runtime caches use weak database keys and stay outside SavedVariables. They retain
per-character/profession content hashes, manifest rows, the unfiltered digest and
one most-recent guild-filtered digest per profession. Returned rows are copied.
Controlled saves, membership changes, registry/roster reconciliation, purges and
repairs invalidate before mutation, including paths that can fail after changes.
Database/index table identities and typed metadata signatures detect replacement,
identity, ownership, eligibility and observation changes. Numeric signatures use
17 significant digits; the protocol continues to use its original serialization.

Every manifest read still runs full index validation. Cold captures are validated
before publication. Warm metadata changes cannot conceal malformed identities,
forbidden saved recipe arrays, non-table snapshots or invalid metadata types.
P1 recipe hashes and D2 aggregate serialization exactly match the frozen uncached
implementation in tests/fixtures/profession_sync_data_uncached.lua. Controlled
recipe-index writers must call InvalidateProfessionSyncCache; arbitrary in-place
recipe membership edits outside those writers require that explicit invalidation.

Query replies digest their existing filtered manifest. Login/background hints
do no local digest work; save announcements retain their digest comparison.
Profession P5 / GC_PROF5, codec bounds, record validation, ACKs, queue behavior
and SavedVariables formats are unchanged.

## Baseline and method

The selected base is bfe4851 (PR1 and bank batching on top of main with profession
compression PR #84 merged). Gear compression PR #93 is not part of this selected
worktree baseline; PR2 does not alter gear.

Run from the repository root with Lua 5.1:

    lua tests/run.lua
    lua tests/check_toc_syntax.lua
    lua tests/bench_profession_sync_cache.lua

Measurements use the bundled Windows Lua 5.1 executable at
E:/Razz Addon/tools/lua/lua.exe, five samples, median os.clock CPU milliseconds.
Database construction, prewarming, forced GC and end-to-end convergence assertions
are outside timing. Normal GC runs during operations. Clock resolution is roughly
1 ms here; small codec times should be interpreted accordingly.

Synthetic dense-overlap databases use every listed recipe on every character.
Cold means no prepared runtime calculation cache; warm means the same database
has already had its digest computed. Baseline probes load the frozen original
ProfessionSyncData implementation. The reference end-to-end query helper also
restores the original redundant digest read, so it measures the previous responder
calculation path. Both sides use the same compression and deterministic guild
transport fixture. These fixtures are scaling probes, not typical guild data.

The end-to-end cases include the request, responder selection, manifests where
needed, complete record transfer, validation, storage, ACKs and finish timers.
Advancing simulated time costs no wall-clock wait; reported time is CPU work.
The equal case has two online peers and ten matching character caches, each with
500 recipes. The divergent case transfers a validated compressed 2,000-recipe
record into an empty peer and asserts convergence and a Z1 envelope on the wire.

## Calculation results

Median CPU milliseconds; each warm cached case performed zero HashProfessionRecipes,
ValidateProfessionCapture and GetProfessionRecord calls.

| Characters x recipes | Baseline warm digest | Cached cold digest | Cached warm digest | Baseline cold manifest + digest | Cached cold manifest + digest | Cached warm manifest + digest |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 x 500 | 8 | 8 | 2 | 14 | 9 | 3 |
| 50 x 1,000 | 76 | 76 | 14 | 152 | 93 | 29 |
| 100 x 2,000 | 337 | 330 | 56 | 717 | 410 | 112 |

The 100 x 2,000 cold manifest-plus-digest probe hashes/validates/reconstructs
100 character captures once instead of 200. Warm reads still pay for full index
validation; they remain synchronous and can exceed a frame budget. Remaining cold
work and validation reuse are explicitly deferred to PR5.

## End-to-end results

| Fixture | State | Baseline CPU ms | Cached CPU ms | Baseline recipe hash calls | Cached recipe hash calls | Frames / bytes (both) |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Equal 10 x 500 | Cold | 45 | 20 | 60 | 20 | 3 / 187 |
| Equal 10 x 500 | Warm | 44 | 9 | 60 | 0 | 3 / 187 |
| Compressed 2,000-recipe transfer | Cold | 52 | 39 | 10 | 5 | 48 / 10,165 |
| Compressed 2,000-recipe transfer | Warm | 53 | 36 | 10 | 4 | 48 / 10,165 |

Codec CPU measured inside the record transfer was 12 ms on the baseline and
13-14 ms with caching. Those small timing differences do not indicate a codec
change: the codec source and transport are unchanged. Warm equal comparisons
also perform zero capture validations and zero GetProfessionRecord calls.

A standalone 37,026-byte synthetic P5 record encoded to a 363-byte Z1 payload.
Median encode and decode costs were 2 ms each. This is a different, deliberately
repetitive codec fixture; the real end-to-end record results above include the
actual serialized recipes and transport overhead.

## Verification and limits

The clean PR2-only snapshot passes **852 tests, 0 failures** and compiles all
**42 TOC-listed Lua sources**. Focused review also exercised compression corruption,
bounds, protocol isolation and library load order. Oracle parity tests cover
content, freshness, labels/icons, ownership, eligibility, membership, rename,
repair/failure, purge and database/index replacement. Targeted regressions first
demonstrated warm-cache failures before fixes.

Verification used a clean snapshot of the selected base plus only PR2 changes
because the shared test0-01 worktree concurrently contains uncommitted PR3 UI and
catalog work. Those unrelated changes are excluded from this PR2 commit.

No live World of Warcraft, in-game frame-time, real network-delivery or memory
stabilization measurement was performed. The results establish less repeated
CPU work in the Lua fixture, not an in-game FPS improvement.

## Raw benchmark output

```text
Lua: Lua 5.1; five samples, median CPU; setup/prewarm/forced GC excluded
10x500 baseline cold digest: 8.000 ms; hashes=10 captures=10 records=10 frames=0 bytes=0 codec=0.000 ms
10x500 baseline cold manifest+digest: 14.000 ms; hashes=20 captures=20 records=20 frames=0 bytes=0 codec=0.000 ms
10x500 baseline warm digest: 8.000 ms; hashes=10 captures=10 records=10 frames=0 bytes=0 codec=0.000 ms
10x500 baseline warm manifest+digest: 14.000 ms; hashes=20 captures=20 records=20 frames=0 bytes=0 codec=0.000 ms
10x500 cached cold digest: 8.000 ms; hashes=10 captures=10 records=10 frames=0 bytes=0 codec=0.000 ms
10x500 cached cold manifest+digest: 9.000 ms; hashes=10 captures=10 records=10 frames=0 bytes=0 codec=0.000 ms
10x500 cached warm digest: 2.000 ms; hashes=0 captures=0 records=0 frames=0 bytes=0 codec=0.000 ms
10x500 cached warm manifest+digest: 3.000 ms; hashes=0 captures=0 records=0 frames=0 bytes=0 codec=0.000 ms
50x1000 baseline cold digest: 78.000 ms; hashes=50 captures=50 records=50 frames=0 bytes=0 codec=0.000 ms
50x1000 baseline cold manifest+digest: 152.000 ms; hashes=100 captures=100 records=100 frames=0 bytes=0 codec=0.000 ms
50x1000 baseline warm digest: 76.000 ms; hashes=50 captures=50 records=50 frames=0 bytes=0 codec=0.000 ms
50x1000 baseline warm manifest+digest: 157.000 ms; hashes=100 captures=100 records=100 frames=0 bytes=0 codec=0.000 ms
50x1000 cached cold digest: 76.000 ms; hashes=50 captures=50 records=50 frames=0 bytes=0 codec=0.000 ms
50x1000 cached cold manifest+digest: 93.000 ms; hashes=50 captures=50 records=50 frames=0 bytes=0 codec=0.000 ms
50x1000 cached warm digest: 14.000 ms; hashes=0 captures=0 records=0 frames=0 bytes=0 codec=0.000 ms
50x1000 cached warm manifest+digest: 29.000 ms; hashes=0 captures=0 records=0 frames=0 bytes=0 codec=0.000 ms
100x2000 baseline cold digest: 342.000 ms; hashes=100 captures=100 records=100 frames=0 bytes=0 codec=0.000 ms
100x2000 baseline cold manifest+digest: 717.000 ms; hashes=200 captures=200 records=200 frames=0 bytes=0 codec=0.000 ms
100x2000 baseline warm digest: 337.000 ms; hashes=100 captures=100 records=100 frames=0 bytes=0 codec=0.000 ms
100x2000 baseline warm manifest+digest: 683.000 ms; hashes=200 captures=200 records=200 frames=0 bytes=0 codec=0.000 ms
100x2000 cached cold digest: 330.000 ms; hashes=100 captures=100 records=100 frames=0 bytes=0 codec=0.000 ms
100x2000 cached cold manifest+digest: 410.000 ms; hashes=100 captures=100 records=100 frames=0 bytes=0 codec=0.000 ms
100x2000 cached warm digest: 56.000 ms; hashes=0 captures=0 records=0 frames=0 bytes=0 codec=0.000 ms
100x2000 cached warm manifest+digest: 112.000 ms; hashes=0 captures=0 records=0 frames=0 bytes=0 codec=0.000 ms
sync baseline cold equal-10x500: 45.000 ms; hashes=60 captures=60 records=60 frames=3 bytes=187 codec=0.000 ms
sync baseline cold record-2000: 52.000 ms; hashes=10 captures=12 records=8 frames=48 bytes=10165 codec=12.000 ms
sync baseline warm equal-10x500: 44.000 ms; hashes=60 captures=60 records=60 frames=3 bytes=187 codec=0.000 ms
sync baseline warm record-2000: 53.000 ms; hashes=10 captures=12 records=8 frames=48 bytes=10165 codec=12.000 ms
sync cached cold equal-10x500: 20.000 ms; hashes=20 captures=20 records=20 frames=3 bytes=187 codec=0.000 ms
sync cached cold record-2000: 39.000 ms; hashes=5 captures=7 records=3 frames=48 bytes=10165 codec=13.000 ms
sync cached warm equal-10x500: 9.000 ms; hashes=0 captures=0 records=0 frames=3 bytes=187 codec=0.000 ms
sync cached warm record-2000: 36.000 ms; hashes=4 captures=6 records=2 frames=48 bytes=10165 codec=14.000 ms
codec payload: 37026 plain bytes -> 363 wire bytes
codec encode: 2.000 ms; hashes=0 captures=0 records=0 frames=0 bytes=0 codec=0.000 ms
codec decode: 2.000 ms; hashes=0 captures=0 records=0 frames=0 bytes=0 codec=0.000 ms

```
