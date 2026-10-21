# Artisan Journal runtime artwork

The UI follows the approved `ui-concepts/03-artisan-journal.png` reference: a bronze and wood journal frame, illustrated leather sidebar, torn parchment, inset profession buttons, large serif text, and profession artwork behind the recipe page. Controls, labels, native item icons, and cached records are rendered by the addon.

The revised layout is 1400 × 630 logical UI units and scales down to fit the screen. All six professions switch their own full-page background and show their selected quoted subtitle in readable 18px dark-ink italic serif type, left-aligned beneath the heading. Search, recipe details, crafter selection, navigation, and cached-data wording retain their existing behavior. No gameplay, data acquisition, or synchronization logic changes.

## Runtime files

- `recipe-page.blp`: custom 1024 × 1024 DXT1-compressed BLP2 background for the 540 × 620 Recipe Details card. Bronze/wood framing, torn parchment and faint workshop sketches match the journal. Source: `tests/Source/recipe-page.png`. Created by a `gpt-6-luna` subagent at medium effort using ImageGen. No baked text or controls.
- `journal-window.blp`: 2048 × 1024 complete journal chrome, using DXT5-compressed BLP2 to retain its transparency.
- `profession-button-framed.tga`: 512 × 128 darker inset button; the UI crops its transparent padding using the existing normalized texture coordinates.
- `{profession}-page.blp`: six 1024 × 1024 DXT1-compressed BLP2 backgrounds displayed at the reference panel proportions.
- `profession-page-mask.tga`: shared 256 × 256 rounded perimeter mask for profession, gear, and bank backgrounds. The top corners use a broader radius and the upper fade is 50% wider than the lower 5% fade. The mask is generated directly from the same normalized shape and fade formulas at the smaller resolution, reducing its size from 4,194,348 to 262,188 bytes (93.75% smaller). Profession artwork, chrome, controls, and anchors are unchanged.
- `journal-serif.ttf`, `journal-serif-bold.ttf`, and `journal-serif-italic.ttf`: Crimson Text regular, bold, and italic; license included in `FONT-LICENSE.txt`.
- `parchment.tga`, `leather.tga`, and `profession-button.tga`: 256 × 256 reusable surfaces for recipe details and secondary panels.

Runtime artwork contains ten compressed BLP2 files and seven uncompressed TGA files, all with power-of-two dimensions. The six profession pages, gear page, recipe page, and bank page use DXT1 with no alpha. The journal window uses DXT5 for its transparency. Every BLP includes a complete mipmap chain down to 1 × 1; dimensions are unchanged from the earlier TGA exports. Compression is lossy and requires in-game appearance/loading verification. Original lossless PNGs remain under `tests/Source/` outside the installed addon folders.

The remaining TGA surfaces (parchment, leather, and plain profession button) use 24-bit RGB. The framed profession button, page mask, and radio controls retain 32-bit RGBA. The framed button and three reusable surfaces are exported directly from the lossless source PNGs with Lanczos resizing at half their previous width and height, saving 2,555,904 bytes. UI dimensions and texture coordinates are unchanged. Source PNGs retain their original aspect ratio; the runtime viewport restores that ratio after technical export resizing. There is no baked UI text in the new artwork.

## Reproduction and checking

`ui-concepts/export-journal-reference.py` exports the eight revised textures (seven BLP illustrations and the TGA framed button), validates the exports, and builds the complete `The-Guild-Book-ArtisanJournal-v2.zip`. `reference-export.json` records sources, dimensions, and runtime filenames. `ui-concepts/export-artisan-journal.py` exports the three shared surfaces and rebuilds the smaller artwork package; `manifest.json` records those surfaces.

