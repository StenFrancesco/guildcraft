# Classic equipment layout implementation plan

**Goal:** Implement the user-approved Classic character-sheet layout without new assets.
**Architecture:** Keep presentation changes in SnapshotTestUI.lua; reuse native inventory-slot and quickslot textures, existing class portrait, parchment and header art. Preserve all saved data and synchronization.
**Tech stack:** WoW Lua 5.1, existing regression suite and off-game preview renderer.

- [x] Enlarge slots to 44px with 36px icons, use native 14px UI text, and place equipment beside the portrait with outward labels.
- [x] Give the journal 64px more height and use a 47px row pitch; reserve space for two-line names, weapon labels and the capture footer.
- [x] Retain native empty-slot artwork and distinguish Empty from No data.
- [x] Update README, verify existing layout regressions, render complete/long-name/empty/incomplete previews and inspect them.
- [x] Review the focused diff and commit locally on codex/classic-equipment-layout.

Approved by the user on 2026-10-22. Base: b78a47a5bc2d42c3c9ba8bbc0719f13d83b63e93. No new media assets, storage changes or network changes.

## Validation

- Baseline: 815 passed, 0 failed with Lua 5.1.
- Final regression suite: 815 passed, 0 failed.
- Off-game previews inspected: complete, long names, incomplete equipment and no search results. Native icons/fonts are substitutes in this renderer; game FontStrings bound long names to 32px. The existing renderer fixture adapter was adjusted in memory only.
- No new addon media, capture, storage or communication changes. Live in-game rendering remains to be checked.
- Independent review by gpt-6-luna; no outstanding actionable findings.
