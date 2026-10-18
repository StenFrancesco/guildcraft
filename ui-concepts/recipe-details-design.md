# Recipe Details polish — 2026-10-10

Use a single illustrated artisan parchment sheet with a slim bronze and wood rim, matching the Professions journal. Keep dark serif ink, framed item icons, clear section hierarchy, and generous but purposeful spacing. A 540 × 620 window retains screen-fit scaling and movement.

The header holds the recipe icon, two-line title and italic profession caption. Materials occupy an understated inset with scrolling and wrapped labels. A single-choice material uses one icon row containing its name, quantity and required/optional state; alternatives retain their group heading and individual choices.

The lower section groups the crafter selector, saved knowledge date, quantity stepper, whisper action and availability message. All buttons use the existing parchment/bronze controls. Cached knowledge stays explicitly labeled. No acquisition, networking, whisper safety or synchronization logic changes.

Implementation: generate a text-free background, restyle only RecipeDetailsUI.lua, update material-row assertions, run the complete Lua suite, and render complete, long-name, empty, unavailable and many-crafter previews from runtime anchors. Verify texture export pixel round-trip. Final appearance in WoW requires an in-game check.