`ui-concepts/export-blp-artwork.py` rebuilds all ten BLP illustrations from their original PNG sources. `ui-concepts/blp_export.py` uses Pillow 12.3 or newer with DDS DXT encoding to build BLP2 headers and full mipmap chains; it checks encoded block sizes and decodes each output to verify dimensions and color mode. Opaque images use DXT1; images with non-opaque pixels use DXT5. The BLP2 field layout follows [Pillow’s BLP reader](https://github.com/python-pillow/Pillow/blob/main/src/PIL/BlpImagePlugin.py). Current BLP files total 9,089,296 bytes, compared with 36,700,600 bytes for their preceding TGA files. The old TGA copies are excluded from the addon.

`ui-concepts/render-journal-preview.py` creates an off-game preview from the actual Lua UI anchors, fonts, and runtime textures. Native WoW icons are represented by placeholders. This preview does not establish in-game texture loading or font rendering.

`ui-concepts/export-profession-mask.py` generates and verifies the mathematical mask without modifying any original image. Render each profession with `render-journal-preview.py --profession=Blacksmithing` (or another supported profession name). The mask attaches only to the recipe-panel background, so it cannot fade text, icons, or the outer frame.

The current integrated PR CI run passes 405 tests with 0 failures; Lua syntax validation covers 38 Lua files. These results cover the integrated changes in that CI run. Final in-game appearance still needs checking after installing the complete v2 ZIP and reloading WoW.

Artwork was coordinated by `gpt-6-luna` subagents at `max` effort using the built-in ImageGen tool. Original images are in `tests/Source/`; exact prompts are in `ui-concepts/artisan-journal-prompts/`.

Font sources: https://github.com/google/fonts/tree/main/ofl/crimsontext

## Character armory journal

Characters shares the journal chrome, parchment search, serif fonts, and framed library buttons with Professions. The detail page uses `gear-journal-page.blp`, a 1024 × 1024 DXT1-compressed BLP2 parchment texture, with a painted armory composition in the upper-right and faint equipment sketches below. The page uses the same edge mask and bounds as Professions, without an extra nested panel border. Its editable source is `tests/Source/gear-journal-page.png` and prompt is `ui-concepts/artisan-journal-prompts/gear-journal-page.txt`. Regenerate and verify the runtime export with `ui-concepts/export-character-armory.py`, which validates the BLP output. The exporter generates only the current gear page. The unused `character-armory-vignette.tga` and its texture reference have been removed, saving 2,097,196 bytes from installed artwork. Earlier editable sources, `tests/Source/character-armory.png` and `tests/Source/character-armory-vignette.png`, remain in the repository outside the installed addon folders.

The portrait uses the selected character’s saved Classic class icon for the nine original Classic classes. Equipment acquisition, storage, tooltips, synchronization, and cached-state semantics are unchanged.

Render Characters with `ui-concepts/render-journal-preview.py --characters`; `--state=incomplete`, `--state=long-name`, and `--state=empty` cover alternative layouts. The default mode renders Professions to a separate comparison preview. Native portraits and icons are placeholders; in-game appearance remains unverified.

The 2026-10-09 redesign aligns slot rows around a framed portrait and reserves separate space for weapons and the last-known equipment caption. Geometry checks cover painted page bounds, portrait/weapon/footer separation, the shared background mask, adjacent slot clearance, and the bounded capture date. The in-game screenshot follow-up fixes the centered realm label and replaces the padded achievement icon-frame texture with two thin borders at the actual portrait bounds. All 417 tests pass under Lua 5.1; the full Lua 5.4 suite has one unrelated failure because a recipe fixture uses Lua 5.1's global `unpack`.

The preview now assumes centered alignment for font strings without explicit alignment, matching the inherited game font behavior. Its texture fixture clears the previous solid fill when a texture is assigned. Native icons and portraits remain placeholders, so final rendering still needs checking in WoW.

This gear page's artwork was created and refined by a `gpt-6-luna` subagent at medium reasoning effort. The gear redesign review used `gpt-6-luna` at xhigh effort. The earlier artwork generation settings documented above describe older assets.
