# Character Armory Implementation Plan

**Goal:** Match Characters to the approved ArtisanJournal visual style.

**Architecture:** Presentation changes stay in SnapshotTestUI.lua, with scoped portrait styling applied to the existing SavedCharacterModel view. Reuse journal textures and add one armory page texture. Data acquisition and network behavior remain unchanged.

**Tech stack:** WoW Lua, existing Lua tests, image generation, Pillow texture export, existing off-game renderer.

- [x] Generate a parchment armory page with a quiet left and lower field and a painted upper-right equipment vignette. Save source PNG and 1024x1024 TGA to Media/ArtisanJournal.
- [x] Consolidate character library framing, match profession row artwork, use parchment search, and bound list scrolling to its visible panel.
- [x] Apply the armory background to the detail panel. Reserve a readable header, compact parchment portrait, two equipment columns, separate weapons, and footer.
- [x] Extend the existing preview script with a character mode and representative saved record; preserve its profession mode.
- [x] Run the existing test suite with E:/Razz Addon/tools/lua/lua.exe tests/run.lua from PR39-Test. Render both tabs, inspect the images, and correct overlaps or contrast issues.
- [x] Review the diff for presentation-only scope and verify texture formats and file references.

Approved design: character-armory-design.md. Execute in the existing codex/pr-39-test worktree. No publish, push, or merge is included.
