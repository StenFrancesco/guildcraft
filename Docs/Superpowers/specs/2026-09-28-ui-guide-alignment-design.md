# UI Guide Alignment Design

## Goal

Bring Guild Gear Memory's existing user interface into alignment with `UI_GUIDE.md` while preserving its familiar World of Warcraft addon layout and behavior.

## Scope

Apply the shared visual system to the main saved-gear browser, including its Character, Professions, and Bank tabs, and to the Save button added to the profession window.

The main browser keeps its existing centered 900×610 window, dark application shell, left character search/list column, right-side character details, and paper-doll equipment arrangement. The Bank tab remains a placeholder. The Professions tab keeps its existing content and navigation structure.

## Design

### Shared visual foundation

Use a single set of local design tokens in `SnapshotTestUI.lua` for the application and panel surfaces, border and accent colors, text hierarchy, spacing, and common control dimensions. Reuse shared construction and styling helpers for panels, buttons, rows, inputs, navigation tabs, and headings wherever the current WoW frame APIs allow. Keep the dark, restrained visual treatment and use the accent color for active or selected controls. Reserve semantic colors for meaningful status.

Align the search and ownership controls, character list, detail heading, equipment panel, and profession content to the guide's spacing rhythm and shared edges. Preserve the current compact density and slot arrangement. Keep Bank's placeholder within the common shell instead of introducing a separate visual treatment.

### Interaction states

Standardize hover, pressed, selected, focus, and disabled feedback across custom controls, using the states supported by the WoW UI frame API and existing addon compatibility targets. Selection remains visible after pointer exit. Keyboard focus remains visible where the control supports keyboard interaction. Disabled controls are visually distinct and do not use success or warning colors decoratively.

### Profession-window Save button

Keep the Save button parented to the Blizzard profession frame and preserve its current visibility, save action, and status behavior. Apply the same common control height, text hierarchy, neutral surface, border, and accent/focus treatment used in the browser. Do not alter Blizzard-owned profession controls.

## Behavior and policy boundaries

This is a presentation-only change. It does not change gear capture, API usage, inspection behavior, cached-data claims, SavedVariables, addon communication, synchronization timing, or profession snapshot logic. It adds no external data or interaction path and does not automate gameplay.

Existing unavailable, incomplete, empty, and cached-data messages remain truthful and retain their current data meanings. Text needed to understand a state stays visible without requiring a tooltip.

## Implementation areas

- `GuildGearMemory/SnapshotTestUI.lua`: consolidate the visual tokens and reusable helpers, then apply them to the browser window, search and ownership controls, character rows, detail and equipment panels, paper-doll slot controls, profession page, and navigation tabs.
- `GuildGearMemory/ProfessionLinkSave.lua`: style the profession Save button using the shared control rules without changing its save or visibility logic.
- `tests/snapshot_test_ui_test.lua` and `tests/profession_link_save_test.lua`: update existing UI-focused assertions only if the presentation changes require them; do not broaden into data or synchronization behavior.

## Completion criteria

- The browser and profession Save button use a consistent accent, panel, border, typography, spacing, and control-height system.
- Shared control types have consistent hover and selected treatments; focus and disabled feedback are present wherever their frame/API states apply.
- The existing layout, paper-doll placement, tab content, and profession Save behavior remain intact.
- All existing data-state text remains accurate and readable.
- No changes are made to gameplay data acquisition, storage, or addon-message behavior.

## Validation

Review the changed screens and controls against the layout, components, typography, color, interaction, density, and consistency sections of `UI_GUIDE.md`. Preserve the existing UI-specific test expectations and update them only where presentation changes warrant it. No test commands are included in this design phase.
