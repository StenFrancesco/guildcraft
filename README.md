# Guild Gear Memory

Install and enable all three sibling folders in your WoW `Interface/AddOns` folder:

```text
Interface/AddOns/
    GuildGearMemory/
    DysbankMemory/
    DysgearMemory/
```

Each folder must directly contain its matching `.toc` file. GuildGearMemory
remains the main addon and provides the `/ggm` browser.

| Folder | Saved global | Contents |
| --- | --- | --- |
| GuildGearMemory | GuildGearMemoryDB | Professions, recipe index, and profession character metadata |
| DysbankMemory | DysbankMemoryDB | Last-known personal and guild bank snapshots |
| DysgearMemory | DysgearMemoryDB | Gear capture, stable changes, last-known gear, ownership, and guild synchronization |

DysgearMemory owns the gear backend and runs capture and synchronization even
when GuildGearMemory is disabled. GuildGearMemory reads its versioned backend
interface to show the same gear browser and `/ggm` commands. Install matching
versions of both folders; the earlier persistence-only companion is unsupported.
The saved gear format and guild message protocol remain unchanged by this split.

WoW writes these to separate files under
`WTF/Account/<account>/SavedVariables` when you log out or reload. The three
addon folders belong in `Interface/AddOns`, not in `SavedVariables`.

This branch starts a fresh gear cache. Old gear in GuildGearMemoryDB is not
migrated; its legacy gear fields are removed after profession storage validates.
Your character's gear is captured again at login through the existing addon API
path. Profession and bank data stay in their respective databases. Offline
characters remain unavailable until a permitted observation or explicit cached
snapshot request supplies their gear.

If DysgearMemory is missing, disabled, or has an unsupported database, gear
capture and synchronization are unavailable; profession and bank features remain
usable. `/ggm status` reports storage errors. Back up SavedVariables with WoW
closed before manually resetting any database.

Run the regression suite with Lua 5.1 using `lua tests/run.lua`. In this
workspace, the local Lua 5.1 runtime can be used with
`./tools/lua/lua.exe tests/run.lua`.

To create a local install ZIP containing all three addon folders, run
`python ui-concepts/package-bank-polish.py` (requires Pillow). The output is
`ui-concepts/GuildGearMemory-ThreeFolders.zip`.
