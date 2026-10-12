# The Guild Book Addon Rename Design

**Date:** 2026-10-12

## Goal

Rename the three installed World of Warcraft addon folders and their visible names:

| Current folder | New folder and visible name |
| --- | --- |
| `GuildGearMemory` | `The Guild Book` |
| `DysgearMemory` | `The Guild Book gear` |
| `DysbankMemory` | `The Guild Book Bank` |

## Design

Each addon folder and its `.toc` file will use the exact new name. The `.toc` titles, optional dependency names, addon-load identity checks, hard-coded asset paths, install guidance, packaging tools, and repository references will be updated to match. The three folders will remain siblings directly under `Interface/AddOns` in packaged installs.

Internal Lua APIs and SavedVariables globals (`GuildGearMemoryDB`, `DysgearMemoryDB`, and `DysbankMemoryDB`) will retain their current names. No capture, storage schema, synchronization behavior, or data source will change.

Because changing an addon ID can change the SavedVariables file basename, existing users will receive a migration note. It will explain how to rename the old account-wide files after fully closing WoW, without deleting or overwriting them automatically.

## Acceptance criteria

- All three new folder names contain a `.toc` file with the exact same basename.
- TOC dependencies and runtime addon identity checks use the new folder names.
- Every addon asset and installation path points to the renamed folders.
- Packaging and repository documentation use the new folder structure and names.
- Existing SavedVariables globals and Lua API identifiers remain unchanged.
- Existing test fixtures refer to the new paths and addon IDs.

## Scope and safety

This is a naming and packaging change only. It does not add game-state access, addon-message traffic, gameplay automation, or external data paths. Migration guidance preserves user control over existing local SavedVariables files.
