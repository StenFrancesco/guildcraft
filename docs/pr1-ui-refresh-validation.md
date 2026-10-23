# PR1 UI refresh validation — 22 October 2026

Baseline: `b78a47a`, the user-selected `test0-01` worktree. Measurements run with the bundled Lua 5.1 runtime and the regression suite's mock browser API. They count actual browser refresh paths with an instrumented catalog builder; these are operation counts, not catalog CPU timings or in-game FPS measurements.

Both runs use the same fixture. Five invalidations occur before draining queued callbacks. Gear changes call the existing adapter's browser-refresh entry point. The fixture includes an initialized but hidden browser to exercise the missing visibility guard without relying on close-time selection reset. In the baseline, ordinary closing clears the profession selection and can incidentally prevent hidden catalog builds; PR1 preserves selection and explicitly gates visibility instead.

## Before (b78a47a)

```text
Initialized hidden browser, five profession events: 5
Initial opening: 2
Reopen after hidden changes: 2
Five gear events on Character: 5 catalogs, 0 Bank refreshes
Five gear events on Bank: 5 catalogs, 10 Bank refreshes
Five gear events on Professions: 10 catalogs, 0 Bank refreshes
Five visible profession events: 5
Automatic gear requests from opening/refresh: 0
```

## After

```text
Initialized hidden browser, five profession events: 0
Initial opening: 1
Reopen after hidden changes: 1
Five gear events on Character: 0 catalogs, 0 Bank refreshes
Five gear events on Bank: 0 catalogs, 0 Bank refreshes
Five gear events on Professions: 0 catalogs, 0 Bank refreshes
Five visible profession events: 1
Automatic gear requests from opening/refresh: 0
```

## Regression and compatibility checks

- All eight PR1 regression cases fail against the original browser implementation and pass with the fix. The original source is loaded separately; the working copy is never reverted for this check.
- Coverage includes hidden and inactive catalog/layout work, actual parent visibility, one build on opening, clean reopen/tab reuse, latest saved data, coalesced events, hiding before callback, consuming queued work on tab entry, selected record rebinding, Own-selection/search/scroll retention and one Bank refresh on opening.
- All 42 TOC-listed Lua sources compile using `loadfile`, without executing them.
- Full PR1-only suite: 823 passed, 0 failed, run in a temporary clean archive of `b78a47a` with only PR1's README, browser implementation and UI tests overlaid. Existing codec, malformed-input, transport, automatic-sync and ownership tests remain included.
- The shared worktree gained unrelated edits to `tests/bank_memory_test.lua` during final verification. Its full suite then reported 823 passed and 6 failing new bank-batching tests (missing `FlushPending` and repeated captures). These edits are excluded from PR1 and were left untouched; the isolated snapshot verifies exactly PR1's scope.
- `git diff --check`: clean.
- Independent gpt-6-luna review: hidden sidebar resize bypass fixed and regression covered; follow-up found no further actionable issues.
- No SavedVariables, protocol, compression, material-loading or network request behavior changes. No in-game FPS or live WoW verification was performed.
