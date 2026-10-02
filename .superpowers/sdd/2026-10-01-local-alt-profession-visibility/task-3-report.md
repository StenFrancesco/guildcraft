# Task 3 Report: Purge departed non-local character data

## Changes

- Reconciliation now requires the gear, legacy ownership, and GUID ownership tables needed for a safe purge.
- After complete roster collection, local GUID ownership and the recipe index are validated before registry repair or purge can proceed.
- Successful reconciliation removes absent non-local profession records, reverse registry entries, repair candidates, recipe crafter references, and gear records. Locally GUID-owned records and records protected by an unresolved legacy key marker remain. `nextLocalCharacterID` is not changed.
- An authoritative `IsInGuild() == false` result is treated as an empty roster. An in-guild zero-row result remains incomplete and returns without purge.
- Added six roster purge/retention tests and updated two older roster tests to explicitly declare their retained records as locally owned.

## TDD evidence

Lua 5.1 was unavailable. The installed runtime is Lua 5.4.6 at `C:\Users\stend\AppData\Local\Programs\Lua\bin\lua.exe`; no Lua 5.1 verification is claimed. Direct sandbox execution was denied, so the same test command was run with permission to execute that one installed binary.

**RED command:**

```powershell
& 'C:\Users\stend\AppData\Local\Programs\Lua\bin\lua.exe' tests/run.lua
```

Observed summary before production changes: `325 passed, 3 failed`. The three failures were the expected missing-purge assertions in the new tests for departed profession/gear records and the authoritative out-of-guild case. The retention, local ownership, legacy marker, and incomplete-roster tests passed.

**GREEN command:**

```powershell
& 'C:\Users\stend\AppData\Local\Programs\Lua\bin\lua.exe' tests/run.lua
```

Observed summary after implementation and fixture updates: `328 passed, 0 failed`.

## Self-review

- Unavailable APIs, malformed or ambiguous roster rows, zero members while still in a guild, invalid local ownership or recipe index state, failed registry repair, and rename conflicts all return before the purge block.
- The `IsInGuild() == false` path skips roster calls and reaches the same validated purge phase with an empty current roster.
- Local profession IDs are collected and sorted before purge; deleting entries does not lower or rewrite `nextLocalCharacterID`.
- Recipe index cleanup removes only the departing crafter ID and retains shared recipes for surviving crafters.
- A legacy `localCharacters[key] == true` marker without matching GUID ownership protects records for that key, but does not set `localCharacterGUIDs` or infer ownership from the profession record.
- No external data source, addon-message path, or gameplay automation was added.
- `git diff --check` completed without errors. The unrelated untracked `examples/` content was not staged.

## Files

- `GuildGearMemory/ProfessionIndex.lua`
- `tests/profession_index_test.lua`
- `.superpowers/sdd/2026-10-01-local-alt-profession-visibility/task-3-report.md`
