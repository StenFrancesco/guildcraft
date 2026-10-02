# Task 2 implementation report: local GUID ownership at login

## Scope

Recorded local player ownership synchronously during `PLAYER_LOGIN`, using only `UnitGUID("player")` and the local SavedVariables database. A missing, invalid, or erroring GUID API result is reported as `player-guid-unavailable` and does not stop the existing delayed gear-tracker startup. Profession capture remains tied to the existing explicit profession UI Save Snapshot action.

The helper does not resolve names or realms, inspect gear, inspect professions, or derive ownership from snapshots, guild links, or roster entries. The existing key-based marker in gear-tracker startup remains unchanged. No network behavior was added.

## TDD evidence

### RED

Command, using the installed Lua 5.4.6 executable because `lua5.1` is not installed:

```powershell
& 'C:\Users\stend\AppData\Local\Programs\Lua\bin\lua.exe' tests\run.lua
```

Observed before the production implementation:

```text
318 passed, 4 failed
```

The failures were the newly added ownership/login behavior checks: the ownership helper did not exist, login did not record ownership, and the ownership-failure diagnostic was absent. The initial sandboxed process launch was denied; rerunning the same specific test executable with the required execution approval produced the RED result above.

### GREEN

After implementing the helper and login call, three older `Main.lua` test fixtures that simulate a successful login were updated to provide the new helper dependency. Their behavior assertions remain focused on their respective gear/sync paths.

Command:

```powershell
& 'C:\Users\stend\AppData\Local\Programs\Lua\bin\lua.exe' tests\run.lua
```

Observed final full-suite result:

```text
322 passed, 0 failed
EXIT_CODE=0
```

The ownership tests also assert that only the `player` GUID is requested, forbidden identity/gear/profession APIs are not touched, no profession or key-based local-character state is created, and missing GUID data fails closed without changing the GUID ownership table.

`git diff --check` completed without whitespace errors. Git printed only line-ending normalization warnings for the four edited source/test files.

## Files changed

- `GuildGearMemory/LocalGearMemory.lua`
- `GuildGearMemory/Main.lua`
- `tests/local_gear_memory_test.lua`
- `tests/main_test.lua`

## Verification limits

Lua 5.1 verification was not performed because `lua5.1` was unavailable. The only runtime suite verified here used Lua 5.4.6. The existing untracked `examples/GuildGearMemory.lua` was preserved and not staged.
