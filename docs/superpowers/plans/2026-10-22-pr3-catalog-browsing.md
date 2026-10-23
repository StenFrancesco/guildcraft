# PR3 Catalog Browsing Implementation Plan

**Goal:** Bounded visible rows and reusable catalog models without data/protocol changes.
**Architecture:** Fixed-height row pools; full logical scroll heights; search debounce; validated runtime catalog cache with exact input comparison.
**Tech Stack:** WoW Lua 5.1 and existing regression mocks.

- [x] Add failing catalog cache/date sharing and viewport/search regressions.
- [x] Cache catalog models with complete input comparison, shared immutable owner descriptors and normalized labels in ProfessionIndex.lua.
- [x] Pool recipe and character rows in SnapshotTestUI.lua, split scroll rebinding from filter/detail updates, clamp offsets and debounce search.
- [x] Run regression suite, TOC compilation and operation probes; review changes and update README.
- [x] Stage only PR3 changes, excluding pre-existing PR2 edits; create requested local commit.
