# Separate window sizes

Approved in chat on 2026-10-22. Replace the shared size control with Main window
size and Recipe details size, each 75-125%, independently saved and applied.
Preserve the existing scale field for the main browser; add optional recipeScale,
falling back to the saved shared scale on first use. Defaults remain 100%.
Clamp each frame independently to its screen dimensions without altering saved
requested sizes. Opacity stays shared. Reset appearance restores both sizes and
opacity to 100%. Keep explicit-open recipe alignment correct at unequal scales.

- [x] Write failing regressions for size independence, legacy fallback, invalid
  recipe preferences, independent screen fit, controls/persistence/reset, and
  recipe opening/alignment with unequal sizes.
- [x] Implement separate size preferences and controls; expand options layout.
- [x] Run full Lua suite and diff checks; independently review.
- [x] Update README, create local commit, and build a verified test ZIP.

Validation: 842 Lua 5.1 tests pass. Independent review completed; a scale
coordinate concern was checked against Blizzard UI code and withdrawn, with
additional coverage for non-unit UI scale and unequal window sizes. Packaging
verified 81 files and all three manifests. In-game checks remain outstanding.
