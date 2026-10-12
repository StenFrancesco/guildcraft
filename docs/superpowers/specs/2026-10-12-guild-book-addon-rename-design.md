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

All three TOCs and their Lua references will use the SavedVariables globals `TheGuildBookDB`, `TheGuildBookGearDB`, and `TheGuildBookBankDB`. Lua API identifiers and addon-message prefixes keep their existing names. No capture, storage schema, synchronization behavior, or data source will change.

This task does not migrate SavedVariables data or access user WoW files.

## Acceptance criteria

- All three new folder names contain a `.toc` file with the exact same basename.
- TOC dependencies and runtime addon identity checks use the new folder names.
- Every addon asset and installation path points to the renamed folders.
- Packaging and repository documentation use the new folder structure and names.
- The TOCs and Lua references use the three new SavedVariables globals; Lua API identifiers and addon-message prefixes remain unchanged.
- Existing test fixtures refer to the new paths and addon IDs.

## Scope and safety

This is a naming and packaging change only. It does not add game-state access, addon-message traffic, gameplay automation, or external data paths. Existing SavedVariables data is not migrated.
