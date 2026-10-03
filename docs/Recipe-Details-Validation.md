# Recipe details validation

## Policy and API review, 2026-10-03

The feature displays ordinary exposed recipe material data and existing cached crafter knowledge. It does not perform gameplay actions, inspection, communication, external game-state acquisition, or database enrichment.

Reviewed official Blizzard sources:

- [UI Add-On Development Policy](https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534): visible addon source, no excessive realm/chat impact, and Blizzard's ability to disable addon functionality.
- [Blizzard EULA](https://www.blizzard.com/en-gb/legal/2c72a35c-bf1b-4ae6-99ec-80624e1b429c/blizzard-end-user-license-agreement): unauthorized external information collection and automation remain excluded. The official page was indexed on the review date; direct retrieval intermittently failed.
- [Combat Philosophy and Addon Disarmament in Midnight](https://news.blizzard.com/en-us/article/24246290/combat-philosophy-and-addon-disarmament-in-midnight): secret values must not be processed to recover withheld information.

Blizzard-authored generated API documentation, distributed with the game and viewable in a source mirror:

- [TradeSkillUIDocumentation.lua](https://raw.githubusercontent.com/Gethe/wow-ui-source/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/TradeSkillUIDocumentation.lua): GetRecipeSchematic accepts recipeSpellID and isRecraft, returning CraftingRecipeSchematic.

The mirrored API contract describes the exposed interface; official Blizzard policy remains the permission source. The implementation must treat nil, errors, unsupported contracts, secret values, and combat restrictions as unavailable. It must not change trade-skill context to retrieve missing information.

## In-game visual and interaction checks

1. Open Guild Gear Memory, select Professions, and click a saved recipe. Confirm a separate Blizzard-style window opens with its name, icon, profession, materials, and crafter dropdown.
2. Select a recipe with several materials and quality alternatives. Check quantities and alternative/optional labels; scroll through the full list.
3. Select each known crafter. Confirm name, realm, saved date, and last-known knowledge are visible. No crafting or messages should result.
4. Click another recipe, then search and click a reused row. Confirm the details belong to the newly selected recipe.
5. Drag the window; close it using its button and Escape. Switch professions and tabs, then close the main browser. Confirm no orphan window or menu remains.
6. Refresh cached data or invalidate guild eligibility while details are open. Confirm removed crafters and obsolete recipes do not remain attributed.
7. Test a recipe without available material context and test selection during combat. Confirm an unavailable message without an error, context change, or workaround.

Automated tests cover logic and injected UI behavior. Actual WoW font metrics, textures, layering, template compatibility, and visual proportions require this in-game check.

Automated verification: 351 tests passed, zero failures; all six changed Lua files parsed with Lua 5.1; `git diff --check` passed. In-game checks above have not been performed in this session.
