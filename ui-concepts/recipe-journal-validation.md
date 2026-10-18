# Recipe Details validation — 2026-10-10

Implemented in the UI-Recipes worktree. The 540 × 620 card now uses custom bronze/wood framing, torn parchment and understated workshop sketches. Existing Crimson Text fonts and parchment buttons tie it to Professions. Single-choice materials display the item, quantity and required/optional state in one row; alternatives keep their group and individual choices. Crafter selection, saved dates, cached wording, request controls and availability messages have separate regions.

The custom background is owned by the window at background sublevel -7, above the leather fallback (-8). The translucent materials surface remains owned by the same window (-6). Text and interactive controls render above the background. Native and scrollable crafter selectors occupy the lower section; long titles reserve two lines.

No equipment acquisition, SavedVariables, addon communication, synchronization or whisper safety logic changed. Whispering still requires the existing explicit button click and availability checks.

## Verification

- Full Lua 5.1 suite: **414 passed, 0 failed**.
- Syntax checked all **18 top-level addon Lua files**.
- Background header verified: uncompressed TGA type 2, 1024 × 1024, 32-bit RGBA. Decoded pixels match the source resized with Lanczos exactly.
- Rendered complete, long-name, empty, unavailable and many-crafters previews from live Lua anchors and runtime textures. Each passes bounded-label checks; scroll content is clipped.
- Visually inspected ordinary, long-title, unavailable and open-menu previews. Preview now renders the amount field and explicitly applies the runtime disabled-button style because the fixture does not emit Blizzard callbacks.
- git diff --check passes.

The preview uses placeholder native item icons. In-game texture/font loading, native dropdown chrome and actual input handling require a WoW reload and manual check; off-game previews do not establish those results.

Run the renderer with python ui-concepts/render-journal-preview.py --recipe --state=complete; substitute any state above. It requires Pillow and lupa.lua51 on the Python module path. The validation run used the existing local runtime from the PR39-Test worktree. Run tests with E:/Razz Addon/tools/lua/lua.exe tests/run.lua from UI-Recipes.
