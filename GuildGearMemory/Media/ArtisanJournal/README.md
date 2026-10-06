# Artisan Journal runtime artwork

The UI follows the approved `ui-concepts/03-artisan-journal.png` reference: a bronze and wood journal frame, illustrated leather sidebar, torn parchment, inset profession buttons, large serif text, and profession artwork behind the recipe page. Controls, labels, native item icons, and cached records are rendered by the addon.

The revised layout is 1400 × 630 logical UI units and scales down to fit the screen. All six professions switch their own full-page background and show their selected quoted subtitle in centered italic serif type. Search, recipe details, crafter selection, navigation, and cached-data wording retain their existing behavior. No gameplay, data acquisition, or synchronization logic changes.

## Runtime files

- `journal-window.tga`: 2048 × 1024 complete journal chrome, with transparent outside corners.
- `profession-button-framed.tga`: 1024 × 256 darker inset button; the UI crops its transparent padding.
- `{profession}-page.tga`: six 1024 × 1024 backgrounds displayed at the reference panel proportions.
- `profession-page-mask.tga`: shared rounded perimeter mask for all six recipe panels. The top corners use a broader radius and the upper fade is 50% wider than the lower 5% fade. Profession artwork, chrome, controls, and anchors are unchanged.
- `journal-serif.ttf`, `journal-serif-bold.ttf`, and `journal-serif-italic.ttf`: Crimson Text regular, bold, and italic; license included in `FONT-LICENSE.txt`.
- The earlier nine TGA surfaces remain available for recipe details and secondary panels.

All TGA files use uncompressed 32-bit RGBA and power-of-two dimensions. Source PNGs retain their original aspect ratio; the runtime viewport restores that ratio after technical export resizing. There is no baked UI text in the new artwork.

## Reproduction and checking

`ui-concepts/export-journal-reference.py` exports the eight revised textures, verifies pixel round-trips, and builds the complete `GuildGearMemory-ArtisanJournal-v2.zip`. `reference-export.json` records sources and dimensions. The older export script and artwork-only ZIP describe the first asset set.

`ui-concepts/render-journal-preview.py` creates an off-game preview from the actual Lua UI anchors, fonts, and runtime textures. Native WoW icons are represented by placeholders. This preview does not establish in-game texture loading or font rendering.

`ui-concepts/export-profession-mask.py` generates and verifies the mathematical mask without modifying any original image. Render each profession with `render-journal-preview.py --profession=Blacksmithing` (or another supported profession name). The mask attaches only to the recipe-panel background, so it cannot fade text, icons, or the outer frame.

The Lua 5.1 regression suite passes 389 tests; syntax checks cover 37 Lua files. Final in-game appearance still needs checking after installing the complete v2 ZIP and reloading WoW.

Artwork was coordinated by `gpt-6-luna` subagents at `max` effort using the built-in ImageGen tool. Original images are in `Source/`; exact prompts are in `ui-concepts/artisan-journal-prompts/`.

Font sources: https://github.com/google/fonts/tree/main/ofl/crimsontext

## Character armory journal

Characters shares the journal chrome, parchment search, serif fonts, and framed library buttons with Professions. Its header uses `character-armory-vignette.tga`, a 1024 × 512 uncompressed 32-bit RGBA texture with transparent, softly fading left and bottom edges. The UI displays the entire texture so cropping cannot discard the fade. Its source is retained at `Source/character-armory-vignette.png`; the original opaque artwork remains at `Source/character-armory.png`. Regenerate and verify both runtime exports with `ui-concepts/export-character-armory.py`, which checks transparency and exact pixel round-trips.

The portrait remains the existing saved race/2D portrait. Equipment acquisition, storage, tooltips, synchronization, and cached-state semantics are unchanged.

Render Characters with `ui-concepts/render-journal-preview.py --characters`; `--state=incomplete`, `--state=long-name`, and `--state=empty` cover alternative layouts. The default mode renders Professions to a separate comparison preview. Native portraits and icons are placeholders; in-game appearance remains unverified.

The redesign adds regression checks for portrait/weapon/footer separation and header artwork/date visibility. The complete suite passes 391 tests. The armory vignette has an explicit foreground layer, and the capture date has a fixed header region to avoid relying on background draw order or caption autosizing.
