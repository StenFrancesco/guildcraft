# Artisan Journal runtime artwork

The UI follows the approved `ui-concepts/03-artisan-journal.png` reference: a bronze and wood journal frame, illustrated leather sidebar, torn parchment, inset profession buttons, large serif text, and profession artwork behind the recipe page. Controls, labels, native item icons, and cached records are rendered by the addon.

The revised layout is 1400 × 630 logical UI units and scales down to fit the screen. All six professions switch their own full-page background and show their selected quoted subtitle in readable 18px dark-ink italic serif type, left-aligned beneath the heading. Search, recipe details, crafter selection, navigation, and cached-data wording retain their existing behavior. No gameplay, data acquisition, or synchronization logic changes.

## Runtime files

- `journal-window.tga`: 2048 × 1024 complete journal chrome, with transparent outside corners.
- `profession-button-framed.tga`: 1024 × 256 darker inset button; the UI crops its transparent padding.
- `{profession}-page.tga`: six 1024 × 1024 backgrounds displayed at the reference panel proportions.
- `profession-page-mask.tga`: shared rounded perimeter mask for all six recipe panels. The top corners use a broader radius and the upper fade is 50% wider than the lower 5% fade. Profession artwork, chrome, controls, and anchors are unchanged.
- `journal-serif.ttf`, `journal-serif-bold.ttf`, and `journal-serif-italic.ttf`: Crimson Text regular, bold, and italic; license included in `FONT-LICENSE.txt`.
- `parchment.tga`, `leather.tga`, and `profession-button.tga` remain available for recipe details and secondary panels.

All TGA files use uncompressed 32-bit RGBA and power-of-two dimensions. Source PNGs retain their original aspect ratio; the runtime viewport restores that ratio after technical export resizing. There is no baked UI text in the new artwork.

## Reproduction and checking

`ui-concepts/export-journal-reference.py` exports the eight revised textures, verifies pixel round-trips, and builds the complete `GuildGearMemory-ArtisanJournal-v2.zip`. `reference-export.json` records sources and dimensions. `ui-concepts/export-artisan-journal.py` exports the three shared surfaces and rebuilds the smaller artwork package; `manifest.json` records those surfaces.

`ui-concepts/render-journal-preview.py` creates an off-game preview from the actual Lua UI anchors, fonts, and runtime textures. Native WoW icons are represented by placeholders. This preview does not establish in-game texture loading or font rendering.

`ui-concepts/export-profession-mask.py` generates and verifies the mathematical mask without modifying any original image. Render each profession with `render-journal-preview.py --profession=Blacksmithing` (or another supported profession name). The mask attaches only to the recipe-panel background, so it cannot fade text, icons, or the outer frame.

The current integrated PR CI run passes 405 tests with 0 failures; Lua syntax validation covers 38 Lua files. These results cover the integrated changes in that CI run. Final in-game appearance still needs checking after installing the complete v2 ZIP and reloading WoW.

Artwork was coordinated by `gpt-6-luna` subagents at `max` effort using the built-in ImageGen tool. Original images are in `tests/Source/`; exact prompts are in `ui-concepts/artisan-journal-prompts/`.

Font sources: https://github.com/google/fonts/tree/main/ofl/crimsontext

## Character armory journal

Characters shares the journal chrome, parchment search, serif fonts, and framed library buttons with Professions. The detail page uses `gear-journal-page.tga`, a 1024 × 1024 uncompressed 32-bit RGBA parchment texture, with a painted armory composition in the upper-right and faint equipment sketches below. The page uses the same edge mask and bounds as Professions, without an extra nested panel border. Its editable source is `tests/Source/gear-journal-page.png` and prompt is `ui-concepts/artisan-journal-prompts/gear-journal-page.txt`. Regenerate and verify the runtime export with `ui-concepts/export-character-armory.py`, which checks exact pixel round-trips. The earlier armory assets remain available.

The portrait remains the existing saved race/2D portrait. Equipment acquisition, storage, tooltips, synchronization, and cached-state semantics are unchanged.

Render Characters with `ui-concepts/render-journal-preview.py --characters`; `--state=incomplete`, `--state=long-name`, and `--state=empty` cover alternative layouts. The default mode renders Professions to a separate comparison preview. Native portraits and icons are placeholders; in-game appearance remains unverified.

The 2026-10-09 redesign aligns slot rows around a framed portrait and reserves separate space for weapons and the last-known equipment caption. Geometry checks cover painted page bounds, portrait/weapon/footer separation, the shared background mask, adjacent slot clearance, and the bounded capture date. The in-game screenshot follow-up fixes the centered realm label and replaces the padded achievement icon-frame texture with two thin borders at the actual portrait bounds. All 417 tests pass under Lua 5.1; the full Lua 5.4 suite has one unrelated failure because a recipe fixture uses Lua 5.1's global `unpack`.

The preview now assumes centered alignment for font strings without explicit alignment, matching the inherited game font behavior. Its texture fixture clears the previous solid fill when a texture is assigned. Native icons and portraits remain placeholders, so final rendering still needs checking in WoW.

This gear page's artwork was created and refined by a `gpt-6-luna` subagent at medium reasoning effort. The gear redesign review used `gpt-6-luna` at xhigh effort. The earlier artwork generation settings documented above describe older assets.
