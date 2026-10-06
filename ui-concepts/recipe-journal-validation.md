# Recipe journal validation — 2026-10-05

The recipe details window now shares the Artisan Journal parchment, leather, bronze palette and Crimson Text fonts with Professions. It uses a 540 × 620 logical-unit frame, follows the browser scale, and remains movable and clamped to the screen.

The recipe icon, title and profession use a dedicated header. Titles reserve up to two lines. Materials have a bordered scroll viewport, wrapped labels and explicit empty/unavailable states. The crafter control, saved date and cached-data note have separate bounded regions. The legacy native dropdown and the large-list fallback both retain selection behavior; the fallback menu appears above the materials and clips its scrolling rows.

Existing runtime artwork was reused. No new data acquisition, network traffic, automation, storage behavior or synchronization behavior was introduced. Existing uncommitted armory work was preserved.

## Checks

- Current integrated PR CI run: **405 passed, 0 failed**, with Lua syntax validation passing for **38 Lua files**. This is the integrated CI result; the earlier local counts below are historical context from when the recipe-only change was validated.
- Lua 5.1 suite after the runtime stacking correction: **394 passed, 0 failed** in the full working tree; **392 passed, 0 failed** in an isolated copy of the recipe-only staged changes (the two additional tests belong to separate uncommitted armory work).
- Five previews rendered from actual Lua anchors and runtime textures: `complete`, `long-name`, `empty`, `unavailable`, and `many-crafters`.
- Visible non-scrolling labels checked for horizontal bounds, wrapping, and placement inside the window.
- Ordinary, long-title, unavailable and open-menu previews visually inspected. Native icons are placeholders.
- In-game rendering, native dropdown chrome and font loading remain unverified.

Run the renderer with `ui-concepts/render-journal-preview.py --recipe --state=complete`; substitute any scenario above. Run the suite from this worktree using `../tools/lua/lua.exe tests/run.lua`.

## Runtime stacking correction

The in-game screenshot showed leather covering the parchment sheet and materials area. Their backgrounds had been on separate frames at the same level; the off-game preview imposed a stable order that did not establish the client's ordering. The parchment textures now belong to the window itself, with explicit background sublevels: leather -8, sheet -7, materials -6, and icon backing -5. Each parchment texture stays anchored to its original panel, preserving layout and borders. Dynamic crafter menus retain their own visibility and raised frame level.

A regression test failed before this correction and passes after it; it verifies texture ownership, ordering, and panel anchoring. The parchment, leather and button files are opaque, uncompressed 32-bit RGBA TGA images, 512 × 512. The corrected installation archive includes the parchment texture and revised Lua source. The correction still requires confirmation in-game after replacing the addon files and reloading.
